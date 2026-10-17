import Foundation
#if canImport(PoseCore)
import PoseCore
#endif
#if canImport(ControllerCore)
import ControllerCore
#endif

// Executes ApproachPlanner actions. Protocol-based so the loop is tested with fakes; the real adapters
// (ControllerMotion, CappedDriveSink) are plain Foundation and only need the existing Controller types.
// Not run on a robot. No Xcode on the machine that wrote it.

protocol ApproachMotion {
    func rotate(deg: Double, speedCap: Int) async -> ControlStatus
    func drive(meters: Double, bearingDeg: Double, speedCap: Int) async -> ControlStatus
    func stop()
}

final class ComeToMeRunner {
    private var planner: ApproachPlanner
    private let ranging: RangingSource
    private let motion: ApproachMotion
    private let detector: PersonDetector?
    private let clock: () -> Double
    private let sleep: (Double) async -> Void
    private let onStatus: (CompanionState, Double?, String?) -> Void
    private var cancelled = false

    init(config: ApproachConfig = ApproachConfig(), ranging: RangingSource, motion: ApproachMotion, detector: PersonDetector?,
         clock: @escaping () -> Double = { ProcessInfo.processInfo.systemUptime },
         sleep: @escaping (Double) async -> Void = { try? await Task.sleep(nanoseconds: UInt64($0 * 1_000_000_000)) },
         onStatus: @escaping (CompanionState, Double?, String?) -> Void) {
        planner = ApproachPlanner(config: config)
        self.ranging = ranging; self.motion = motion; self.detector = detector
        self.clock = clock; self.sleep = sleep; self.onStatus = onStatus
    }

    /// Companion `cancel`: the robot stops at once.
    func cancel() { cancelled = true; motion.stop() }

    /// Runs until arrived, failed or cancelled. Always leaves the rover stopped.
    @discardableResult
    func run() async -> ApproachPhase {
        planner.start(now: clock())
        onStatus(.accepted, nil, nil)
        var lastReport = -10.0
        while !planner.isFinished {
            if cancelled || Task.isCancelled { planner.cancel(); break }
            let r = ranging.latest()
            let person = (detector != nil) ? await detector!.detect() : nil
            let action = planner.step(ApproachInput(now: clock(), distanceM: r.distanceM, bearingDeg: r.bearingDeg,
                                                    lastUpdateAt: r.updatedAt, person: person, visionAvailable: detector != nil))
            if clock() - lastReport > 1 { onStatus(.approaching, planner.lastDistance, nil); lastReport = clock() }
            switch action {
            case .wait, .stop: motion.stop(); await sleep(0.1)
            case let .rotate(deg, cap): await perform { await self.motion.rotate(deg: deg, speedCap: cap) }
            case let .drive(m, b, cap): await perform { await self.motion.drive(meters: m, bearingDeg: b, speedCap: cap) }
            }
        }
        motion.stop()
        let s = planner.companionStatus
        onStatus(s.state, planner.lastDistance, s.reason)
        return planner.phase
    }

    private final class DoneFlag {
        private let lock = NSLock(); private var v = false
        var done: Bool { lock.lock(); defer { lock.unlock() }; return v }
        func set() { lock.lock(); v = true; lock.unlock() }
    }

    /// Runs one motion while a watchdog checks the 2 s UWB rule and cancel every 0.1 s.
    private func perform(_ work: @escaping () async -> ControlStatus) async {
        let flag = DoneFlag()
        let task = Task { () -> ControlStatus in let s = await work(); flag.set(); return s }
        while !flag.done {
            await sleep(0.1)
            if cancelled { motion.stop(); break }
            if let u = ranging.latest().updatedAt, clock() - u > planner.config.staleTimeout { motion.stop(); break }
        }
        let status = await task.value
        planner.motionFinished(at: clock())
        if status == .failed(.trackingLost) { planner.failExternally("tracking_lost") }
    }
}

/// Scales both wheels down so neither exceeds `cap` (keeps the turn ratio). Wrap the real DriveSink with this to apply
/// the lower come-to-me speed cap without touching Controller. If the cap is under the rover's minimum moving command
/// it may stall: tune `ApproachConfig.*SpeedCap` on the rover.
final class CappedDriveSink: DriveSink {
    private let inner: DriveSink
    var cap: Int
    init(inner: DriveSink, cap: Int) { self.inner = inner; self.cap = cap }
    func drive(left: Int, right: Int) {
        let m = max(abs(left), abs(right))
        guard m > cap, m > 0 else { inner.drive(left: left, right: right); return }
        let k = Double(cap) / Double(m)
        inner.drive(left: Int((Double(left) * k).rounded()), right: Int((Double(right) * k).rounded()))
    }
    func stop() { inner.stop() }
}

/// Real motion: world goal from the current pose + bearing, executed by the existing Controller.
final class ControllerMotion: ApproachMotion {
    private let poses: PoseSource
    private let sink: CappedDriveSink
    private let controller: Controller
    init(poses: PoseSource, sink: DriveSink, guardState: @escaping () -> GuardState) {
        self.poses = poses
        self.sink = CappedDriveSink(inner: sink, cap: 255)
        controller = Controller(poses: poses, sink: self.sink, guardState: guardState)
    }
    func rotate(deg: Double, speedCap: Int) async -> ControlStatus {
        sink.cap = speedCap
        return await controller.rotateBy(deg)
    }
    func drive(meters: Double, bearingDeg: Double, speedCap: Int) async -> ControlStatus {
        guard let p = poses.latest().pose else { return .failed(.trackingLost) }
        sink.cap = speedCap
        // yaw 0 faces -z, CCW positive (PoseMath): heading vector is (-sin, -cos).
        let yaw = (p.yawDeg + bearingDeg) * .pi / 180
        return await controller.goTo(x: p.x + meters * -sin(yaw), z: p.z + meters * -cos(yaw), stopDistance: 0.05)
    }
    func stop() { controller.stop() }
}
