import Foundation
#if canImport(CoordinatorCore)
@testable import CoordinatorCore
#endif
#if canImport(ControllerCore)
@testable import ControllerCore
#endif
#if canImport(ExploreCore)
@testable import ExploreCore
#endif
#if canImport(PlannerCore)
@testable import PlannerCore
#endif
#if canImport(PoseCore)
import PoseCore
#endif

// Remote Teach (Sought sends "forward 0.5 m", "turn left 90", "scan here", "save map"). Runs as a coordinator task on
// the coordinator's Controller and drive lease, so STOP, pause and a manual tool cancel it like any other task.
// - forward: Controller.goTo to a point straight ahead with the full forward guard, arriving within ~0.1 m.
// - back: Controller.goTo cannot reverse, so a slow straight reverse that holds on the rear sonar guard.
// - turn: Controller.rotateBy with the turn guard.
// - scan here: Explore's ScanRoutine (the Scan here routine) driven by Controller.rotateBy.
// No drive tuning here: speeds are the Controller's own constants.

final class RemoteTeachAdapter: CoordinatorRemoteTeaching {
    /// goTo's stop distance for a forward move: done once within stopDistance + 0.05 = 0.1 m of the target point.
    static let forwardStopDistanceM = 0.05
    /// Reverse is done this close to the requested distance.
    static let reverseToleranceM = 0.05
    /// PLACEHOLDER reverse wheel command (Controller's slow linear speed), not tuned for reversing.
    static let reverseSpeed = Int(ControllerTuning.slowLinear)
    static let reverseTimeoutS = 10.0

    private let controller: Controller
    private let poses: PoseSource
    private let reverseSink: DriveSink
    private let rearHold: () -> Bool
    private let scanConfig: ScanConfig
    private let saver: () async -> String?
    private let clock: () -> Double
    private let sleep: (Double) async -> Void

    /// `controller` is the coordinator's (leased sink, forward guard, turn guard). `reverseSink` must be the same leased
    /// sink. `rearHold` true = rear blocked (see RearGuard). `saveMap` returns nil when saved and adopted, else why not.
    init(controller: Controller, poses: PoseSource, reverseSink: DriveSink, rearHold: @escaping () -> Bool,
         scanConfig: ScanConfig, saveMap: @escaping () async -> String?,
         clock: @escaping () -> Double = { ProcessInfo.processInfo.systemUptime },
         sleep: @escaping (Double) async -> Void = { try? await Task.sleep(nanoseconds: UInt64($0 * 1_000_000_000)) }) {
        self.controller = controller; self.poses = poses; self.reverseSink = reverseSink; self.rearHold = rearHold
        self.scanConfig = scanConfig; self.saver = saveMap; self.clock = clock; self.sleep = sleep
    }

    func cancel() { controller.stop() }

    func saveMap() async -> String? { await saver() }

    func move(meters: Double) async throws -> CoordinatorTaskResult {
        let epoch = controller.stopEpoch   // a cancel() from here on cancels this move even before the loop starts
        try Task.checkCancellation()
        let s = poses.latest()
        guard s.tracking == .normal, let start = s.pose else { return .blocked(reason: CoordinatorConfig.rescanReason) }
        let dist = abs(meters)
        if meters < 0 { return await reverse(dist, from: start, since: epoch) }
        // Heading vector for yaw (0 deg = -z, CCW positive): (-sin, -cos).
        let yaw = start.yawDeg * .pi / 180
        let status = await controller.goTo(x: start.x - sin(yaw) * dist, z: start.z - cos(yaw) * dist,
                                           stopDistance: Self.forwardStopDistanceM, since: epoch)
        let r = ControllerResultMapper.result(status)
        guard case .completed = r else { return r }
        return .completed(summary: "moved \(RemoteTeachText.meters(dist)) m")
    }

    func turn(degrees: Double) async throws -> CoordinatorTaskResult {
        let epoch = controller.stopEpoch
        try Task.checkCancellation()
        let r = ControllerResultMapper.result(await controller.rotateBy(degrees, since: epoch))
        guard case .completed = r else { return r }
        return .completed(summary: "turned \(degrees < 0 ? "right" : "left") \(RemoteTeachText.degrees(abs(degrees)))°")
    }

