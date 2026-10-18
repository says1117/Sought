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

/// PR 51 review probes: STOP and pause always win over remote commands, remote motion is never queued,
/// and `done` means the task really succeeded. Each test was a reproduced defect before the fix.
final class RemoteCommandSafetyTests: XCTestCase {
    private func runner(_ r: CoordRig, planner: Planner = KeywordPlanner()) -> RemoteCommandRunner {
        RemoteCommandRunner(planner: planner, coordinator: r.coordinator, plannerTimeout: 60,
                            context: { PlannerContext(waypointNames: ["kitchen"]) })
    }

    private func poller(_ t: GatedCommandTransport, _ run: RemoteCommandRunner) -> CommandPoller {
        CommandPoller(transport: t, runner: run, sleep: { _ in })
    }

    /// [P1] A command still in plan() when STOP arrives must never start afterwards.
    func testStopInvalidatesACommandStillPlanning() async {
        let r = CoordRig()
        let gate = RemoteTestGate()
        let run = runner(r, planner: GatedRemotePlanner(gate: gate, calls: [.findObject(description: "keys")]))
        let find = Task { await run.run("find my keys") }
        await remoteUntil { gate.waiting > 0 }

        let stopped = await run.run("stop")
        XCTAssertEqual(stopped, .done("Stopped."))
        gate.open()
        await coordSettle()
        XCTAssertEqual(r.finder.started, [], "pre-STOP motion started after STOP")
        r.finder.finish(.completed(summary: nil))   // only reachable without the fix; keeps the test from hanging
        guard case .failed = await find.value else { return XCTFail("a command overtaken by STOP must fail") }
        XCTAssertFalse(r.coordinator.isBusy)
    }

    /// [P1] Pause while a claim (GET /next) is still in flight: the command must never reach the coordinator.
    func testPauseDropsAClaimStillInFlight() async {
        let r = CoordRig()
        let t = GatedCommandTransport(commands: [("cmd_1", "find my keys")], gateNext: true)
        let p = poller(t, runner(r))
        let poll = Task { await p.pollOnce() }
        await remoteUntil { t.nextGate.waiting > 0 }

        p.stop(); r.coordinator.stopAll()           // AppRuntime.pause order
        t.nextGate.open()
        let work = await poll.value.work
        await coordSettle()
        XCTAssertEqual(r.finder.started, [], "a command claimed before pause started after it")
        r.finder.finish(.completed(summary: nil))
        await work?.value
        XCTAssertEqual(t.finalAck?.status, "failed")
    }

    /// [P1] The reviewer's probe: pause while the running ack is stalled; releasing it must not start motion.
    func testPauseCancelsClaimedWorkWaitingOnItsAck() async {
        let r = CoordRig()
        let t = GatedCommandTransport(commands: [("cmd_1", "find my keys")], gateRunningAck: true)
        let p = poller(t, runner(r))
        let work = await p.pollOnce().work
        await remoteUntil { t.ackGate.waiting > 0 }
        await coordSettle()

        p.stop(); r.coordinator.stopAll()
        let startedAtPause = r.finder.started
        t.ackGate.open()
        await coordSettle()
        XCTAssertEqual(r.finder.started, startedAtPause, "motion started after the pause")
        XCTAssertFalse(r.finder.isRunning)
        r.finder.finish(.completed(summary: nil))
        await work?.value
        XCTAssertEqual(t.finalAck?.status, "failed")
        XCTAssertFalse(r.coordinator.isBusy)
    }

    /// [P1] A remote "stop" brakes at once, without waiting for its running ack.
    func testStopBrakesBeforeItsAckIsDelivered() async throws {
        let r = CoordRig()
        let local = await r.launch(.findObject(description: "remote"))
        let t = GatedCommandTransport(commands: [("cmd_stop", "stop")], gateRunningAck: true)
        let stops = r.drive.stops
        let work = await poller(t, runner(r)).pollOnce().work
        await remoteUntil { t.ackGate.waiting > 0 }
        await coordSettle()

        XCTAssertGreaterThan(r.drive.stops, stops, "STOP waited for the network ack")
        XCTAssertEqual(r.coordinator.status, .idle)
        t.ackGate.open()
        await work?.value
        try? await local.value
        XCTAssertEqual(t.finalAck?.status, "done")
        XCTAssertEqual(t.finalAck?.result, "Stopped.")
    }

    /// [P1] A local task starting between the runner's busy check and admission: refuse, never queue.
    func testLocalTaskStartingBeforeAdmissionRefusesAndNeverQueues() async throws {
        let r = CoordRig()
        let local = RemoteTaskBox()
        let co = r.coordinator
        r.waypoints.onLookup = { _ in
            guard local.task == nil else { return }
            local.task = Task { try await co.execute(.findObject(description: "local")) }
            let deadline = Date().addingTimeInterval(2)
            while !co.isBusy, Date() < deadline { usleep(1_000) }
        }
        let outcome = await runner(r).run("go to the kitchen")
        XCTAssertEqual(outcome, .failed(CommandPoller.busy))
        XCTAssertFalse(r.coordinator.hasPending, "remote motion was put in the pending slot")
        XCTAssertEqual(r.finder.started, ["find:local"])

        r.finder.finish(.completed(summary: nil))
        try await local.task?.value
        await coordSettle()
        XCTAssertEqual(r.navigator.started, [], "queued remote motion ran after the local task")
        r.navigator.finish(.completed(summary: nil))
    }

