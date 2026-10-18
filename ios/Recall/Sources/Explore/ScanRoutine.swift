import Foundation
#if canImport(PoseCore)
import PoseCore
#endif

enum DriveResult: Equatable {
    case reached
    case failed          // timeout or blocked; the robot is stopped
    case trackingLost
    case cancelled
}

/// Drive side of exploration. Backed by Controller (+ ObstacleGuard) in the app; fakes in tests.
protocol ExploreDrive: AnyObject {
    func goTo(x: Double, z: Double, stopDistance: Double) async -> DriveResult
    func rotateBy(_ deg: Double) async -> DriveResult
    func stop()
}

/// Perception hook: capture one keyframe at the current pose. Perception is built elsewhere.
protocol ScanHook: AnyObject {
    func captureKeyframe(stopIndex: Int, headingIndex: Int) async
}

protocol ExploreClock: AnyObject {
    func now() -> Double
    func sleep(_ seconds: Double) async
}

protocol ExplorePoseSource: AnyObject {
    func latest() -> (pose: Pose2D?, tracking: TrackingKind)
}

protocol ExploreGridSource: AnyObject {
    func currentMap() -> ExploreMap
    /// nil when the map is fresh enough to plan on; otherwise a short spoken reason (empty, stale...).
    func readiness() -> String?
}

extension ExploreGridSource {
    func readiness() -> String? { nil }
}

protocol WaypointSink: AnyObject {
    func addWaypoint(name: String, x: Double, z: Double, yawDeg: Double)
}

struct ScanConfig {
    var rotations = 4
    var stepDeg = 90.0
    var dwellS = 0.6     // PLACEHOLDER: settle time before each capture
}

struct ScanRoutine {
    var config = ScanConfig()

    /// Four 90 degree turns; at each heading: dwell, then capture. Ends back at the original heading.
    func run(stopIndex: Int, drive: ExploreDrive, hook: ScanHook, clock: ExploreClock,
             shouldAbort: () -> Bool) async -> DriveResult {
        for i in 0..<config.rotations {
            if shouldAbort() { return .cancelled }
            await clock.sleep(config.dwellS)
            await hook.captureKeyframe(stopIndex: stopIndex, headingIndex: i)
            if shouldAbort() { return .cancelled }
            let r = await drive.rotateBy(config.stepDeg)
            if r != .reached { return r }
        }
        return .reached
    }
}