    func scanHere() async throws -> CoordinatorTaskResult {
        let epoch = controller.stopEpoch
        try Task.checkCancellation()
        let total = scanConfig.rotations
        let drive = TurnDrive(controller: controller, since: epoch)
        let poses = self.poses, controller = self.controller
        var trackingLost = false
        let result = await ScanRoutine(config: scanConfig).run(
            stopIndex: 0, drive: drive, hook: NoCapture(), clock: SleepClock(clock: clock, sleep: sleep),
            shouldAbort: {
                if controller.stopEpoch != epoch || Task.isCancelled { return true }
                if poses.latest().tracking != .normal { trackingLost = true; return true }
                return false
            })
        // Every Controller run already ends with STOP; the coordinator brakes again when the task returns.
        let done = "\(drive.turnsDone)/\(total)"
        if controller.stopEpoch != epoch || Task.isCancelled { return .cancelled }
        if trackingLost { return .blocked(reason: "\(CoordinatorConfig.rescanReason) (scan stopped at \(done))") }
        switch result {
        case .reached: return .completed(summary: "scan done \(done)")
        case .cancelled: return .cancelled
        case .trackingLost: return .blocked(reason: "\(CoordinatorConfig.rescanReason) (scan stopped at \(done))")
        case .failed: return .blocked(reason: "a turn did not finish (scan stopped at \(done))")
        }
    }

    /// Straight reverse at a slow constant command. Holds (STOP) while the rear guard says blocked; gives up after the
    /// timeout. Every exit leaves the rover stopped.
    private func reverse(_ dist: Double, from start: Pose2D, since epoch: UInt64) async -> CoordinatorTaskResult {
        defer { reverseSink.stop() }
        let t0 = clock()
        var lostSince: Double?
        var held = false
        while true {
            if controller.stopEpoch != epoch || Task.isCancelled { return .cancelled }
            let now = clock()
            if now - t0 > Self.reverseTimeoutS {
                return .blocked(reason: held ? "something is behind me" : "I couldn't back up that far in time")
            }
            let s = poses.latest()
            if s.tracking != .normal || s.pose == nil {
                reverseSink.stop()
                if lostSince == nil { lostSince = now }
                if now - (lostSince ?? now) > ControllerTuning.trackingLossLimit { return .blocked(reason: CoordinatorConfig.rescanReason) }
            } else if let p = s.pose {
                lostSince = nil
                if hypot(p.x - start.x, p.z - start.z) >= dist - Self.reverseToleranceM {
                    return .completed(summary: "moved back \(RemoteTeachText.meters(dist)) m")
                }
                held = rearHold()
                if held { reverseSink.stop() } else { reverseSink.drive(left: -Self.reverseSpeed, right: -Self.reverseSpeed) }
            }
            await sleep(1.0 / ControllerTuning.tickHz)
        }
    }

    private final class NoCapture: ScanHook {
        func captureKeyframe(stopIndex: Int, headingIndex: Int) async {}   // the perception loop captures while parked
    }

    private final class SleepClock: ExploreClock {
        let clock: () -> Double
        let sleeper: (Double) async -> Void
        init(clock: @escaping () -> Double, sleep: @escaping (Double) async -> Void) { self.clock = clock; self.sleeper = sleep }
        func now() -> Double { clock() }
        func sleep(_ seconds: Double) async { await sleeper(seconds) }
    }

    /// Scan turns on the coordinator's Controller, each bound to the task's stop epoch.
    private final class TurnDrive: ExploreDrive {
        let controller: Controller
        let since: UInt64
        private(set) var turnsDone = 0
        init(controller: Controller, since: UInt64) { self.controller = controller; self.since = since }
        func goTo(x: Double, z: Double, stopDistance: Double) async -> DriveResult { .failed }   // a scan never drives forward
        func rotateBy(_ deg: Double) async -> DriveResult {
            switch await controller.rotateBy(deg, since: since) {
            case .done: turnsDone += 1; return .reached
            case .running, .failed(.timeout): return .failed
            case .failed(.cancelled): return .cancelled
            case .failed(.trackingLost): return .trackingLost
            }
        }
        func stop() { controller.stop() }
    }
}
