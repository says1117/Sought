import XCTest
import simd
#if canImport(CoordinatorCore)
@testable import CoordinatorCore
#endif
#if canImport(PlannerCore)
@testable import PlannerCore
#endif
#if canImport(ControllerCore)
@testable import ControllerCore
#endif
#if canImport(PoseCore)
import PoseCore
#endif
#if canImport(Memory)
import Memory
#endif
#if canImport(Retrieval)
import Retrieval
#endif
#if canImport(FindExecutor)
import FindExecutor
#endif
#if canImport(PerceptionCore)
import PerceptionCore
#endif
#if canImport(SyncCore)
import SyncCore
#endif
#if canImport(TeachCore)
import TeachCore
#endif
#if canImport(ObstacleGuardCore)
import ObstacleGuardCore
#endif

// MARK: fakes (prefixed Coord because the RecallTests bundle compiles every test file into one module)

/// A robot that is both the pose source and the drive sink. Each drive command moves it one step.
final class CoordSimRobot: PoseSource, DriveSink {
    private let lock = NSLock()
    private var x = 0.0, z = 0.0, yaw = 0.0
    private(set) var commands: [(left: Int, right: Int)] = []
    private(set) var stopCount = 0
    var trackingKind: TrackingKind = .normal

    var position: (x: Double, z: Double) { lock.lock(); defer { lock.unlock() }; return (x, z) }
    var movingCommands: Int { lock.lock(); defer { lock.unlock() }; return commands.filter { $0.left != 0 || $0.right != 0 }.count }
    var allCommands: [(left: Int, right: Int)] { lock.lock(); defer { lock.unlock() }; return commands }
    var stops: Int { lock.lock(); defer { lock.unlock() }; return stopCount }

    func latest() -> (pose: Pose2D?, tracking: TrackingKind) {
        lock.lock(); defer { lock.unlock() }
        return (Pose2D(x: x, z: z, yawDeg: yaw), trackingKind)
    }
    func drive(left: Int, right: Int) {
        lock.lock(); defer { lock.unlock() }
        commands.append((left, right))
        let lin = Double(left + right) / 2, ang = Double(right - left) / 2
        yaw = PoseMath.normalizeDegrees(yaw + ang * 0.04)
        let r = yaw * .pi / 180
        x += -sin(r) * lin * 0.0005
        z += -cos(r) * lin * 0.0005
    }
    func stop() { lock.lock(); stopCount += 1; commands.append((0, 0)); lock.unlock() }
}

final class CoordFixedTextEncoder: TextEncoder {
    func encode(_ text: String) throws -> [Float] { [1, 0, 0, 0] }
}
final class CoordFixedImageEmbedder: ImageEmbedder {
    func captureEmbeddings(around position: SIMD3<Float>, count: Int, cropScale: Float) async throws -> [[Float]] {
        Array(repeating: [1, 0, 0, 0], count: count)
    }
}

final class CoordTickClock {
    private let lock = NSLock()
    private var t = 0.0
    func tick() -> Double { lock.lock(); defer { lock.unlock() }; t += 0.1; return t }
}

struct CoordIntegrationRig {
    let robot = CoordSimRobot()
    let speaker = CoordTestSpeaker()
    let clock = CoordTestClock()
    let tracks: TrackStore
    let waypoints: WaypointStore
    let coordinator: RobotCoordinator

    init(encoders: EncoderProvider, features: RecallFeatureFlags = RecallFeatureFlags(),
         unreachableTarget: Bool = false, frame: CoordinatorFrameValidity = TrustedFrame(),
         trackMapId: String = TrackStore.defaultMapId) throws {
        tracks = try TrackStore(path: ":memory:", scope: { frame.activeMapId })
        waypoints = try WaypointStore(path: ":memory:")
        try tracks.upsert(Track(id: "obj_1", position: SIMD3(0, 0, unreachableTarget ? -500 : -2),
                                embedding: [1, 0, 0, 0], sightings: 3, persistence: 0.8), mapId: trackMapId)
        try waypoints.addWaypoint(name: "kitchen", pose: Pose2D(x: 0, z: -1, yawDeg: 0))
        let ticks = CoordTickClock()
        var wiring = CoordinatorWiring(
            poses: robot, drive: robot, guardState: { .clear }, waypointStore: waypoints, trackStore: tracks,
            encoders: encoders, speaker: speaker, clock: clock)
        wiring.features = features
        wiring.frame = frame
        wiring.controllerClock = { ticks.tick() }
        wiring.controllerSleep = { _ in try? await Task.sleep(nanoseconds: unreachableTarget ? 2_000_000 : 20_000) }
        coordinator = wiring.makeCoordinator()
    }

