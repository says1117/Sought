import Foundation
#if canImport(PoseCore)
import PoseCore
#endif
#if canImport(ControllerCore)
@testable import ControllerCore
#endif
#if canImport(ObstacleGuardCore)
import ObstacleGuardCore
#endif
#if canImport(FindExecutor)
import FindExecutor
#endif
#if canImport(Retrieval)
import Retrieval
#endif
#if canImport(Memory)
import Memory
#endif
#if canImport(TeachCore)
import TeachCore
#endif

// Concrete adapters between the coordinator's protocols and the existing modules. ARKit and BLE specifics stay
// out: they arrive as `PoseSource` (PoseTracker) and `DriveSink` (DriveLink), both defined by Controller.
// Hardware safety is not owned here. The ESP32 watchdog and sonar stop independently.

/// Drive sink as the coordinator's synchronous brake.
final class DriveStopAdapter: CoordinatorDriveStopping {
    private let sink: DriveSink
    init(sink: DriveSink) { self.sink = sink }
    func stop() { sink.stop() }
}

final class ControllerPoseAdapter: CoordinatorPoseSource {
    private let source: PoseSource
    init(source: PoseSource) { self.source = source }
    func tracking() -> CoordinatorTracking {
        let s = source.latest()
        guard s.pose != nil else { return .notAvailable }   // PoseTracker reports nil for stale/absent frames
        switch s.tracking {
        case .normal: return .normal
        case .limited: return .limited
        case .notAvailable: return .notAvailable
        }
    }
}

/// Waypoint names to Teach `WaypointStore` rows; `markHere` saves the live pose.
final class StoreWaypointsAdapter: CoordinatorWaypoints {
    enum MarkError: Error { case noPose }
    private let store: WaypointStore
    private let poses: PoseSource
    let isPersistent: Bool
    private let frame: CoordinatorFrameValidity
    init(store: WaypointStore, poses: PoseSource, isPersistent: Bool = true, frame: CoordinatorFrameValidity) {
        self.store = store; self.poses = poses; self.isPersistent = isPersistent; self.frame = frame
    }

    func lookup(_ name: String) -> CoordinatorWaypoint? {
        guard let w = try? store.waypoint(named: name) else { return nil }
        return CoordinatorWaypoint(name: w.name, x: w.x, z: w.z, yawDeg: w.yawDeg,
                                   inCurrentFrame: frame.isInCurrentFrame(createdAt: w.createdAt),
                                   predatesMap: frame.predatesActiveMap(createdAt: w.createdAt))
    }

    func markHere(name: String) throws -> CoordinatorWaypoint {
        let s = poses.latest()
        guard s.tracking == .normal, let pose = s.pose else { throw MarkError.noPose }
        let w = try store.addWaypoint(name: name, pose: pose)
        return CoordinatorWaypoint(name: w.name, x: w.x, z: w.z, yawDeg: w.yawDeg, inCurrentFrame: true)
    }
}

enum ControllerResultMapper {
    static func result(_ s: ControlStatus) -> CoordinatorTaskResult {
        switch s {
        case .done: return .completed(summary: "arrived")
        case .running: return .blocked(reason: "The controller did not finish")
        case .failed(.cancelled): return .cancelled
        case .failed(.timeout): return .blocked(reason: "I couldn't get there in time")
        case .failed(.trackingLost): return .blocked(reason: CoordinatorConfig.rescanReason)
        }
    }
}

/// go_to_waypoint: Controller.goTo to the stored pose.
final class ControllerNavigator: CoordinatorNavigating {
    private let controller: Controller
    private let stopDistance: Double
    init(controller: Controller, stopDistance: Double = 0.3) { self.controller = controller; self.stopDistance = stopDistance }

    func goTo(_ waypoint: CoordinatorWaypoint) async throws -> CoordinatorTaskResult {
        let epoch = controller.stopEpoch   // a cancel() from here on cancels this run even if it lands before the loop starts
        try Task.checkCancellation()
        let status = await controller.goTo(x: waypoint.x, z: waypoint.z, stopDistance: stopDistance, since: epoch)
        return ControllerResultMapper.result(status)
    }
    func cancel() { controller.stop() }
}

/// FindExecutor's drive step: go to within `stopDistance`, then turn to face the remembered position.
final class ControllerApproachDriver: ApproachDriver {
    private let controller: Controller
    private let poses: PoseSource
    init(controller: Controller, poses: PoseSource) { self.controller = controller; self.poses = poses }

