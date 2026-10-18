import XCTest
#if canImport(CoordinatorCore)
@testable import CoordinatorCore
#endif
#if canImport(PlannerCore)
@testable import PlannerCore
#endif
#if canImport(SyncCore)
import SyncCore
#endif

/// Remote Teach fake: move/turn/scan suspend until finished or cancelled; save map returns `saveResult`.
final class TeachTestRunner: CoordinatorRemoteTeaching {
    private let lock = NSLock()
    private var cont: CheckedContinuation<CoordinatorTaskResult, Error>?
    private var starts: [String] = []
    private var cancelCount = 0
    var saveResult: String?
    private var saveCount = 0
    var started: [String] { lock.lock(); defer { lock.unlock() }; return starts }
    var cancels: Int { lock.lock(); defer { lock.unlock() }; return cancelCount }
    var saves: Int { lock.lock(); defer { lock.unlock() }; return saveCount }
    var isRunning: Bool { lock.lock(); defer { lock.unlock() }; return cont != nil }

    private func run(_ name: String) async throws -> CoordinatorTaskResult {
        try Task.checkCancellation()
        return try await withCheckedThrowingContinuation { (c: CheckedContinuation<CoordinatorTaskResult, Error>) in
            lock.lock()
            if Task.isCancelled { lock.unlock(); c.resume(throwing: CancellationError()); return }
            starts.append(name); cont = c; lock.unlock()
        }
    }
    func finish(_ r: CoordinatorTaskResult) { lock.lock(); let c = cont; cont = nil; lock.unlock(); c?.resume(returning: r) }
    func move(meters: Double) async throws -> CoordinatorTaskResult { try await run("move:\(meters)") }
    func turn(degrees: Double) async throws -> CoordinatorTaskResult { try await run("turn:\(degrees)") }
    func scanHere() async throws -> CoordinatorTaskResult { try await run("scan") }
    func cancel() { lock.lock(); cancelCount += 1; lock.unlock(); finish(.cancelled) }
    func saveMap() async -> String? { lock.lock(); saveCount += 1; let r = saveResult; lock.unlock(); return r }
}

final class RemoteTeachCoordinatorTests: XCTestCase {
    private struct Rig {
        let other = CoordTestRunner()
        let teach = TeachTestRunner()
        let waypoints = CoordTestWaypoints()
        let drive = CoordTestDrive(), speaker = CoordTestSpeaker(), clock = CoordTestClock(), pose = CoordTestPose()
        let coordinator: RobotCoordinator
        init() {
            var deps = CoordinatorDependencies(explorer: other, finder: other, comer: other, navigator: other, waypoints: waypoints,
                                               drive: drive, speaker: speaker, clock: clock, pose: pose)
            deps.teach = teach
            coordinator = RobotCoordinator(dependencies: deps)
        }
        func runner() -> RemoteCommandRunner {
            RemoteCommandRunner(planner: KeywordPlanner(), coordinator: coordinator, plannerTimeout: 60,
                                context: { PlannerContext(waypointNames: ["kitchen"]) })
        }
    }

    private func until(_ cond: () -> Bool) async {
        for _ in 0..<500 { if cond() { return }; await coordSettle() }
        XCTFail("condition never became true")
    }

    // MARK: acks

    func testRemoteCommandsReportShortAcks() async {
        let r = Rig()
        let run = r.runner()
        let cases: [(String, String, CoordinatorTaskResult, String)] = [
            ("forward 0.5 m", "move:0.5", .completed(summary: "moved 0.5 m"), "moved 0.5 m"),
            ("back 0.3 m", "move:-0.3", .completed(summary: "moved back 0.3 m"), "moved back 0.3 m"),
            ("turn left 90", "turn:90.0", .completed(summary: "turned left 90°"), "turned left 90°"),
            ("turn right", "turn:-90.0", .completed(summary: "turned right 90°"), "turned right 90°"),
            ("scan here", "scan", .completed(summary: "scan done 4/4"), "scan done 4/4"),
        ]
        for (text, start, result, ack) in cases {
            let t = Task { await run.run(text) }
            await until { r.teach.isRunning }
            XCTAssertEqual(r.teach.started.last, start, text)
            r.teach.finish(result)
            let outcome = await t.value
            XCTAssertEqual(outcome, .done(ack), text)
        }
        let marked = await run.run("mark kitchen")
        XCTAssertEqual(marked, .done("marked kitchen"))
    }

    func testBlockedMoveIsAFailureNotDone() async {
        let r = Rig()
        let t = Task { await r.runner().run("forward 1 m") }
        await until { r.teach.isRunning }
        r.teach.finish(.blocked(reason: "I couldn't get there in time"))
        guard case .failed = await t.value else { return XCTFail("a blocked move must not be done") }
    }

    // MARK: refusals

