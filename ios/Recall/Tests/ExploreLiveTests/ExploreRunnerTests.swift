import XCTest
#if canImport(ExploreLive)
@testable import ExploreLive
#endif
#if canImport(ExploreCore)
@testable import ExploreCore
#endif
#if canImport(CoordinatorCore)
@testable import CoordinatorCore
#endif
#if canImport(ControllerCore)
@testable import ControllerCore
#endif
#if canImport(PoseCore)
import PoseCore
#endif
#if canImport(PlannerCore)
@testable import PlannerCore
#endif

// ExploreRunner (the coordinator's explore task) with fakes. No robot, no ARKit.

private final class Fakes: ExploreDrive, ExplorePoseSource, ExploreGridSource, ExploreClock, CoordinatorSpeaking {
    var map: ExploreMap
    var pose = Pose2D(x: 1.5, z: 1.5, yawDeg: 0)
    var tracking = TrackingKind.normal
    var notReady: String?
    var t = 0.0
    var said: [String] = []
    var rotations = 0
    var goTos = 0
    var stops = 0
    var onRotate: (() -> Void)?

    init(map: ExploreMap) { self.map = map }

    func goTo(x: Double, z: Double, stopDistance: Double) async -> DriveResult {
        goTos += 1; t += 5; pose = Pose2D(x: x, z: z, yawDeg: pose.yawDeg); return .reached
    }
    func rotateBy(_ deg: Double) async -> DriveResult { rotations += 1; onRotate?(); return Task.isCancelled ? .cancelled : .reached }
    func stop() { stops += 1 }
    func latest() -> (pose: Pose2D?, tracking: TrackingKind) { (tracking == .normal ? pose : nil, tracking) }
    func currentMap() -> ExploreMap { map }
    func readiness() -> String? { notReady }
    func now() -> Double { t }
    func sleep(_ seconds: Double) async { t += seconds }
    func say(_ text: String) { said.append(text) }
}

/// Fully known 1.5 m room: no frontier, so a run is the home scan and then "done".
private func closedRoom() -> ExploreMap {
    var m = ExploreMap(width: 30, height: 30, fill: .free)
    for r in 0..<30 { for c in 0..<30 where r < 2 || c < 2 || r >= 28 || c >= 28 { m.set(GridCell(col: c, row: r), .occupiedHigh) } }
    return m
}

final class ExploreRunnerTests: XCTestCase {
    private func runner(_ f: Fakes, limits: ExploreRunner.Limits = .init()) -> ExploreRunner {
        ExploreRunner(drive: f, poses: f, grid: f, clock: f, speaker: f, limits: limits)
    }

    func testRefusesWithoutTracking() async throws {
        let f = Fakes(map: closedRoom()); f.tracking = .limited
        let r = try await runner(f).explore(maxMinutes: nil)
        guard case .refused(let spoken) = r else { return XCTFail("\(r)") }
        XCTAssertTrue(spoken.contains("not tracking"))
        XCTAssertEqual(f.rotations + f.goTos, 0)
    }

    func testRefusesWhenMapIsEmptyOrStale() async throws {
        let f = Fakes(map: closedRoom()); f.notReady = "The map is empty: no depth frames yet."
        let r = try await runner(f).explore(maxMinutes: 1)
        XCTAssertEqual(r, .refused(spoken: "I can't explore yet. The map is empty: no depth frames yet."))
        XCTAssertEqual(f.rotations + f.goTos, 0)
    }

    func testRunAnnouncesAndCompletes() async throws {
        let f = Fakes(map: closedRoom())
        let r = try await runner(f).explore(maxMinutes: nil)
        guard case .completed(let summary) = r else { return XCTFail("\(r)") }
        XCTAssertTrue(summary?.contains("no reachable frontier") == true)
        XCTAssertEqual(f.rotations, 4, "home scan only")
        XCTAssertEqual(f.said.first, "Exploring for up to 2 minutes and 8 meters. Press stop any time.")
        XCTAssertTrue(f.said.last?.hasPrefix("Done exploring") == true)
    }

    func testRequestedTimeIsCappedByLimits() async throws {
        let f = Fakes(map: closedRoom())
        _ = try await runner(f, limits: .init(defaultMinutes: 2, maxMinutes: 5, maxDistanceM: 3)).explore(maxMinutes: 30)
        XCTAssertEqual(f.said.first, "Exploring for up to 5 minutes and 3 meters. Press stop any time.")
    }