    func approach(x: Double, z: Double, stopDistance: Double) async -> ApproachReport {
        let status = await controller.goTo(x: x, z: z, stopDistance: stopDistance)
        // Why a drive failed, for the Last find trace (guard holds vs turning vs driving, distance progress).
        let why = " (" + controller.lastRun.summary + ")"
        switch status {
        case .failed(.cancelled): return ApproachReport(outcome: .cancelled)
        case .failed(.timeout): return ApproachReport(outcome: .failed(reason: "timeout" + why))
        case .failed(.trackingLost): return ApproachReport(outcome: .failed(reason: "tracking lost" + why))
        case .running: return ApproachReport(outcome: .failed(reason: "controller did not finish"))
        case .done:
            guard !Task.isCancelled else { return ApproachReport(outcome: .cancelled) }
            let snapshot = poses.latest()
            guard snapshot.tracking == .normal, let pose = snapshot.pose else {
                return ApproachReport(outcome: .failed(reason: "tracking lost"))
            }
            let err = ControllerMath.headingError(pose: pose, targetX: x, targetZ: z)
            if abs(err) > ControllerTuning.rotateToleranceDeg {
                let rotation = await controller.rotateBy(err)
                if Task.isCancelled { return ApproachReport(outcome: .cancelled) }
                switch rotation {
                case .done: break
                case .running: return ApproachReport(outcome: .failed(reason: "controller did not finish"))
                case .failed(.cancelled): return ApproachReport(outcome: .cancelled)
                case .failed(.timeout): return ApproachReport(outcome: .failed(reason: "final turn timeout (" + controller.lastRun.summary + ")"))
                case .failed(.trackingLost): return ApproachReport(outcome: .failed(reason: "final turn tracking lost"))
                }
            }
            return ApproachReport(outcome: .arrived)
        }
    }
}

/// find_object: Retrieval over the stored tracks, then FindExecutor drives and checks arrival.
/// Refuses (spoken by the coordinator) when the image models are not installed.
final class FindRunnerAdapter: CoordinatorFinding {
    private let tracks: TrackProviding
    private let encoders: EncoderProvider
    private let driver: ApproachDriver
    private let speaker: CoordinatorSpeaking
    private let config: FindConfig
    private let stopMotion: () -> Void
    private let frame: CoordinatorFrameValidity
    /// Called with the trace of every find that ran the executor, aborted ones included, so a viewer can show it.
    private let onTrace: ((FindTrace) -> Void)?

    init(tracks: TrackProviding, encoders: EncoderProvider, driver: ApproachDriver, speaker: CoordinatorSpeaking,
         config: FindConfig = FindConfig(), frame: CoordinatorFrameValidity = TrustedFrame(),
         onTrace: ((FindTrace) -> Void)? = nil, stopMotion: @escaping () -> Void) {
        self.tracks = tracks; self.encoders = encoders; self.driver = driver; self.speaker = speaker
        self.config = config; self.stopMotion = stopMotion; self.frame = frame; self.onTrace = onTrace
    }

    func find(description: String) async throws -> CoordinatorTaskResult {
        try Task.checkCancellation()
        let set = encoders.encoders()
        guard set.isAvailable else {
            return .refused(spoken: set.unavailableMessage ?? ModelsMissingEncoderProvider.spoken)
        }
        let known = try tracks.allTracks()
        // Remembered positions come from storage, in the frame of an earlier session. Do not drive to them
        // until ARKit has recognised the saved map again.
        if !known.isEmpty && !frame.relocalized { return .refused(spoken: CoordinatorConfig.notRecognisedSpoken) }
        let executor = FindExecutor(retriever: Retriever(encoder: set.text, negatives: RetrievalConfig.negatives, arrivalNegatives: RetrievalConfig.arrivalNegatives), driver: driver, images: set.images, config: config)
        let result = await executor.find(phrase: description, tracks: known)
        onTrace?(result.trace)
        if Task.isCancelled || result.outcome == .aborted { return .cancelled }
        speaker.say(result.spoken)
        return .completed(summary: "\(result.outcome.rawValue): \(result.spoken)")
    }

    func cancel() { stopMotion() }
}