    static func working() -> EncoderProvider {
        StaticEncoderProvider(set: EncoderSet(text: CoordFixedTextEncoder(), images: CoordFixedImageEmbedder(),
                                              isAvailable: true, unavailableMessage: nil))
    }
}

final class CoordTaskBox { var task: Task<Void, Error>? }

/// Fixed pose: commands cannot turn this robot, so a requested final turn must time out.
final class CoordFixedPoseRobot: PoseSource, DriveSink {
    var trackingKind: TrackingKind = .normal
    var loseTrackingOnStop = false
    func latest() -> (pose: Pose2D?, tracking: TrackingKind) {
        (trackingKind == .normal ? Pose2D(x: 0, z: 0, yawDeg: 0) : nil, trackingKind)
    }
    func drive(left: Int, right: Int) {}
    func stop() { if loseTrackingOnStop { trackingKind = .notAvailable } }
}

final class CoordinatorIntegrationTests: XCTestCase {
    func testFinalFacingTimeoutIsNotReportedAsArrived() async {
        let robot = CoordFixedPoseRobot()
        var time = 0.0
        let controller = Controller(poses: robot, sink: robot,
                                    clock: { time += 1; return time }, sleep: { _ in await Task.yield() })
        let report = await ControllerApproachDriver(controller: controller, poses: robot)
            .approach(x: 1, z: 0, stopDistance: 2)
        XCTAssertEqual(report.outcome, .failed(reason: "timeout"))
    }

    func testMissingTrackingAfterTranslationIsNotReportedAsArrived() async {
        let robot = CoordFixedPoseRobot()
        robot.loseTrackingOnStop = true
        var time = 0.0
        let controller = Controller(poses: robot, sink: robot,
                                    clock: { time += 1; return time }, sleep: { _ in await Task.yield() })
        let report = await ControllerApproachDriver(controller: controller, poses: robot)
            .approach(x: 1, z: 0, stopDistance: 2)
        XCTAssertEqual(report.outcome, .failed(reason: "tracking lost"))
    }

    func testRunningControllerIsNotReportedAsCompleted() {
        XCTAssertEqual(ControllerResultMapper.result(.running), .blocked(reason: "The controller did not finish"))
    }

    func testTypedFindDrivesThenSpeaksResult() async throws {
        let rig = try CoordIntegrationRig(encoders: CoordIntegrationRig.working())
        try await rig.coordinator.execute(.findObject(description: "blue backpack"))
        XCTAssertGreaterThan(rig.robot.movingCommands, 5, "should have driven toward the remembered position")
        XCTAssertEqual(rig.robot.allCommands.last?.left, 0, "ends stopped")
        XCTAssertEqual(rig.robot.allCommands.last?.right, 0)
        XCTAssertLessThan(abs(rig.robot.position.z + 1.2), 0.5, "stopped about 0.8 m short of the object at z=-2")
        XCTAssertTrue(rig.speaker.said.contains { $0.hasPrefix("Found blue backpack") }, "\(rig.speaker.said)")
        XCTAssertEqual(rig.coordinator.status, .idle)
    }

    // Real adapters with a real gate: stored targets are refused until the saved map is recognised.
    func testStoredWaypointAndFindRefusedUntilRelocalizedThenAllowed() async throws {
        let gate = WorldFrameGate(now: { Date().addingTimeInterval(3600) })   // this frame began after the stored rows
        let rig = try CoordIntegrationRig(encoders: CoordIntegrationRig.working(), frame: gate, trackMapId: "map-A")
        gate.sessionStarted(loadedSavedMap: true, mapId: "map-A")
        try await rig.coordinator.execute(.goToWaypoint(name: "kitchen"))
        try await rig.coordinator.execute(.findObject(description: "blue backpack"))
        XCTAssertEqual(rig.robot.movingCommands, 0, "no motion toward stored coordinates")
        XCTAssertEqual(rig.speaker.said.filter { $0 == CoordinatorConfig.notRecognisedSpoken }.count, 2, "\(rig.speaker.said)")

        gate.update(tracking: .limited, mapping: .limited, relocalizing: true); gate.update(tracking: .normal, mapping: .mapped)
        try await rig.coordinator.execute(.goToWaypoint(name: "kitchen"))
        XCTAssertGreaterThan(rig.robot.movingCommands, 0)
    }

