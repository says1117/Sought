import XCTest
#if canImport(CoordinatorCore)
@testable import CoordinatorCore
#endif
#if canImport(PlannerCore)
@testable import PlannerCore
#endif
#if canImport(ControllerCore)
@testable import ControllerCore
#endif

// Come to me v2, waypoint version (T-066). Prefixed CTP because the RecallTests bundle compiles every test file
// into one module.

final class CTPPlaces: CoordinatorTaughtPlaces {
    var all: [TaughtPlace]
    var paths: [[String]]
    init(_ all: [TaughtPlace], routes: [[String]] = []) { self.all = all; self.paths = routes }
    func places() -> [TaughtPlace] { all }
    func routes() -> [[String]] { paths }
}

final class CTPFrame: CoordinatorFrameValidity {
    var relocalized: Bool
    var activeMapId: String?
    init(relocalized: Bool = true, mapId: String = "map_a") { self.relocalized = relocalized; self.activeMapId = mapId }
    func isInCurrentFrame(createdAt isoTimestamp: String) -> Bool { false }
}

/// Records every leg. With `hold` each leg drives once through `sink`, then waits for `release()`; it drives
/// again after release (which a revoked lease must drop) and reports the leg completed.
final class CTPLegs: CoordinatorLegDriving {
    struct Leg: Equatable { var x: Double; var z: Double; var stop: Double }
    private let lock = NSLock()
    private var log: [Leg] = []
    private var cancelCount = 0
    private var cont: CheckedContinuation<Void, Never>?
    var here: (x: Double, z: Double)? = (0, 0)
    var hold = false
    var cooperative = true
    var sink: DriveSink?
    var result: CoordinatorTaskResult = .completed(summary: "arrived")

    var legs: [Leg] { lock.lock(); defer { lock.unlock() }; return log }
    var cancels: Int { lock.lock(); defer { lock.unlock() }; return cancelCount }
    var waiting: Bool { lock.lock(); defer { lock.unlock() }; return cont != nil }

    func position() -> (x: Double, z: Double)? { here }
    func drive(x: Double, z: Double, stopDistance: Double) async throws -> CoordinatorTaskResult {
        lock.lock(); log.append(Leg(x: x, z: z, stop: stopDistance)); lock.unlock()
        guard hold else { return result }
        sink?.drive(left: 40, right: 40)
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in lock.lock(); cont = c; lock.unlock() }
        sink?.drive(left: 40, right: 40)
        return result
    }
    func release() { lock.lock(); let c = cont; cont = nil; lock.unlock(); c?.resume() }
    func cancel() {
        lock.lock(); cancelCount += 1; let co = cooperative; lock.unlock()
        if co { release() }
    }
}

final class CTPRig {
    let lease = DriveLease()
    let recorder = CoordLeaseRecorder()
    let speaker = CoordTestSpeaker(), clock = CoordTestClock(), pose = CoordTestPose()
    let legs = CTPLegs()
    let places: CTPPlaces
    let frame: CTPFrame
    let coordinator: RobotCoordinator

    static let a = TaughtPlace(id: "wpt_a", name: "hall", x: 0, z: 0, inCurrentFrame: false)
    static let b = TaughtPlace(id: "wpt_b", name: "door", x: 3, z: 0, inCurrentFrame: false)
    static let c = TaughtPlace(id: "wpt_c", name: "kitchen", x: 3, z: 3, inCurrentFrame: false)
    static let d = TaughtPlace(id: "wpt_d", name: "office", x: -4, z: 4, inCurrentFrame: false)

    init(places: [TaughtPlace] = [a, b, c, d], routes: [[String]] = [["wpt_a", "wpt_b", "wpt_c"]],
         frame: CTPFrame = CTPFrame(), config: CoordinatorConfig = CoordinatorConfig()) {
        self.places = CTPPlaces(places, routes: routes)
        self.frame = frame
        legs.sink = LeasedDriveSink(base: recorder, lease: lease)
        coordinator = RobotCoordinator(dependencies: CoordinatorDependencies(
            explorer: CoordTestRunner(), finder: CoordTestRunner(), comer: CoordTestRunner(), navigator: CoordTestRunner(),
            waypoints: CoordTestWaypoints(), drive: DriveStopAdapter(sink: recorder), speaker: speaker, clock: clock, pose: pose,
            lease: lease, frame: frame, taught: self.places, legs: legs), config: config)
    }