    func testCancelDuringRunEndsCancelled() async throws {
        let f = Fakes(map: closedRoom())
        let r = runner(f)
        f.onRotate = { r.cancel() }
        let result = try await r.explore(maxMinutes: nil)
        XCTAssertEqual(result, .cancelled)
        XCTAssertEqual(f.rotations, 1)
        XCTAssertGreaterThan(f.stops, 0)
    }

    func testTaskCancellationStopsTheRun() async throws {
        let f = Fakes(map: closedRoom())
        let r = runner(f)
        let task = Task { try await r.explore(maxMinutes: nil) }
        f.onRotate = { task.cancel() }
        let result = try await task.value
        XCTAssertEqual(result, .cancelled)
        XCTAssertLessThanOrEqual(f.rotations, 1)
    }

    func testMapGoingStaleMidRunIsBlocked() async throws {
        let f = Fakes(map: closedRoom())
        f.onRotate = { f.notReady = "The map stopped updating 3 seconds ago." }
        let result = try await runner(f).explore(maxMinutes: nil)
        XCTAssertEqual(result, .blocked(reason: "my map is not usable. The map stopped updating 3 seconds ago."))
    }

    func testTrackingLossMidRunAsksForRescan() async throws {
        let f = Fakes(map: closedRoom())
        f.onRotate = { f.tracking = .notAvailable }
        let result = try await runner(f).explore(maxMinutes: nil)
        XCTAssertEqual(result, .blocked(reason: CoordinatorConfig.rescanReason))
    }

    func testControllerStatusMapping() {
        XCTAssertEqual(ControllerExploreDrive.map(.done), .reached)
        XCTAssertEqual(ControllerExploreDrive.map(.failed(.timeout)), .failed)
        XCTAssertEqual(ControllerExploreDrive.map(.failed(.cancelled)), .cancelled)
        XCTAssertEqual(ControllerExploreDrive.map(.failed(.trackingLost)), .trackingLost)
    }
}

// MARK: through the real RobotCoordinator

private final class Inert: CoordinatorFinding, CoordinatorNavigating, CoordinatorWaypoints, CoordinatorDriveStopping, CoordinatorPoseSource {
    var brakes = 0
    func find(description: String) async throws -> CoordinatorTaskResult { .cancelled }
    func goTo(_ waypoint: CoordinatorWaypoint) async throws -> CoordinatorTaskResult { .cancelled }
    func cancel() {}
    func lookup(_ name: String) -> CoordinatorWaypoint? { nil }
    func markHere(name: String) throws -> CoordinatorWaypoint { throw CancellationError() }
    func stop() { brakes += 1 }
    func tracking() -> CoordinatorTracking { .normal }
}

final class ExploreThroughCoordinatorTests: XCTestCase {
    private func coordinator(_ f: Fakes, _ inert: Inert, enabled: Bool) -> RobotCoordinator {
        var cfg = CoordinatorConfig()
        cfg.features.exploreEnabled = enabled
        let deps = CoordinatorDependencies(
            explorer: ExploreRunner(drive: f, poses: f, grid: f, clock: f, speaker: f), finder: inert,
            comer: UnwiredComeToMe(), navigator: inert, waypoints: inert, drive: inert, speaker: f,
            clock: SystemCoordinatorClock(), pose: inert)
        return RobotCoordinator(dependencies: deps, config: cfg)
    }

    func testFlagOffRefusesBeforeTheRunner() async throws {
        let f = Fakes(map: closedRoom()), inert = Inert()
        try await coordinator(f, inert, enabled: false).execute(.explore(maxMinutes: nil))
        XCTAssertEqual(f.rotations, 0)
        XCTAssertEqual(f.said, ["Sorry, exploring is turned off in this build."])
    }

    func testFlagOnRunsUnderTheCoordinator() async throws {
        let f = Fakes(map: closedRoom()), inert = Inert()
        let c = coordinator(f, inert, enabled: true)
        try await c.execute(.explore(maxMinutes: 1))
        XCTAssertEqual(f.rotations, 4)
        XCTAssertEqual(c.status.state, .idle)
        XCTAssertTrue(c.trace.contains { $0.event == "start" && $0.detail == "explore" })
    }

    func testGlobalStopEndsExplore() async throws {
        let f = Fakes(map: closedRoom()), inert = Inert()
        let c = coordinator(f, inert, enabled: true)
        f.onRotate = { c.stopAll() }
        try await c.execute(.explore(maxMinutes: nil))
        XCTAssertEqual(f.rotations, 1)
        XCTAssertGreaterThan(inert.brakes, 0)
        XCTAssertEqual(c.status.state, .idle)
        XCTAssertFalse(c.isBusy)
    }
}
