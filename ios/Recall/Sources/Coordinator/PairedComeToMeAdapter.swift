import Foundation
#if canImport(ComeToMeCore)
@testable import ComeToMeCore
#endif
#if canImport(ControllerCore)
@testable import ControllerCore
#endif
#if canImport(PoseCore)
import PoseCore
#endif

/// Identity and sticky cancellation for a single paired-phone request. A delayed cancel never stops another task.
final class PairedComeRequest {
    let id: String
    private let lock = NSLock()
    private var stopped = false
    init(id: String) { self.id = id }
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return stopped }
    func cancel() { lock.lock(); stopped = true; lock.unlock() }
}

enum PairedComeContext {
    @TaskLocal static var request: PairedComeRequest?
}

/// Pairing may collect diagnostic ranges before the human verifies the robot mount's left/right bearing.
final class PairedGuidanceSource: RangingSource {
    private let source: RangingSource
    private let lock = NSLock()
    private var enabled = false
    init(source: RangingSource) { self.source = source }
    var isEnabled: Bool { lock.lock(); defer { lock.unlock() }; return enabled }
    func setEnabled(_ value: Bool) { lock.lock(); enabled = value; lock.unlock() }
    func latest() -> RangeSample { isEnabled ? source.latest() : RangeSample() }
}

/// Entered only inside RobotCoordinator's admitted task and its task-local DriveLease.
final class PairedComeToMeAdapter: CoordinatorComingToUser {
    private let ranging: RangingSource
    private let isReady: () -> Bool
    private let makeMotion: () -> ApproachMotion
    private let clock: () -> Double
    private let sleep: (Double) async -> Void
    private let onStatus: (PairedComeRequest?, CompanionState, Double?, String?) -> Void
    private let lock = NSLock()
    private var current: (request: PairedComeRequest?, runner: PairedApproachRunner)?
    private var cancelEpoch = 0

    init(ranging: RangingSource, isReady: @escaping () -> Bool = { false }, makeMotion: @escaping () -> ApproachMotion,
         clock: @escaping () -> Double = { ProcessInfo.processInfo.systemUptime },
         sleep: @escaping (Double) async -> Void = { try? await Task.sleep(nanoseconds: UInt64($0 * 1_000_000_000)) },
         onStatus: @escaping (PairedComeRequest?, CompanionState, Double?, String?) -> Void = { _, _, _, _ in }) {
        self.ranging = ranging; self.isReady = isReady; self.makeMotion = makeMotion; self.clock = clock; self.sleep = sleep
        self.onStatus = onStatus
    }

    func comeToMe() async throws -> CoordinatorTaskResult {
        try Task.checkCancellation()
        let request = PairedComeContext.request
        guard request?.isCancelled != true else { return .cancelled }
        guard isReady() else { return .refused(spoken: "Pair your phone and check the left/right bearing in Robot tools before enabling approach.") }
        let epoch = cancellationEpoch()
        let motion = makeMotion()
        let runner = PairedApproachRunner(ranging: ranging, motion: motion, clock: clock, sleep: sleep,
                                         onStatus: { [onStatus] state, distance, reason in onStatus(request, state, distance, reason) })
        guard install(runner, request: request, epoch: epoch) else { runner.cancel(); return .cancelled }
        defer { clear(runner) }
        let result = await withTaskCancellationHandler(operation: { await runner.run() }, onCancel: { runner.cancel() })
        if Task.isCancelled || request?.isCancelled == true { return .cancelled }
        switch result {
        case .arrived: return .completed(summary: "Reached the paired phone, about one metre away.")
        case .cancelled: return .cancelled
        case .blocked(let reason): return .blocked(reason: reason)
        }
    }

    /// Coordinator STOP/manual takeover cancels whichever paired approach this adapter owns.
    func cancel() {
        lock.lock(); cancelEpoch += 1; let runner = current?.runner; lock.unlock()
        runner?.cancel()
    }

    /// Peer cancellation is scoped by object identity, including cancellation before runner registration.
    func cancel(request: PairedComeRequest) {
        request.cancel()
        lock.lock(); let runner = current?.request === request ? current?.runner : nil; lock.unlock()
        runner?.cancel()
    }

    private func cancellationEpoch() -> Int { lock.lock(); defer { lock.unlock() }; return cancelEpoch }
    private func install(_ runner: PairedApproachRunner, request: PairedComeRequest?, epoch: Int) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard current == nil, cancelEpoch == epoch, request?.isCancelled != true else { return false }
        current = (request, runner)
        return true
    }
    private func clear(_ runner: PairedApproachRunner) {
        lock.lock(); if current?.runner === runner { current = nil }; lock.unlock()
    }
}

/// Fresh per-request controller: shared serialized/leased drive path, capped wheels and both existing guards.
final class PairedControllerMotion: ApproachMotion {
    private let poses: PoseSource
    private let controller: Controller
    private let sink: CappedDriveSink
    private let epoch: UInt64

    init(poses: PoseSource, sink: DriveSink, guardState: @escaping () -> GuardState,
         turnGuard: (() -> GuardState)? = nil) {
        self.poses = poses
        let capped = CappedDriveSink(inner: sink, cap: 120)
        self.sink = capped
        let controller = Controller(poses: poses, sink: capped, guardState: guardState, turnGuard: turnGuard)
        self.controller = controller
        epoch = controller.stopEpoch
    }

    func rotate(deg: Double, speedCap: Int) async -> ControlStatus {
        guard !Task.isCancelled else { return .failed(.cancelled) }
        guard poses.latest().tracking == .normal else { return .failed(.trackingLost) }
        sink.cap = min(120, max(0, speedCap))
        return await controller.rotateBy(deg, since: epoch)
    }
    func drive(meters: Double, bearingDeg: Double, speedCap: Int) async -> ControlStatus {
        guard !Task.isCancelled else { return .failed(.cancelled) }
        let sample = poses.latest()
        guard sample.tracking == .normal, let p = sample.pose else { return .failed(.trackingLost) }
        sink.cap = min(120, max(0, speedCap))
        let yaw = (p.yawDeg + bearingDeg) * .pi / 180
        // Controller already has a 5 cm arrival margin. Adding another stand-off here would make
        // the final short segment complete without moving while UWB still reports outside stand-off.
        return await controller.goTo(x: p.x - meters * sin(yaw), z: p.z - meters * cos(yaw), stopDistance: 0, since: epoch)
    }
    func stop() { controller.stop() }
}