    @discardableResult
    func launch(_ target: ComeToMeTarget) async -> Task<Void, Error> {
        let co = coordinator
        let t = Task { try await co.comeToMe(target: target) }
        await coordSettle()
        return t
    }
}

final class ComeToPlacePlannerTests: XCTestCase {
    private let s = ComeToMeSettings()
    private let all = [CTPRig.a, CTPRig.b, CTPRig.c, CTPRig.d]

    func testFollowsTheTaughtRouteFromTheNearestWaypoint() {
        let p = ComeToPlacePlanner.plan(from: (0.2, 0.1), targetPlaceId: "wpt_c", goal: (3, 3, "kitchen"),
                                        places: all, routes: [["wpt_a", "wpt_b", "wpt_c"]], settings: s)
        XCTAssertEqual(p.route, ["hall", "door", "kitchen"])
        XCTAssertEqual(p.legs.map(\.label), ["hall", "door", "kitchen"])
        XCTAssertEqual(p.legs.map(\.stopDistance), [0.3, 0.3, 1.0])
    }

    func testRouteWorksBackwardsAndAcrossJoinedRoutes() {
        let p = ComeToPlacePlanner.plan(from: (3.1, 2.9), targetPlaceId: "wpt_a", goal: (0, 0, "hall"),
                                        places: all, routes: [["wpt_a", "wpt_b"], ["wpt_b", "wpt_c"]], settings: s)
        XCTAssertEqual(p.route, ["kitchen", "door", "hall"])
        XCTAssertEqual(p.legs.last, ComeToPlaceLeg(x: 0, z: 0, stopDistance: 1.0, label: "hall"))
    }

    func testDrivesDirectWhenNoRouteConnects() {
        let p = ComeToPlacePlanner.plan(from: (0, 0), targetPlaceId: "wpt_d", goal: (-4, 4, "office"),
                                        places: all, routes: [["wpt_a", "wpt_b", "wpt_c"]], settings: s)
        XCTAssertNil(p.route)
        XCTAssertEqual(p.legs, [ComeToPlaceLeg(x: -4, z: 4, stopDistance: 1.0, label: "office")])
    }

    func testDrivesDirectWhenNearestWaypointIsTheTarget() {
        let p = ComeToPlacePlanner.plan(from: (2.9, 2.5), targetPlaceId: "wpt_c", goal: (3, 3, "kitchen"),
                                        places: all, routes: [["wpt_a", "wpt_b", "wpt_c"]], settings: s)
        XCTAssertNil(p.route)
        XCTAssertEqual(p.legs.count, 1)
    }

    func testRouteEndsAtAWaypointAlreadyInsideTheStopRadius() {
        let e = TaughtPlace(id: "wpt_e", name: "counter", x: 3, z: 2.5, inCurrentFrame: false)
        let p = ComeToPlacePlanner.plan(from: (0, 0), targetPlaceId: "wpt_c", goal: (3, 3, "kitchen"),
                                        places: all + [e], routes: [["wpt_a", "wpt_b", "wpt_e", "wpt_c"]], settings: s)
        XCTAssertEqual(p.legs.map(\.label), ["hall", "door", "kitchen"])
    }

    func testStopShortIsConfigurable() {
        var custom = s; custom.stopShortM = 0.6
        let p = ComeToPlacePlanner.plan(from: (0, 0), targetPlaceId: "wpt_d", goal: (-4, 4, "office"),
                                        places: all, routes: [], settings: custom)
        XCTAssertEqual(p.legs.last?.stopDistance, 0.6)
    }
}

