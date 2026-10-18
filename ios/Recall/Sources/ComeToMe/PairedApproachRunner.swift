import Foundation
#if canImport(ControllerCore)
@testable import ControllerCore
#endif

enum PairedApproachResult: Equatable {
    case arrived, cancelled
    case blocked(String)
}

/// Conservative placeholders, not measured range accuracy or rover stopping performance.
struct PairedApproachConfig {
    let stopDistance: Double
    let segmentMax: Double
    let overallTimeout: Double
    let sampleWait: Double
    let sampleMaxAge = 1.0
    let arrivalMargin = 0.05
    let driveSpeedCap = 100
    let turnSpeedCap = 120

    init(stopDistance: Double = 1.1, segmentMax: Double = 0.25,
         overallTimeout: Double = 60, sampleWait: Double = 3) {
        func bounded(_ value: Double, _ fallback: Double, _ low: Double, _ high: Double) -> Double {
            value.isFinite ? max(low, min(high, value)) : fallback
        }
        self.stopDistance = bounded(stopDistance, 1.1, 1, 2)
        self.segmentMax = bounded(segmentMax, 0.25, 0.05, 0.25)
        self.overallTimeout = bounded(overallTimeout, 60, 1, 60)
        self.sampleWait = bounded(sampleWait, 3, 0.1, 3)
    }
}

/// Paired-phone UWB only: never probes without direction and never substitutes a detected person.
/// Motion must enforce the global STOP epoch and the normal tracking/obstacle guard at its drive boundary.
final class PairedApproachRunner {
    private let config: PairedApproachConfig
    private let ranging: RangingSource
    private let motion: ApproachMotion
    private let clock: () -> Double
    private let sleep: (Double) async -> Void
    private let onStatus: (CompanionState, Double?, String?) -> Void
    private let lock = NSLock()
    private var cancelled = false
    private var running = false
    private var generation = 0
    private var pending: Task<ControlStatus, Never>?

    init(config: PairedApproachConfig = PairedApproachConfig(), ranging: RangingSource,
         motion: ApproachMotion, clock: @escaping () -> Double = { ProcessInfo.processInfo.systemUptime },
         sleep: @escaping (Double) async -> Void = {
             try? await Task.sleep(nanoseconds: UInt64($0 * 1_000_000_000))
         }, onStatus: @escaping (CompanionState, Double?, String?) -> Void = { _, _, _ in }) {
        self.config = config; self.ranging = ranging; self.motion = motion
        self.clock = clock; self.sleep = sleep; self.onStatus = onStatus
    }

    /// Cancellation is sticky for this runner: late STOP is never cleared by starting run().
    func cancel() {
        lock.lock(); cancelled = true; generation += 1; let task = pending; lock.unlock()
        motion.stop()
        task?.cancel()
    }

