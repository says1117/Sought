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

// PR 38 review P2: the Robot tools "Last find" screen needs a production trace producer. FindRunnerAdapter hands every
// executor result's trace to `onTrace` (via CoordinatorWiring.onFindTrace), aborted ones included.

final class CoordTraceBox {
    private let lock = NSLock()
    private var all: [FindTrace] = []
    var traces: [FindTrace] { lock.lock(); defer { lock.unlock() }; return all }
    func add(_ t: FindTrace) { lock.lock(); all.append(t); lock.unlock() }
}

final class CoordinatorTraceHookTests: XCTestCase {
    private func makeCoordinator(box: CoordTraceBox, robot: CoordSimRobot, speaker: CoordTestSpeaker, targetZ: Float) throws -> RobotCoordinator {
        let tracks = try TrackStore(path: ":memory:")
        try tracks.upsert(Track(id: "obj_1", position: SIMD3(0, 0, targetZ), embedding: [1, 0, 0, 0], sightings: 3, persistence: 0.8))
        let ticks = CoordTickClock()
        var wiring = CoordinatorWiring(
            poses: robot, drive: robot, guardState: { .clear }, waypointStore: try WaypointStore(path: ":memory:"), trackStore: tracks,
            encoders: CoordIntegrationRig.working(), speaker: speaker, clock: CoordTestClock())
        wiring.controllerClock = { ticks.tick() }
        wiring.controllerSleep = { _ in try? await Task.sleep(nanoseconds: 2_000_000) }
        wiring.frame = TrustedFrame()
        wiring.onFindTrace = { box.add($0) }
        return wiring.makeCoordinator()
    }

    func testCompletedFindDeliversItsTrace() async throws {
        let box = CoordTraceBox()
        let co = try makeCoordinator(box: box, robot: CoordSimRobot(), speaker: CoordTestSpeaker(), targetZ: -2)
        try await co.execute(.findObject(description: "blue backpack"))
        XCTAssertEqual(box.traces.count, 1)
        XCTAssertEqual(box.traces.first?.text, "blue backpack")
        XCTAssertNotEqual(box.traces.first?.outcome, "aborted")
        XCTAssertEqual(box.traces.first?.ranked.first?.trackID, "obj_1")
    }

    func testAbortedFindStillDeliversItsTrace() async throws {
        let box = CoordTraceBox()
        let robot = CoordSimRobot()
        let co = try makeCoordinator(box: box, robot: robot, speaker: CoordTestSpeaker(), targetZ: -500)
        let task = Task { try await co.execute(.findObject(description: "blue backpack")) }
        for _ in 0..<500 where robot.movingCommands == 0 { try await Task.sleep(nanoseconds: 2_000_000) }
        XCTAssertGreaterThan(robot.movingCommands, 0)
        co.stopAll()
        try await task.value
        XCTAssertEqual(box.traces.count, 1, "an aborted find reports its trace too")
        XCTAssertEqual(box.traces.first?.outcome, "aborted")
    }

    func testNoHookIsFine() async throws {
        let tracks = try TrackStore(path: ":memory:")
        let speaker = CoordTestSpeaker()
        var wiring = CoordinatorWiring(
            poses: CoordSimRobot(), drive: CoordSimRobot(), guardState: { .clear }, waypointStore: try WaypointStore(path: ":memory:"),
            trackStore: tracks, encoders: CoordIntegrationRig.working(), speaker: speaker, clock: CoordTestClock())
        XCTAssertNil(wiring.onFindTrace)
        wiring.onFindTrace = nil
        try await wiring.makeCoordinator().execute(.findObject(description: "anything"))
    }
}