final class ComeToPlaceCoordinatorTests: XCTestCase {
    func testPlannerCallDrivesTheRouteAndStopsOneMetreShort() async throws {
        let r = CTPRig()
        try await r.coordinator.execute(.comeToWaypoint(name: "Kitchen"))
        XCTAssertEqual(r.legs.legs, [.init(x: 0, z: 0, stop: 0.3), .init(x: 3, z: 0, stop: 0.3), .init(x: 3, z: 3, stop: 1.0)])
        XCTAssertEqual(r.coordinator.status, .idle)
        XCTAssertEqual(r.coordinator.trace.last?.event, "done")
        XCTAssertTrue(r.coordinator.trace.last?.detail.contains("route hall > door > kitchen") ?? false)
        XCTAssertEqual(r.speaker.said.last, "I'm here, near the kitchen.")
    }

    func testWaypointIdFromRemoteCommandDrivesDirectWithoutARoute() async throws {
        let r = CTPRig()
        try await r.coordinator.comeToMe(target: .waypointId("wpt_d"))
        XCTAssertEqual(r.legs.legs, [.init(x: -4, z: 4, stop: 1.0)])
        XCTAssertTrue(r.coordinator.trace.last?.detail.contains("via direct") ?? false)
    }

    func testConfiguredStopDistanceReachesTheLastLeg() async throws {
        var cfg = CoordinatorConfig(); cfg.comeToMe.stopShortM = 1.5
        let r = CTPRig(config: cfg)
        try await r.coordinator.comeToMe(target: .waypointId("wpt_d"))
        XCTAssertEqual(r.legs.legs.last?.stop, 1.5)
    }

    func testRefusesWhenNotRelocalized() async throws {
        let r = CTPRig(frame: CTPFrame(relocalized: false))
        try await r.coordinator.comeToMe(target: .waypointName("kitchen"))
        XCTAssertTrue(r.legs.legs.isEmpty)
        XCTAssertEqual(r.speaker.said, [CoordinatorConfig.notRecognisedSpoken])
        XCTAssertEqual(r.coordinator.trace.last?.event, "refused")
        XCTAssertFalse(r.coordinator.isBusy)
    }

    func testPlaceTaughtThisSessionWorksWithoutRelocalizationAndSkipsStoredOnes() async throws {
        var fresh = CTPRig.c; fresh.inCurrentFrame = true
        let r = CTPRig(places: [CTPRig.a, CTPRig.b, fresh], frame: CTPFrame(relocalized: false))
        try await r.coordinator.comeToMe(target: .waypointName("kitchen"))
        // hall and door are from an earlier session, so they are not used as legs: direct to the kitchen.
        XCTAssertEqual(r.legs.legs, [.init(x: 3, z: 3, stop: 1.0)])
    }

    func testRefusesUnknownWaypoint() async throws {
        let r = CTPRig()
        try await r.coordinator.comeToMe(target: .waypointId("wpt_nope"))
        try await r.coordinator.execute(.comeToWaypoint(name: "attic"))
        XCTAssertTrue(r.legs.legs.isEmpty)
        XCTAssertEqual(r.speaker.said, ["I don't know that place.", "I don't know a place called attic."])
    }

    func testPoseWithMatchingMapDrivesToThePose() async throws {
        let r = CTPRig()
        try await r.coordinator.comeToMe(target: .pose(x: 3.5, z: 3.2, mapId: "map_a"))
        XCTAssertEqual(r.legs.legs.map(\.stop), [0.3, 0.3, 1.0])
        XCTAssertEqual(r.legs.legs.last, .init(x: 3.5, z: 3.2, stop: 1.0))
        XCTAssertEqual(r.speaker.said.last, "I'm here.")
    }

    func testPoseRefusedOnMapMismatchNoRelocalizationOrOutsideTaughtArea() async throws {
        let r = CTPRig()
        try await r.coordinator.comeToMe(target: .pose(x: 3, z: 3, mapId: "map_b"))
        try await r.coordinator.comeToMe(target: .pose(x: 30, z: 30, mapId: "map_a"))
        r.frame.relocalized = false
        try await r.coordinator.comeToMe(target: .pose(x: 3, z: 3, mapId: "map_a"))
        XCTAssertTrue(r.legs.legs.isEmpty)
        XCTAssertEqual(r.speaker.said, [ComeToPlaceRunner.mapMismatchSpoken, ComeToPlaceRunner.poseOutsideSpoken,
                                        CoordinatorConfig.notRecognisedSpoken])
    }