    private func begin() -> Int? {
        lock.lock(); defer { lock.unlock() }
        guard !cancelled, !running else { return nil }
        running = true; generation += 1
        return generation
    }
    private func current(_ g: Int) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return running && !cancelled && generation == g
    }
    private func install(_ task: Task<ControlStatus, Never>, generation g: Int) {
        lock.lock()
        let valid = running && !cancelled && generation == g
        if valid { pending = task }
        lock.unlock()
        if !valid { task.cancel(); motion.stop() }
    }
    private func end() {
        lock.lock(); pending = nil; running = false; lock.unlock()
    }
    private func sample(now: Double) -> (distance: Double, bearing: Double, time: Double)? {
        let r = ranging.latest()
        guard now.isFinite, let d = r.distanceM, d.isFinite, d >= 0,
              let b = r.bearingDeg, b.isFinite, abs(b) <= 180,
              let t = r.updatedAt, t.isFinite, t >= 0, t <= now, now - t <= config.sampleMaxAge else { return nil }
        return (d, b, t)
    }

    @discardableResult
    func run() async -> PairedApproachResult {
        guard let g = begin() else { return .cancelled }
        return await withTaskCancellationHandler(operation: {
            defer { self.motion.stop(); self.end() }
            let result = await self.execute(g)
            switch result {
            case .arrived: self.onStatus(.arrived, self.sample(now: self.clock())?.distance, nil)
            case .cancelled: self.onStatus(.failed, nil, "cancelled")
            case .blocked(let reason): self.onStatus(.failed, nil, reason)
            }
            return result
        }, onCancel: { self.cancel() })
    }

    private func execute(_ g: Int) async -> PairedApproachResult {
        let started = clock()
        guard started.isFinite else { return .blocked("invalid_clock") }
        var waitStarted = started
        var requireAfter: Double?
        onStatus(.accepted, nil, nil)
        while true {
            guard current(g), !Task.isCancelled else { return .cancelled }
            let now = clock()
            guard now.isFinite, now >= started else { return .blocked("invalid_clock") }
            if now - started >= config.overallTimeout { return .blocked("timeout") }
            guard let r = sample(now: now), requireAfter.map({ r.time > $0 }) ?? true else {
                if now - waitStarted >= config.sampleWait { return .blocked("range_or_direction_unavailable") }
                await sleep(0.1); continue
            }
            if r.distance <= config.stopDistance + config.arrivalMargin { return .arrived }
            onStatus(.approaching, r.distance, nil)
            let turning = abs(r.bearing) > 15
            let meters = min(config.segmentMax, r.distance - config.stopDistance)
            let completion = MotionCompletion()
            let task = Task { [self] () -> ControlStatus in
                guard current(g), !Task.isCancelled else {
                    completion.set(.failed(.cancelled)); return .failed(.cancelled)
                }
                let status: ControlStatus
                if turning {
                    status = await motion.rotate(deg: max(-30, min(30, r.bearing)), speedCap: config.turnSpeedCap)
                } else {
                    status = await motion.drive(meters: meters, bearingDeg: r.bearing, speedCap: config.driveSpeedCap)
                }
                completion.set(status)
                return status
            }
            install(task, generation: g)
            while true {
                guard current(g), !Task.isCancelled else { await stopAndDrain(task); return .cancelled }
                let checkTime = clock()
                guard checkTime.isFinite, checkTime >= started else {
                    await stopAndDrain(task); return .blocked("invalid_clock")
                }
                if checkTime - started >= config.overallTimeout {
                    await stopAndDrain(task); return .blocked("timeout")
                }
                guard let check = sample(now: checkTime) else {
                    await stopAndDrain(task); return .blocked("range_or_direction_lost")
                }
                if let status = completion.get(), status != .done {
                    _ = await task.value
                    if status == .failed(.cancelled) { return .cancelled }
                    return .blocked("motion_failed")
                }
                if check.distance <= config.stopDistance + config.arrivalMargin {
                    await stopAndDrain(task); return .arrived
                }
                // A translating segment must not continue toward a direction that changed substantially.
                if !turning, abs(check.bearing) > 30 {
                    await stopAndDrain(task); return .blocked("direction_changed")
                }
                if completion.get() == .done { _ = await task.value; break }
                await sleep(0.1)
            }
            // Reuse no reading taken before or during the segment, even when it is still fresh.
            requireAfter = clock()
            waitStarted = requireAfter!
        }
    }

    /// Keep coordinator ownership until the controller's final STOP/cleanup has finished.
    /// Otherwise an old segment could brake a successor after the approach has returned.
    private func stopAndDrain(_ task: Task<ControlStatus, Never>) async {
        task.cancel()
        motion.stop()
        _ = await task.value
    }

    private final class MotionCompletion {
        private let lock = NSLock()
        private var status: ControlStatus?
        func set(_ value: ControlStatus) { lock.lock(); status = value; lock.unlock() }
        func get() -> ControlStatus? { lock.lock(); defer { lock.unlock() }; return status }
    }
}