    func testWaypointOlderThanTheMapIsRefusedEvenWhenRelocalized() async throws {
        let gate = WorldFrameGate(now: { Date().addingTimeInterval(3600) })
        let rig = try CoordIntegrationRig(encoders: CoordIntegrationRig.working(), frame: gate, trackMapId: "map-A")
        // map-A was saved from a fresh scan after "kitchen" was marked under an older map.
        gate.sessionStarted(loadedSavedMap: true, mapId: "map-A", waypointCutoff: Date().addingTimeInterval(1800))
        gate.update(tracking: .limited, mapping: .limited, relocalizing: true); gate.update(tracking: .normal, mapping: .mapped)
        XCTAssertTrue(gate.relocalized)
        try await rig.coordinator.execute(.goToWaypoint(name: "kitchen"))
        XCTAssertEqual(rig.robot.movingCommands, 0, "no motion toward a waypoint from another map's frame")
        XCTAssertTrue(rig.speaker.said.contains(CoordinatorConfig.notRecognisedSpoken), "\(rig.speaker.said)")
    }

    func testWaypointMarkedThisSessionIsAllowedWithoutRelocalization() async throws {
        let gate = WorldFrameGate(now: { Date().addingTimeInterval(-5) })
        let rig = try CoordIntegrationRig(encoders: CoordIntegrationRig.working(), frame: gate)
        gate.sessionStarted(loadedSavedMap: false)
        // "kitchen" was inserted by the rig just now, i.e. after this frame started.
        try await rig.coordinator.execute(.goToWaypoint(name: "kitchen"))
        XCTAssertGreaterThan(rig.robot.movingCommands, 0)
    }

    func testModelsMissingRefusesFindButGoToWaypointWorks() async throws {
        let rig = try CoordIntegrationRig(encoders: ModelsMissingEncoderProvider())
        try await rig.coordinator.execute(.findObject(description: "blue backpack"))
        XCTAssertEqual(rig.robot.movingCommands, 0)
        XCTAssertTrue(rig.speaker.said.contains { $0.contains("image models are not installed") }, "\(rig.speaker.said)")
        XCTAssertEqual(rig.coordinator.status, .idle)
        XCTAssertFalse(rig.coordinator.isBusy)

        try await rig.coordinator.execute(.goToWaypoint(name: "kitchen"))
        XCTAssertGreaterThan(rig.robot.movingCommands, 3)
        XCTAssertLessThan(abs(rig.robot.position.z + 0.7), 0.3, "within the 0.3 m stop distance of the waypoint")

        try await rig.coordinator.execute(.markWaypoint(name: "desk"))
        XCTAssertNotNil(try rig.waypoints.waypoint(named: "desk"))
        try await rig.coordinator.execute(.say(text: "hello"))
        XCTAssertEqual(rig.speaker.said.last, "hello")
    }

    func testStopDuringFindSendsDriveStopAndReturnsIdle() async throws {
        let rig = try CoordIntegrationRig(encoders: CoordIntegrationRig.working(), unreachableTarget: true)
        let co = rig.coordinator
        let task = Task { try await co.execute(.findObject(description: "blue backpack")) }
        for _ in 0..<500 where rig.robot.movingCommands == 0 { try await Task.sleep(nanoseconds: 2_000_000) }
        XCTAssertGreaterThan(rig.robot.movingCommands, 0)
        XCTAssertEqual(co.status.state, .finding)

        let stopsBefore = rig.robot.stops
        co.stopAll()
        XCTAssertGreaterThan(rig.robot.stops, stopsBefore, "stopAll brakes synchronously")
        XCTAssertEqual(co.status, .idle)
        try await task.value
        let movingAfter = rig.robot.movingCommands
        try await Task.sleep(nanoseconds: 60_000_000)
        XCTAssertEqual(rig.robot.movingCommands, movingAfter, "no drive commands after stop")
        XCTAssertFalse(co.isBusy)
        XCTAssertEqual(co.status, .idle)
    }

    func testExploreAndComeToMeRefusedWhenFlaggedOff() async throws {
        let rig = try CoordIntegrationRig(encoders: CoordIntegrationRig.working())
        try await rig.coordinator.execute(.explore(maxMinutes: 5))
        XCTAssertTrue(rig.speaker.said.last?.contains("exploring is turned off in this build") == true, "\(rig.speaker.said)")
        try await rig.coordinator.execute(.comeToMe)
        XCTAssertTrue(rig.speaker.said.last?.contains("turned off in this build") == true)
        XCTAssertEqual(rig.coordinator.status, .idle)
        XCTAssertFalse(rig.coordinator.isBusy)
        XCTAssertEqual(rig.robot.movingCommands, 0)
        XCTAssertFalse(RecallFeatureFlags().exploreEnabled)
        XCTAssertFalse(RecallFeatureFlags().comeToMeEnabled)
    }