/// Explore and come-to-me are behind feature flags and off in this build. These keep the dependency struct
/// total; the coordinator refuses before they are ever called, and they refuse again if a flag is flipped
/// before the real runner is wired.
final class UnwiredExplorer: CoordinatorExploring {
    func explore(maxMinutes: Int?) async throws -> CoordinatorTaskResult {
        .refused(spoken: "Exploring is not wired up in this build.")
    }
    func cancel() {}
}
final class UnwiredComeToMe: CoordinatorComingToUser {
    func comeToMe() async throws -> CoordinatorTaskResult {
        .refused(spoken: "Coming to you is not wired up in this build.")
    }
    func cancel() {}
}

/// Obstacle level for the Controller from the latest depth corridor and ESP32 sonar telemetry.
/// Sonar flags win; a missing depth frame is treated as blind (slow), never as clear.
enum GuardStateMapper {
    static func state(corridor: CorridorResult?, sonar: SonarSample?) -> GuardState {
        switch ObstacleLogic.evaluate(corridor: corridor, sonar: sonar, direction: .forward).level {
        case .clear: return .clear
        case .slow: return .slow
        case .stop: return .stop
        }
    }
}

struct CoordinatorWiring {
    var poses: PoseSource
    var drive: DriveSink
    var guardState: () -> GuardState
    /// Guard for the coordinator's turns in place (find's final facing turn). nil = turns obey `guardState`.
    /// The app passes Scan here's turn guard (SensorCache.turnGuardState); goTo always obeys `guardState`.
    var turnGuard: (() -> GuardState)? = nil
    var waypointStore: WaypointStore
    var trackStore: TrackProviding
    var encoders: EncoderProvider
    var speaker: CoordinatorSpeaking
    var clock: CoordinatorClock = SystemCoordinatorClock()
    var features = RecallFeatureFlags()
    var controllerClock: () -> Double = { ProcessInfo.processInfo.systemUptime }
    var controllerSleep: (Double) async -> Void = { try? await Task.sleep(nanoseconds: UInt64($0 * 1_000_000_000)) }
    var config = CoordinatorConfig()
    /// False when the waypoint store fell back to memory; marks are then confirmed as temporary.
    var waypointsPersistent = true
    /// Which stored coordinates are valid in the current ARKit frame.
    var frame: CoordinatorFrameValidity = WorldFrameGate()
    /// Receives each find's trace, aborted ones included (the app connects the Robot tools viewer here).
    var onFindTrace: ((FindTrace) -> Void)? = nil
    /// The drive lease the coordinator and any other motion producer (Scan here) share. Defaults to a fresh one.
    var lease = DriveLease()
    /// Builds the explore task on the coordinator's Controller (ExploreRuntime.makeExplorer). nil = UnwiredExplorer.
    /// The coordinator still refuses explore unless `features.exploreEnabled`.
    var makeExplorer: ((Controller) -> CoordinatorExploring)? = nil

    /// `drive` must be a serialized sink (see `SerialDriveSink`) and `poses` a snapshot reader
    /// (see `PoseSnapshotBox`): the coordinator and Controller run off the main thread.
    func makeCoordinator() -> RobotCoordinator {
        let lease = self.lease
        let controller = makeController()
        let driver = ControllerApproachDriver(controller: controller, poses: poses)
        let finder = FindRunnerAdapter(tracks: trackStore, encoders: encoders, driver: driver, speaker: speaker, frame: frame,
                                       onTrace: onFindTrace, stopMotion: { controller.stop() })
        var cfg = config
        cfg.features = features
        return RobotCoordinator(
            dependencies: CoordinatorDependencies(
                explorer: makeExplorer?(controller) ?? UnwiredExplorer(), finder: finder, comer: UnwiredComeToMe(),
                navigator: ControllerNavigator(controller: controller),
                waypoints: StoreWaypointsAdapter(store: waypointStore, poses: poses, isPersistent: waypointsPersistent, frame: frame),
                drive: DriveStopAdapter(sink: drive), speaker: speaker, clock: clock,
                pose: ControllerPoseAdapter(source: poses), lease: lease, frame: frame,
                taught: StoreTaughtPlacesAdapter(store: waypointStore, frame: frame),
                legs: ControllerLegDriver(controller: controller, poses: poses)),
            config: cfg)
    }

    /// The coordinator's Controller: drives under the shared lease; goTo obeys `guardState`, rotateBy `turnGuard`.
    func makeController() -> Controller {
        Controller(poses: poses, sink: LeasedDriveSink(base: drive, lease: lease), guardState: guardState,
                   turnGuard: turnGuard, clock: controllerClock, sleep: controllerSleep)
    }
}
