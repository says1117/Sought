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
#if canImport(PoseCore)
import PoseCore
#endif

// The coordinator's explore task: wraps ExploreSession over the live grid and the coordinator's own Controller.
// It only ever runs inside a coordinator request, so global STOP, the drive lease, manual-tool lockout and the
// coordinator's 1 s tracking-loss monitor all apply. Forward legs obey the obstacle guard (Controller.goTo);
// turns use the coordinator Controller's rotateBy and whatever turn guard it was built with (PR 44).
// NOT RUN ON THE ROVER. Limits below are placeholders.

final class ExploreRunner: CoordinatorExploring {
    struct Limits {
        /// Run time when the request names none ("explore", or the Robot tools button).
        var defaultMinutes = 2.0
        /// Hard cap whatever the request asks for.
        var maxMinutes = 5.0
        /// Hard cap on pose-measured driving per run.
        var maxDistanceM = 8.0
    }

    private let drive: ExploreDrive
    private let poses: ExplorePoseSource
    private let grid: ExploreGridSource
    private let clock: ExploreClock
    private let speaker: CoordinatorSpeaking
    private let config: ExploreConfig
    private let limits: Limits
    private let scan: ScanRoutine
    private let lock = NSLock()
    private var session: ExploreSession?

    init(drive: ExploreDrive, poses: ExplorePoseSource, grid: ExploreGridSource, clock: ExploreClock,
         speaker: CoordinatorSpeaking, config: ExploreConfig = ExploreConfig(), limits: Limits = Limits(),
         scan: ScanRoutine = ScanRoutine()) {
        self.drive = drive; self.poses = poses; self.grid = grid; self.clock = clock; self.speaker = speaker
        self.config = config; self.limits = limits; self.scan = scan
    }

    func explore(maxMinutes: Int?) async throws -> CoordinatorTaskResult {
        try Task.checkCancellation()
        let snap = poses.latest()
        guard snap.tracking == .normal, snap.pose != nil else {
            return .refused(spoken: "I can't explore yet: I'm not tracking where I am.")
        }
        if let why = grid.readiness() { return .refused(spoken: "I can't explore yet. \(why)") }

        let minutes = min(maxMinutes.map(Double.init) ?? limits.defaultMinutes, limits.maxMinutes)
        var cfg = config
        cfg.timeCapS = min(cfg.timeCapS, minutes * 60)
        cfg.maxDistanceM = min(cfg.maxDistanceM, limits.maxDistanceM)
        let s = ExploreSession(grid: grid, drive: drive, hook: NoScanHook(), clock: clock, poses: poses,
                               waypoints: NoWaypointSink(), config: cfg, scan: scan,
                               announce: { [speaker] in speaker.say($0) })
        setSession(s)
        defer { setSession(nil) }

        let mins = max(1, Int((cfg.timeCapS / 60).rounded()))
        speaker.say("Exploring for up to \(mins) minute\(mins == 1 ? "" : "s") and \(Int(cfg.maxDistanceM)) meters. Press stop any time.")
        // Fires at once if the coordinator already cancelled this task.
        let report = await withTaskCancellationHandler { await s.run() } onCancel: { s.requestStop() }
        return finish(report)
    }

    private func setSession(_ s: ExploreSession?) { lock.lock(); session = s; lock.unlock() }

    func cancel() {
        lock.lock(); let s = session; lock.unlock()
        s?.requestStop()
        drive.stop()
    }

    private func finish(_ r: ExploreReport) -> CoordinatorTaskResult {
        let stops = "\(r.scanStops) stop\(r.scanStops == 1 ? "" : "s")"
        switch r.end {
        case .noReachableFrontier:
            speaker.say("Done exploring. I can't find more open areas I can safely reach. I made \(stops).")
            return .completed(summary: "explored: no reachable frontier, \(stops)")
        case .timeCap:
            speaker.say("Time's up. I stopped exploring after \(stops).")
            return .completed(summary: "explored: time cap, \(stops)")
        case .distanceCap:
            speaker.say("I've driven as far as one run allows. I stopped after \(stops).")
            return .completed(summary: "explored: distance cap, \(stops)")
        case .trackingLost:
            return .blocked(reason: CoordinatorConfig.rescanReason)
        case .mapNotReady(let why):
            return .blocked(reason: "my map is not usable. \(why)")
        case .stopRequested, .driveCancelled:
            return .cancelled
        }
    }
}

/// Explore's drive on the coordinator's Controller. Honors task cancellation before every command.
final class ControllerExploreDrive: ExploreDrive {
    private let controller: Controller
    init(controller: Controller) { self.controller = controller }

    func goTo(x: Double, z: Double, stopDistance: Double) async -> DriveResult {
        let epoch = controller.stopEpoch
        guard !Task.isCancelled else { return .cancelled }
        return Self.map(await controller.goTo(x: x, z: z, stopDistance: stopDistance, since: epoch))
    }

    func rotateBy(_ deg: Double) async -> DriveResult {
        let epoch = controller.stopEpoch
        guard !Task.isCancelled else { return .cancelled }
        return Self.map(await controller.rotateBy(deg, since: epoch))
    }

    func stop() { controller.stop() }

    static func map(_ s: ControlStatus) -> DriveResult {
        switch s {
        case .done: return .reached
        case .running, .failed(.timeout): return .failed
        case .failed(.cancelled): return .cancelled
        case .failed(.trackingLost): return .trackingLost
        }
    }
}

/// Perception already captures keyframes on its own while the rover is parked, so scans need no hook.
private final class NoScanHook: ScanHook {
    func captureKeyframe(stopIndex: Int, headingIndex: Int) async {}
}

/// Explore's scan stops are not saved as places: they would clutter the taught waypoints.
private final class NoWaypointSink: WaypointSink {
    func addWaypoint(name: String, x: Double, z: Double, yawDeg: Double) {}
}