    func testNoPoseAtRunTimeBlocksWithRescan() async throws {
        let r = CTPRig()
        r.legs.here = nil
        try await r.coordinator.comeToMe(target: .waypointName("kitchen"))
        XCTAssertTrue(r.legs.legs.isEmpty)
        XCTAssertEqual(r.coordinator.status, CoordinatorStatus(state: .blocked, task: CoordinatorConfig.rescanReason))
    }

    func testBlockedLegEndsTheTaskWithoutDrivingFurther() async throws {
        let r = CTPRig()
        r.legs.result = .blocked(reason: "I couldn't get there in time")
        try await r.coordinator.comeToMe(target: .waypointName("kitchen"))
        XCTAssertEqual(r.legs.legs.count, 1)
        XCTAssertEqual(r.coordinator.status.state, .blocked)
    }

    func testStopDuringTheTaskCancelsAndNoFurtherLegRuns() async throws {
        let r = CTPRig()
        r.legs.hold = true
        let t = await r.launch(.waypointName("kitchen"))
        XCTAssertTrue(r.legs.waiting)
        XCTAssertEqual(r.coordinator.status, CoordinatorStatus(state: .comingToUser, task: "come to: kitchen"))
        r.coordinator.stopAll()
        try await t.value
        await coordSettle()
        XCTAssertEqual(r.legs.legs.count, 1)
        XCTAssertGreaterThanOrEqual(r.legs.cancels, 1)
        XCTAssertGreaterThanOrEqual(r.recorder.stops, 1)
        XCTAssertEqual(r.coordinator.status, .idle)
        XCTAssertFalse(r.coordinator.isBusy)
        XCTAssertFalse(r.speaker.said.contains { $0.hasPrefix("I'm here") })
    }

    func testRevokedLeaseDropsDriveFromALegThatIgnoresCancel() async throws {
        let r = CTPRig()
        r.legs.hold = true
        r.legs.cooperative = false
        let t = await r.launch(.waypointName("kitchen"))
        XCTAssertEqual(r.recorder.drives, [40])        // driving under a live lease
        r.coordinator.stopAll()
        r.legs.release()                               // the stale leg tries to drive again
        try await t.value
        await coordSettle()
        XCTAssertEqual(r.recorder.drives, [40])        // dropped at the drive boundary
        XCTAssertEqual(r.legs.legs.count, 1)
        XCTAssertFalse(r.coordinator.isBusy)
    }

    func testOneTaskAtATime() async throws {
        let r = CTPRig()
        r.legs.hold = true
        let first = await r.launch(.waypointName("kitchen"))
        let second = await r.launch(.waypointName("office"))
        let third = await r.launch(.waypointName("door"))
        XCTAssertEqual(r.speaker.said, ["I'm busy with come to: kitchen. I'll do that next.",
                                        "I'm busy and already have something waiting. Say stop first."])
        r.coordinator.stopAll()
        _ = try await (first.value, second.value, third.value)
        XCTAssertEqual(r.legs.legs.count, 1)
    }

    func testRefusedWhileManualControlIsOpen() async throws {
        let r = CTPRig()
        r.coordinator.beginManualControl("Teach")
        try await r.coordinator.comeToMe(target: .waypointName("kitchen"))
        XCTAssertTrue(r.legs.legs.isEmpty)
        XCTAssertEqual(r.speaker.said.last, "A manual control screen is open. Close it first, then ask me again.")
    }

    func testFeatureFlagOffRefuses() async throws {
        var cfg = CoordinatorConfig(); cfg.features.comeToPlaceEnabled = false
        let r = CTPRig(config: cfg)
        try await r.coordinator.execute(.comeToWaypoint(name: "kitchen"))
        XCTAssertTrue(r.legs.legs.isEmpty)
        XCTAssertEqual(r.coordinator.trace.last?.detail, "come_to_me: disabled by feature flag")
    }
}