    func testHeartbeatStateSequenceAndContractBody() async throws {
        let rig = try CoordIntegrationRig(encoders: CoordIntegrationRig.working())
        let hb = CoordinatorHeartbeatSource(now: { Date(timeIntervalSince1970: 1_760_000_000) })
        hb.update(sensors: .init(pose: Pose2D(x: 1.2, z: -3.4, yawDeg: 92.5), tracking: .normal, mapping: .mapped,
                                 frontCm: 87, rearCm: nil, phoneBattery: 0.62, firmwareLink: true))
        final class Log { var seen: [WireHeartbeat] = [] }
        let log = Log()
        rig.coordinator.onChange = { hb.update(status: $0); log.seen.append(hb.snapshot()) }
        XCTAssertEqual(hb.snapshot().state, .idle)
        XCTAssertEqual(hb.snapshot().task, "")

        try await rig.coordinator.execute(.findObject(description: "blue backpack"))
        XCTAssertEqual(log.seen.map(\.state), [.finding, .idle])
        XCTAssertEqual(log.seen.map(\.task), ["find: blue backpack", ""])
        let body = String(decoding: try SyncJSON.encode(log.seen[0]), as: UTF8.self)
        XCTAssertTrue(body.contains("\"state\":\"finding\""), body)
        XCTAssertTrue(body.contains("\"rear_cm\":999"), body)
        XCTAssertTrue(body.contains("\"firmware_link\":true"), body)
        XCTAssertTrue(body.contains("\"yaw_deg\":92.5"), body)

        // Tracking loss surfaces as blocked with the rescan reason.
        let rig2 = try CoordIntegrationRig(encoders: CoordIntegrationRig.working(), unreachableTarget: true)
        let hb2 = CoordinatorHeartbeatSource()
        let log2 = Log()
        rig2.coordinator.onChange = { hb2.update(status: $0); log2.seen.append(hb2.snapshot()) }
        let co = rig2.coordinator
        let t = Task { try await co.execute(.findObject(description: "blue backpack")) }
        for _ in 0..<500 where rig2.robot.movingCommands == 0 { try await Task.sleep(nanoseconds: 2_000_000) }
        rig2.robot.trackingKind = .notAvailable
        await rig2.clock.advance(by: 1.5)
        try await t.value
        XCTAssertEqual(log2.seen.map(\.state).prefix(2), [.finding, .blocked])
        XCTAssertEqual(log2.seen.dropFirst().first?.task, "need a rescan")
    }

    // MARK: liveness fixes in RobotCoordinator

    func testRunnerThatNeverReturnsIsForceReleasedAfterDrainTimeout() async throws {
        let r = CoordRig()
        r.finder.finishOnCancel = false
        let first = await r.launch(.findObject(description: "keys"))
        r.coordinator.stopAll()
        XCTAssertTrue(r.coordinator.isBusy)
        try await r.coordinator.execute(.goToWaypoint(name: "kitchen"))
        XCTAssertTrue(r.speaker.said.last?.contains("still stopping") == true, "refused while draining")

        await r.clock.advance(by: 3.5)
        XCTAssertFalse(r.coordinator.isBusy, "released after the drain timeout")
        XCTAssertEqual(r.coordinator.status, .idle)
        XCTAssertTrue(r.speaker.said.contains { $0.contains("did not finish cleanly") }, "\(r.speaker.said)")
        XCTAssertTrue(r.coordinator.trace.contains { $0.event == "drain-timeout" })
        XCTAssertGreaterThanOrEqual(r.drive.stops, 2, "STOP re-sent on release")
        try await first.value                           // the original caller is released too

        let next = await r.launch(.goToWaypoint(name: "kitchen"))
        XCTAssertEqual(r.navigator.started, ["go:kitchen"], "new requests are accepted again")
        r.navigator.finish(.completed(summary: nil))
        try await next.value
        r.finder.finish(.cancelled)                      // late return of the stuck runner changes nothing
        await coordSettle()
        XCTAssertEqual(r.coordinator.status, .idle)
    }

