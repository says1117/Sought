import Foundation

// Coordinator contracts (plan v2 section 6.1 to 6.3). Pure Foundation. Everything the coordinator drives is a
// protocol here so tests use fakes. Real adapters (ARKit pose, DriveLink, Memory, Explore, Find, ComeToMe,
// Speech) are task T-039 and plug in through `CoordinatorDependenciesFactory` below.
// Hardware safety stays in the ESP32 and in the obstacle guard. Nothing in this layer enforces it.

/// How a sub-task ended. A thrown error from a runner is separate and maps to the `error` state.
enum CoordinatorTaskResult: Equatable {
    case completed(summary: String?)
    /// The task could not continue (controller gave up, no route, nothing found to drive to...).
    case blocked(reason: String)
    case cancelled
    /// The task cannot run in this build or state (e.g. image models not installed). The coordinator speaks
    /// `spoken`, returns to idle, and does not treat it as a failure.
    case refused(spoken: String)
}

enum CoordinatorTracking: String, Equatable {
    case normal, limited
    case notAvailable = "not_available"
}

/// A taught place the robot can drive to.
struct CoordinatorWaypoint: Equatable {
    var name: String
    var x: Double
    var z: Double
    var yawDeg: Double
    /// True when recorded in the coordinate frame in use right now. Defaults to false: a stored waypoint is
    /// only driven to after relocalization against the saved map.
    var inCurrentFrame: Bool
    /// True when recorded before the active saved map existed (that map was saved from a fresh scan), so
    /// relocalizing against it does not make this waypoint valid.
    var predatesMap: Bool
    init(name: String, x: Double, z: Double, yawDeg: Double = 0, inCurrentFrame: Bool = false, predatesMap: Bool = false) {
        self.name = name; self.x = x; self.z = z; self.yawDeg = yawDeg; self.inCurrentFrame = inCurrentFrame
        self.predatesMap = predatesMap
    }
}

/// Runner lifetime contract (all four motion protocols): check Task cancellation before issuing
/// any command and after every await; cancel() must promptly revoke command production. Returning
/// means all child work and callbacks are drained, with no later drive side effects. Dependencies
/// and synchronous methods must be thread-safe and must not synchronously wait for coordinator
/// re-entry from a different thread. The coordinator retains ownership until the runner returns.
/// Explore mode. The adapter wraps ExploreSession (`requestStop()` is `cancel()`).
protocol CoordinatorExploring: AnyObject {
    func explore(maxMinutes: Int?) async throws -> CoordinatorTaskResult
    func cancel()
}

/// Find an object. The adapter wraps FindExecutor plus its ApproachDriver.
protocol CoordinatorFinding: AnyObject {
    func find(description: String) async throws -> CoordinatorTaskResult
    func cancel()
}

/// Drive to the companion iPhone. The adapter wraps ComeToMeRunner.
protocol CoordinatorComingToUser: AnyObject {
    func comeToMe() async throws -> CoordinatorTaskResult
    func cancel()
}

/// Drive to a taught waypoint. The adapter wraps Controller.goTo.
protocol CoordinatorNavigating: AnyObject {
    func goTo(_ waypoint: CoordinatorWaypoint) async throws -> CoordinatorTaskResult
    func cancel()
}

/// Remote Teach (move / turn / scan here / save map from Sought). Motion follows the runner lifetime contract above:
/// it runs as a coordinator task under the drive lease and `cancel()` (STOP, pause, a manual tool) ends it.
protocol CoordinatorRemoteTeaching: AnyObject {
    /// Straight drive along the current heading; negative backs up (rear sonar guard). Summary is the short ack.
    func move(meters: Double) async throws -> CoordinatorTaskResult
    /// Turn in place with the turn guard; positive is left.
    func turn(degrees: Double) async throws -> CoordinatorTaskResult
    /// The Scan here routine. Summary is "scan done n/n".
    func scanHere() async throws -> CoordinatorTaskResult
    func cancel()
    /// Save the ARWorldMap and adopt it as Teach's Save map does. nil when saved, else why not.
    func saveMap() async -> String?
}

/// Keeps `CoordinatorDependencies` total for callers that do not wire Remote Teach.
final class UnwiredRemoteTeach: CoordinatorRemoteTeaching {
    func move(meters: Double) async throws -> CoordinatorTaskResult { .refused(spoken: "Remote teach is not wired up in this build.") }
    func turn(degrees: Double) async throws -> CoordinatorTaskResult { .refused(spoken: "Remote teach is not wired up in this build.") }
    func scanHere() async throws -> CoordinatorTaskResult { .refused(spoken: "Remote teach is not wired up in this build.") }
    func cancel() {}
    func saveMap() async -> String? { "not wired up in this build" }
}

/// Waypoint names to poses, and saving the current pose as a new waypoint.
protocol CoordinatorWaypoints: AnyObject {
    func lookup(_ name: String) -> CoordinatorWaypoint?
    /// Save the robot's current pose under `name`. Throws if there is no pose or the save fails.
    func markHere(name: String) throws -> CoordinatorWaypoint
    /// False when saves only live in memory (persistent storage failed to open). Spoken confirmations say so.
    var isPersistent: Bool { get }
}

extension CoordinatorWaypoints {
    var isPersistent: Bool { true }
}

/// Synchronous drive brake. Must be safe to call from any thread, at any time, many times.
protocol CoordinatorDriveStopping: AnyObject {
    func stop()
}

protocol CoordinatorSpeaking: AnyObject {
    func say(_ text: String)
}

/// Time source plus sleep, so tracking-loss timing is testable without real waiting.
protocol CoordinatorClock: AnyObject {
    func now() -> TimeInterval
    /// Throws `CancellationError` if the calling task is cancelled.
    func sleep(seconds: TimeInterval) async throws
}

protocol CoordinatorPoseSource: AnyObject {
    func tracking() -> CoordinatorTracking
}

struct CoordinatorDependencies {
    var explorer: CoordinatorExploring
    var finder: CoordinatorFinding
    var comer: CoordinatorComingToUser
    var navigator: CoordinatorNavigating
    var waypoints: CoordinatorWaypoints
    var drive: CoordinatorDriveStopping
    var speaker: CoordinatorSpeaking
    var clock: CoordinatorClock
    var pose: CoordinatorPoseSource
    /// Shared with the drive sink the runners use; the coordinator grants, revokes and holds it.
    var lease = DriveLease()
    /// Gate for stored coordinates (see `WorldFrameGate`).
    var frame: CoordinatorFrameValidity = TrustedFrame()
    /// Come to me v2: taught waypoints and routes, and the guarded go-to that drives each leg.
    var taught: CoordinatorTaughtPlaces = NoTaughtPlaces()
    var legs: CoordinatorLegDriving = UnwiredLegDriver()
    /// Remote Teach: move / turn / scan here / save map.
    var teach: CoordinatorRemoteTeaching = UnwiredRemoteTeach()
}

/// T-039 SEAM: the app shell implements this to build the real adapters (ARKit pose, DriveLink, Memory,
/// Sync, Speech, ExploreSession, FindExecutor, ComeToMeRunner, Controller). Nothing implements it yet.
protocol CoordinatorDependenciesFactory {
    func makeCoordinatorDependencies() -> CoordinatorDependencies
}

/// Monotonic-clock implementation for the real app. Pure Foundation, so it lives here.
final class SystemCoordinatorClock: CoordinatorClock {
    func now() -> TimeInterval { ProcessInfo.processInfo.systemUptime }
    func sleep(seconds: TimeInterval) async throws {
        try await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
    }
}