    /// [P2] Tracking not available: the coordinator blocks before starting; that is a failure, not done.
    func testBlockedOnTrackingIsFailedNotDone() async {
        let r = CoordRig()
        r.pose.value = .notAvailable
        let outcome = await runner(r).run("find my keys")
        guard case .failed(let why) = outcome else { return XCTFail("expected failed, got \(outcome)") }
        XCTAssertTrue(why.contains(CoordinatorConfig.rescanReason), why)
        XCTAssertEqual(r.finder.started, [])
        XCTAssertEqual(r.coordinator.status.state, .blocked)
    }

    /// The local find bar keeps its queue-behind-a-task behaviour.
    func testLocalRequestsStillQueue() async throws {
        let r = CoordRig()
        let first = await r.launch(.findObject(description: "keys"))
        try await r.coordinator.execute(.goToWaypoint(name: "kitchen"))
        XCTAssertTrue(r.coordinator.hasPending)
        r.finder.finish(.completed(summary: nil))
        try await first.value
        await coordSettle()
        XCTAssertEqual(r.navigator.started, ["go:kitchen"])
        r.navigator.finish(.completed(summary: nil))
    }
}

private func remoteUntil(_ condition: () -> Bool) async {
    for _ in 0..<2_000 where !condition() {
        await Task.yield()
        try? await Task.sleep(nanoseconds: 500_000)
    }
}

final class RemoteTaskBox { var task: Task<Void, Error>? }

/// Suspends callers until opened; `waiting` counts the callers parked on it.
final class RemoteTestGate {
    private let lock = NSLock()
    private var isOpen = false
    private var parked: [CheckedContinuation<Void, Never>] = []
    var waiting: Int { lock.lock(); defer { lock.unlock() }; return parked.count }
    func wait() async {
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            lock.lock()
            if isOpen { lock.unlock(); c.resume(); return }
            parked.append(c); lock.unlock()
        }
    }
    func open() {
        lock.lock(); isOpen = true; let p = parked; parked = []; lock.unlock()
        p.forEach { $0.resume() }
    }
}

/// A planner that suspends in plan() until its gate opens.
struct GatedRemotePlanner: Planner {
    let gate: RemoteTestGate
    let calls: [ToolCall]
    func plan(_ utterance: String, context: PlannerContext) async throws -> [ToolCall] {
        await gate.wait()
        return calls
    }
}

/// Backend for the poller: scripted GET /next commands, optionally gating that GET or the `running` ack.
final class GatedCommandTransport: CommandTransport {
    let nextGate = RemoteTestGate(), ackGate = RemoteTestGate()
    private let gateNext: Bool, gateRunningAck: Bool
    private let lock = NSLock()
    private var commands: [(id: String, text: String)]
    private var log: [SyncRequest] = []
    init(commands: [(String, String)], gateNext: Bool = false, gateRunningAck: Bool = false) {
        self.commands = commands.map { (id: $0.0, text: $0.1) }
        self.gateNext = gateNext; self.gateRunningAck = gateRunningAck
    }
    var acks: [(status: String?, result: String?)] {
        lock.lock(); let l = log; lock.unlock()
        return l.filter { $0.path.hasSuffix("/ack") }.map { r in
            let o = (try? JSONSerialization.jsonObject(with: r.body ?? Data())) as? [String: Any] ?? [:]
            return (o["status"] as? String, o["result"] as? String)
        }
    }
    var finalAck: (status: String?, result: String?)? { acks.last { $0.status != "running" } }

    func exchange(_ r: SyncRequest) async throws -> (status: Int, body: Data) {
        remember(r)
        if r.path == "/api/commands/next" {
            if gateNext { await nextGate.wait() }
            guard let c = pop() else { return (204, Data()) }
            return (200, Data(#"{"id":"\#(c.id)","text":"\#(c.text)","created_at":"2026-10-18T05:00:00Z","status":"running","result":null}"#.utf8))
        }
        if gateRunningAck, String(data: r.body ?? Data(), encoding: .utf8)?.contains(#""running""#) == true { await ackGate.wait() }
        return (200, Data())
    }
    private func remember(_ r: SyncRequest) { lock.lock(); log.append(r); lock.unlock() }
    private func pop() -> (id: String, text: String)? {
        lock.lock(); defer { lock.unlock() }
        return commands.isEmpty ? nil : commands.removeFirst()
    }
}
