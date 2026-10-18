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

/// Remote commands run through the same keyword/primary planner and coordinator as the find bar.
final class RemoteCommandRunnerTests: XCTestCase {
    private func runner(_ r: CoordRig) -> RemoteCommandRunner {
        RemoteCommandRunner(planner: KeywordPlanner(), coordinator: r.coordinator,
                            context: { PlannerContext(waypointNames: ["kitchen"]) })
    }

    private func start(_ runner: RemoteCommandRunner, _ text: String) async -> Task<CommandOutcome, Never> {
        let t = Task { await runner.run(text) }
        await coordSettle()
        return t
    }

    func testFindExecutesAndIsDone() async {
        let r = CoordRig()
        let t = await start(runner(r), "find my keys")
        XCTAssertEqual(r.finder.started, ["find:keys"])
        r.finder.finish(.completed(summary: "found: on the desk"))
        let outcome = await t.value
        XCTAssertEqual(outcome, .done("done: find: keys: found: on the desk"))
    }

    func testFindThatIsBlockedFails() async {
        let r = CoordRig()
        let t = await start(runner(r), "find my keys")
        r.finder.finish(.blocked(reason: "path blocked"))
        guard case .failed(let why) = await t.value else { return XCTFail("expected failed") }
        XCTAssertTrue(why.contains("path blocked"), why)
    }

    func testUnknownCommandFails() async {
        let r = CoordRig()
        guard case .failed = await runner(r).run("sing me a song") else { return XCTFail("expected failed") }
        XCTAssertEqual(r.finder.started, [])
        XCTAssertEqual(r.coordinator.trace.count, 0)
    }

    func testUnknownPlaceFails() async {
        let r = CoordRig()
        r.waypoints.known = [:]
        guard case .failed(let why) = await runner(r).run("go to the kitchen") else { return XCTFail("expected failed") }
        XCTAssertTrue(why.hasPrefix("rejected"), why)
    }

    func testBusyIsRefusedAndNeverQueued() async throws {
        let r = CoordRig()
        let explore = await r.launch(.explore(maxMinutes: nil))
        let outcome = await runner(r).run("find my keys")
        XCTAssertEqual(outcome, .failed(CommandPoller.busy))
        XCTAssertFalse(r.coordinator.hasPending)
        XCTAssertEqual(r.finder.started, [])
        r.explorer.finish(.completed(summary: nil))
        try await explore.value
    }

    func testSecondRemoteCommandWhileFirstRunsIsBusy() async {
        let r = CoordRig()
        let run = runner(r)
        let first = await start(run, "find my keys")
        let second = await run.run("find the remote")
        XCTAssertEqual(second, .failed(CommandPoller.busy))
        r.finder.finish(.completed(summary: nil))
        _ = await first.value
        XCTAssertEqual(r.finder.started, ["find:keys"])
    }

    func testManualToolOpenIsBusy() async {
        let r = CoordRig()
        r.coordinator.beginManualControl("drive")
        let outcome = await runner(r).run("find my keys")
        XCTAssertEqual(outcome, .failed(CommandPoller.busy))
        XCTAssertEqual(r.finder.started, [])
    }

    func testStopWinsEvenWhenBusy() async throws {
        let r = CoordRig()
        let run = runner(r)
        let find = await start(run, "find my keys")
        let stops = r.drive.stops
        let stopped = await run.run("stop")
        XCTAssertEqual(stopped, .done("Stopped."))
        XCTAssertGreaterThan(r.drive.stops, stops)
        guard case .failed = await find.value else { return XCTFail("the stopped find must fail") }
        XCTAssertEqual(r.coordinator.status, .idle)
    }

    func testSayIsDone() async {
        let r = CoordRig()
        let outcome = await RemoteCommandRunner(planner: FixedPlanner(calls: [.say(text: "hello")]), coordinator: r.coordinator).run("greet")
        XCTAssertEqual(outcome, .done("hello"))
        XCTAssertEqual(r.speaker.said, ["hello"])
    }
}

private struct FixedPlanner: Planner {
    let calls: [ToolCall]
    func plan(_ utterance: String, context: PlannerContext) async throws -> [ToolCall] { calls }
}