    func testRefusedWhileBusyAndNeverQueued() async {
        let r = Rig()
        let find = Task { try await r.coordinator.execute(.findObject(description: "keys")) }
        await until { r.other.isRunning }
        for text in ["forward 0.5 m", "turn left 90", "scan here", "save map"] {
            let outcome = await r.runner().run(text)
            XCTAssertEqual(outcome, .failed(CommandPoller.busy), text)
        }
        r.other.finish(.completed(summary: nil))
        _ = try? await find.value
        await coordSettle()
        XCTAssertEqual(r.teach.started, [], "a refused command started later")
        XCTAssertEqual(r.teach.saves, 0)
        XCTAssertFalse(r.coordinator.hasPending)
    }

    func testRefusedWhileManualToolIsOpen() async {
        let r = Rig()
        r.coordinator.beginManualControl("teach")
        for text in ["forward 0.5 m", "back 0.5 m", "turn right 45", "scan here", "save map", "mark kitchen"] {
            let outcome = await r.runner().run(text)
            XCTAssertEqual(outcome, .failed(CommandPoller.busy), text)
        }
        XCTAssertEqual(r.teach.started, [])
        XCTAssertEqual(r.teach.saves, 0)
        XCTAssertEqual(r.waypoints.marked, [])
    }

    func testMotionRefusedWithoutNormalTracking() async {
        let r = Rig()
        r.pose.value = .limited
        for text in ["forward 0.5 m", "turn left 90", "scan here"] {
            guard case .failed(let why) = await r.runner().run(text) else { XCTFail(text); continue }
            XCTAssertTrue(why.contains("tracking not normal"), why)
        }
        XCTAssertEqual(r.teach.started, [])
    }

    func testLocalTeachCallIsNotQueuedEither() async throws {
        let r = Rig()
        let find = Task { try await r.coordinator.execute(.findObject(description: "keys")) }
        await until { r.other.isRunning }
        try await r.coordinator.execute(.move(meters: 0.5))
        XCTAssertFalse(r.coordinator.hasPending)
        r.other.finish(.completed(summary: nil))
        _ = try? await find.value
        await coordSettle()
        XCTAssertEqual(r.teach.started, [])
    }

    // MARK: STOP

    func testStopDuringMoveTurnAndScanCancels() async {
        for text in ["forward 0.5 m", "turn left 90", "scan here"] {
            let r = Rig()
            let run = r.runner()
            let t = Task { await run.run(text) }
            await until { r.teach.isRunning }
            let stopped = await run.run("stop")
            XCTAssertEqual(stopped, .done("Stopped."), text)
            guard case .failed = await t.value else { XCTFail("\(text) must fail after STOP"); continue }
            XCTAssertGreaterThanOrEqual(r.teach.cancels, 1, text)
            XCTAssertGreaterThanOrEqual(r.drive.stops, 1, text)
            await until { !r.coordinator.isBusy }
            XCTAssertEqual(r.coordinator.status, .idle)
        }
    }

    func testPauseStyleStopAllDuringScanCancels() async {
        let r = Rig()
        let t = Task { await r.runner().run("scan here") }
        await until { r.teach.isRunning }
        r.coordinator.stopAll()
        guard case .failed = await t.value else { return XCTFail("scan must fail after stopAll") }
        XCTAssertEqual(r.teach.cancels, 1)
    }

    // MARK: save map

    func testSaveMapReportsSavedOrWhy() async {
        let r = Rig()
        let saved = await r.runner().run("save map")
        XCTAssertEqual(saved, .done("map saved"))
        r.teach.saveResult = "Keep scanning until tracking is normal and the area is mapped"
        let refused = await r.runner().run("save the map")
        XCTAssertEqual(refused, .failed("map not saved: Keep scanning until tracking is normal and the area is mapped"))
        XCTAssertEqual(r.teach.saves, 2)
    }

    func testUnwiredSaveMapSaysSo() async {
        let co = RobotCoordinator(dependencies: CoordinatorDependencies(
            explorer: CoordTestRunner(), finder: CoordTestRunner(), comer: CoordTestRunner(), navigator: CoordTestRunner(),
            waypoints: CoordTestWaypoints(), drive: CoordTestDrive(), speaker: CoordTestSpeaker(), clock: CoordTestClock(),
            pose: CoordTestPose()))
        let outcome = try? await co.executeRemote(.saveMap, generation: co.stopGeneration)
        XCTAssertEqual(outcome, .failed("map not saved: not wired up in this build"))
    }

    /// The keyword grammar decides teach commands even when a model planner is configured.
    func testTeachCommandsBypassTheModelPlanner() async {
        let r = Rig()
        let run = RemoteCommandRunner(planner: WrongPlanner(), coordinator: r.coordinator, plannerTimeout: 60)
        let t = Task { await run.run("turn right 30") }
        await until { r.teach.isRunning }
        XCTAssertEqual(r.teach.started, ["turn:-30.0"])
        r.teach.finish(.completed(summary: "turned right 30°"))
        let outcome = await t.value
        XCTAssertEqual(outcome, .done("turned right 30°"))
    }

    private struct WrongPlanner: Planner {
        func plan(_ utterance: String, context: PlannerContext) async throws -> [ToolCall] { [.explore(maxMinutes: nil)] }
    }
}
