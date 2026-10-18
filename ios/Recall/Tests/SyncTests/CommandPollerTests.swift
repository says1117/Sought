import XCTest
#if canImport(SyncCore)
@testable import SyncCore
#endif

/// Scripted backend: queued GET /next answers, every request recorded.
final class FakeCommandTransport: CommandTransport {
    enum Answer { case status(Int, Data), offline }
    private let lock = NSLock()
    private var nextAnswers: [Answer]
    private var ackStatus: Int
    private var log: [SyncRequest] = []
    init(next: [Answer], ackStatus: Int = 200) { nextAnswers = next; self.ackStatus = ackStatus }
    var requests: [SyncRequest] { lock.lock(); defer { lock.unlock() }; return log }
    var acks: [[String: String?]] {
        requests.filter { $0.path.hasSuffix("/ack") }.map { r in
            let o = (try? JSONSerialization.jsonObject(with: r.body ?? Data())) as? [String: Any] ?? [:]
            return ["path": r.path, "status": o["status"] as? String, "result": o["result"] as? String]
        }
    }
    func exchange(_ r: SyncRequest) async throws -> (status: Int, body: Data) {
        switch answer(for: r) { case .status(let s, let d): return (s, d); case .offline: throw URLError(.notConnectedToInternet) }
    }
    private func answer(for r: SyncRequest) -> Answer {
        lock.lock(); defer { lock.unlock() }
        log.append(r)
        guard r.path == "/api/commands/next" else { return .status(ackStatus, Data()) }
        return nextAnswers.isEmpty ? .status(204, Data()) : nextAnswers.removeFirst()
    }
    static func command(_ id: String, _ text: String) -> Answer {
        .status(200, Data(#"{"id":"\#(id)","text":"\#(text)","created_at":"2026-10-18T05:00:00Z","status":"running","result":null}"#.utf8))
    }
}

final class FakeCommandRunner: CommandRunning {
    var outcome: (String) -> CommandOutcome
    private(set) var ran: [String] = []
    init(_ outcome: @escaping (String) -> CommandOutcome) { self.outcome = outcome }
    func stopEpoch() -> UInt64 { 0 }
    func run(_ text: String, claimedAt epoch: UInt64) async -> CommandOutcome { ran.append(text); return outcome(text) }
}

final class CommandPollerTests: XCTestCase {
    private func poller(_ t: FakeCommandTransport, _ r: FakeCommandRunner) -> CommandPoller {
        CommandPoller(transport: t, runner: r, backoff: Backoff(base: 2, factor: 2, cap: 30, jitter: 0), sleep: { _ in })
    }

    func testCommandIsAckedRunningThenDoneWithResult() async {
        let t = FakeCommandTransport(next: [FakeCommandTransport.command("cmd_a", "find my keys")])
        let r = FakeCommandRunner { _ in .done("found: on the desk") }
        let (delay, work) = await poller(t, r).pollOnce()
        await work?.value
        XCTAssertEqual(delay, 2)
        XCTAssertEqual(r.ran, ["find my keys"])
        XCTAssertEqual(t.requests.first?.method, "GET")
        XCTAssertEqual(t.acks, [["path": "/api/commands/cmd_a/ack", "status": "running", "result": nil],
                                ["path": "/api/commands/cmd_a/ack", "status": "done", "result": "found: on the desk"]])
    }

    func testRunnerFailureIsAckedFailed() async {
        let t = FakeCommandTransport(next: [FakeCommandTransport.command("cmd_b", "sing")])
        let r = FakeCommandRunner { _ in .failed(CommandPoller.busy) }
        await poller(t, r).pollOnce().work?.value
        XCTAssertEqual(t.acks.last?["status"], "failed")
        XCTAssertEqual(t.acks.last?["result"], "busy")
    }

    func testEmptyQueueDoesNothing() async {
        let t = FakeCommandTransport(next: [.status(204, Data())])
        let r = FakeCommandRunner { _ in .done("") }
        let (delay, work) = await poller(t, r).pollOnce()
        XCTAssertNil(work)
        XCTAssertEqual(delay, 2)
        XCTAssertEqual(t.requests.count, 1)
        XCTAssertEqual(r.ran, [])
    }

    func testBackoffGrowsOnErrorsAndResetsOnSuccess() async {
        let t = FakeCommandTransport(next: [.offline, .offline, .status(500, Data()), .status(401, Data()),
                                            .status(200, Data("not json".utf8)), .status(204, Data()), .offline])
        let p = poller(t, FakeCommandRunner { _ in .done("") })
        var delays: [TimeInterval] = []
        for _ in 0..<7 { delays.append(await p.pollOnce().delay) }
        XCTAssertEqual(delays, [2, 4, 8, 16, 30, 2, 2])
        XCTAssertEqual(p.consecutiveFailures, 1)
    }

    func testAckRetriesThenGivesUpQuietly() async {
        let t = FakeCommandTransport(next: [FakeCommandTransport.command("cmd_c", "stop")], ackStatus: 503)
        let p = poller(t, FakeCommandRunner { _ in .done("Stopped.") })
        await p.pollOnce().work?.value
        XCTAssertEqual(t.acks.count, 6)                 // running x3, done x3
        XCTAssertEqual(p.acksFailed, 2)
    }

    func testFinishedConflictCountsAsDelivered() async {
        let t = FakeCommandTransport(next: [FakeCommandTransport.command("cmd_d", "stop")], ackStatus: 409)
        let p = poller(t, FakeCommandRunner { _ in .done("Stopped.") })
        await p.pollOnce().work?.value
        XCTAssertEqual(t.acks.count, 2)
        XCTAssertEqual(p.acksFailed, 0)
    }

    func testLongResultIsTrimmed() async {
        let t = FakeCommandTransport(next: [FakeCommandTransport.command("cmd_e", "x")])
        await poller(t, FakeCommandRunner { _ in .done(String(repeating: "a", count: 900)) }).pollOnce().work?.value
        XCTAssertEqual(t.acks.last?["result"]??.count, CommandPoller.maxResultLength)
    }

    func testNoPollerAndNoNetworkWhenUnconfigured() {
        let r = FakeCommandRunner { _ in .done("") }
        XCTAssertNil(CommandPoller.make(config: nil, runner: r))
        XCTAssertNil(CommandPoller.make(config: SyncConfig(info: ["BACKEND_BASE_URL": "http://example.com", "RECALL_TOKEN": "change-me"]), runner: r))
        XCTAssertNil(CommandPoller.make(config: SyncConfig(info: [:]), runner: r))
        XCTAssertNotNil(CommandPoller.make(config: SyncConfig(baseURL: URL(string: "http://127.0.0.1:8000")!, token: "t"), runner: r))
    }

    func testStartStopLoopPollsUntilStopped() async throws {
        let t = FakeCommandTransport(next: [])
        let p = CommandPoller(transport: t, runner: FakeCommandRunner { _ in .done("") }, sleep: { _ in try await Task.sleep(nanoseconds: 1_000_000) })
        p.start(); p.start()
        try await Task.sleep(nanoseconds: 50_000_000)
        p.stop()
        try await Task.sleep(nanoseconds: 20_000_000)
        let n = t.requests.count
        XCTAssertGreaterThan(n, 1)
        try await Task.sleep(nanoseconds: 30_000_000)
        XCTAssertEqual(t.requests.count, n)
    }

    func testWireCommandDecodesContractShape() throws {
        let c = try JSONDecoder().decode(WireCommand.self, from: Data(#"{"id":"cmd_x1y2z3","text":"check the way to the bathroom","created_at":"2026-10-18T05:00:00Z","status":"queued","result":null}"#.utf8))
        XCTAssertEqual(c, WireCommand(id: "cmd_x1y2z3", text: "check the way to the bathroom", createdAt: "2026-10-18T05:00:00Z", status: "queued", result: nil))
        XCTAssertEqual(String(data: try SyncJSON.encode(WireCommandAck(status: "running", result: nil)), encoding: .utf8), #"{"result":null,"status":"running"}"#)
    }
}