    func testQueuedRequestCancelledByItsCallerLeavesThePendingSlot() async throws {
        let r = CoordRig()
        let first = await r.launch(.findObject(description: "keys"))
        let box = CoordTaskBox()
        r.speaker.onSay = { if $0.contains("do that next") { box.task?.cancel() } }
        let co = r.coordinator
        let second = Task { try await co.execute(.goToWaypoint(name: "kitchen")) }
        box.task = second
        _ = try? await second.value
        await coordSettle()
        XCTAssertFalse(r.coordinator.hasPending, "a cancelled queued request must not stay in the slot")
        XCTAssertTrue(r.coordinator.trace.contains { $0.event == "cancelled" && $0.detail.contains("while queued") })

        r.finder.finish(.completed(summary: nil))
        try await first.value
        await coordSettle()
        XCTAssertEqual(r.navigator.started, [], "the cancelled request never runs")
        XCTAssertEqual(r.coordinator.status, .idle)
        // and the slot is free for a new queued request
        let third = await r.launch(.findObject(description: "mug"))
        XCTAssertEqual(r.finder.started.last, "find:mug")
        r.finder.finish(.completed(summary: nil))
        try await third.value
    }

    // MARK: adapters and memory

    func testIngestorBuildsTracksThatRetrievalCanFind() throws {
        let store = try TrackStore(path: ":memory:")
        var n = 0
        let ing = MemoryIngestor(store: store, newId: { n += 1; return "obj_t\(n)" })
        func obj(_ x: Float, _ e: [Float]) -> PerceivedObject {
            PerceivedObject(observation: Observation(position: SIMD3(x, 0, -2), embedding: e, confidence: 0.9, time: 1),
                            heightAboveFloor: 0.2, box: NormBox(x: 0, y: 0, w: 1, h: 1), origin: .grid, thumbnailJPEG: nil)
        }
        XCTAssertEqual(try ing.ingest([obj(0, [1, 0, 0, 0]), obj(3, [0, 1, 0, 0])]), .init(matched: 0, created: 2))
        XCTAssertEqual(try ing.ingest([obj(0.05, [1, 0, 0, 0])]), .init(matched: 1, created: 0))
        let tracks = try store.allTracks()
        XCTAssertEqual(tracks.count, 2)
        XCTAssertEqual(tracks.first { $0.id == "obj_t1" }?.sightings, 2)
        XCTAssertTrue(tracks.first { $0.id == "obj_t1" }?.isConfirmed == true)
        let r = try Retriever(encoder: CoordFixedTextEncoder()).retrieve(phrase: "backpack", tracks: tracks)
        XCTAssertEqual(r.ranked.first?.trackID, "obj_t1")
    }

    func testPerceptionSchedulerOnlyCapturesWhenParkedWithModels() {
        var s = PerceptionScheduler()
        XCTAssertFalse(s.decide(now: 0, robotStationary: true, trackingNormal: true, modelsAvailable: false))
        XCTAssertEqual(s.lastReason, "image models not installed")
        XCTAssertFalse(s.decide(now: 1, robotStationary: false, trackingNormal: true, modelsAvailable: true))
        XCTAssertFalse(s.decide(now: 2, robotStationary: true, trackingNormal: false, modelsAvailable: true))
        XCTAssertTrue(s.decide(now: 3, robotStationary: true, trackingNormal: true, modelsAvailable: true))
        XCTAssertFalse(s.decide(now: 3.1, robotStationary: true, trackingNormal: true, modelsAvailable: true), "too soon")
    }

    func testWaypointAdapterAndPoseAdapter() throws {
        let robot = CoordSimRobot()
        let store = try WaypointStore(path: ":memory:")
        let wp = StoreWaypointsAdapter(store: store, poses: robot, frame: TrustedFrame())
        XCTAssertNil(wp.lookup("desk"))
        XCTAssertEqual(try wp.markHere(name: "desk").name, "desk")
        XCTAssertEqual(wp.lookup("DESK")?.name, "desk")
        robot.trackingKind = .limited
        XCTAssertThrowsError(try wp.markHere(name: "bed"))
        XCTAssertEqual(ControllerPoseAdapter(source: robot).tracking(), .limited)
        robot.trackingKind = .normal
        XCTAssertEqual(ControllerPoseAdapter(source: robot).tracking(), .normal)
    }

    func testGuardStateMapper() {
        XCTAssertEqual(GuardStateMapper.state(corridor: nil, sonar: SonarSample(frontCm: 999, rearCm: 999, flags: 0)), .slow, "no depth is blind, not clear")
        XCTAssertEqual(GuardStateMapper.state(corridor: nil, sonar: SonarSample(frontCm: 999, rearCm: 999, flags: GuardConfig.flagFrontBlocked)), .stop)
    }
}
