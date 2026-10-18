import XCTest
@testable import Companion

// Drive & Teach panel: the exact phrase each button sends, Stop never blocked, failed and timeout states.

@MainActor
final class TeachPanelTests: XCTestCase {
    /// Records every text sent. "stop" finishes at once; anything else stays running until cancelled,
    /// unless `outcome` says otherwise.
    private final class FakeRobot {
        var sent: [String] = []
        var outcome: (String) async throws -> RobotCommand? = { _ in nil }

        func send(_ text: String, _ onUpdate: @escaping (RobotCommand) -> Void) async throws -> RobotCommand {
            sent.append(text)
            var c = RobotCommand(id: "cmd_\(sent.count)", text: text, created_at: nil, status: .queued, result: nil)
            onUpdate(c)
            if let done = try await outcome(text) { return done }
            if text == "stop" { c.status = .done; c.result = "stopped"; return c }
            c.status = .running; onUpdate(c)
            try await Task.sleep(nanoseconds: 30_000_000_000)   // cancelled by Stop
            c.status = .done; c.result = "late"; return c
        }
    }

    private func until(_ what: String, _ cond: () -> Bool) async {
        for _ in 0..<200 where !cond() { try? await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertTrue(cond(), what)
    }

    private func done(_ text: String, _ result: String) -> RobotCommand {
        RobotCommand(id: "cmd_d", text: text, created_at: nil, status: .done, result: result)
    }

    func testExactPhrases() {
        XCTAssertEqual(TeachPanelModel.forwardText(0.5), "forward 0.5 m")
        XCTAssertEqual(TeachPanelModel.forwardText(0.25), "forward 0.25 m")
        XCTAssertEqual(TeachPanelModel.forwardText(1.0), "forward 1.0 m")
        XCTAssertEqual(TeachPanelModel.backText(0.5), "back 0.5 m")
        XCTAssertEqual(TeachPanelModel.turnLeftText(90), "turn left 90")
        XCTAssertEqual(TeachPanelModel.turnRightText(45), "turn right 45")
        XCTAssertEqual(TeachPanelModel.scanText, "scan here")
        XCTAssertEqual(TeachPanelModel.markText("  kitchen   table "), "mark kitchen table")
        XCTAssertEqual(TeachPanelModel.saveText, "save map")
        XCTAssertEqual(TeachPanelModel.stopText, "stop")
    }

    func testEachButtonSendsItsPhrase() async {
        let fake = FakeRobot()
        fake.outcome = { [unowned self] t in self.done(t, "ok") }
        let m = TeachPanelModel(send: fake.send)
        let presses: [(String, () -> Void)] = [
            ("forward 0.5 m", m.forward), ("back 0.5 m", m.back),
            ("turn left 90", m.turnLeft), ("turn right 90", m.turnRight),
            ("scan here", m.scanHere), ("save map", m.saveMap),
        ]
        for (want, press) in presses {
            press()
            await until(want) { !m.busy }
            XCTAssertEqual(fake.sent.last, want)
        }
        m.step = 0.25; m.forward(); await until("step") { !m.busy }
        XCTAssertEqual(fake.sent.last, "forward 0.25 m")
        m.step = 1.0; m.back(); await until("step") { !m.busy }
        XCTAssertEqual(fake.sent.last, "back 1.0 m")
        m.turn = 45; m.turnLeft(); await until("turn") { !m.busy }
        XCTAssertEqual(fake.sent.last, "turn left 45")
        m.placeName = "kitchen"; m.markPlace(); await until("mark") { !m.busy }
        XCTAssertEqual(fake.sent.last, "mark kitchen")
        XCTAssertEqual(m.placeName, "")
        XCTAssertEqual(m.current, .init(text: "mark kitchen", phase: .done("ok")))
    }

    func testMarkNeedsAName() {
        let fake = FakeRobot()
        let m = TeachPanelModel(send: fake.send)
        m.placeName = "   "
        XCTAssertFalse(m.canMark)
        m.markPlace()
        XCTAssertNil(m.current)
    }

    func testMotionBlockedWhileInFlightButStopIsNot() async {
        let fake = FakeRobot()
        let m = TeachPanelModel(send: fake.send)
        m.forward()
        await until("running") { m.current?.phase == .running }
        XCTAssertTrue(m.busy)
        m.turnLeft()                                   // ignored while busy
        XCTAssertEqual(fake.sent, ["forward 0.5 m"])

        m.stop()                                       // posts at once
        XCTAssertEqual(m.current?.phase, .stopped)
        XCTAssertFalse(m.busy)
        await until("stop sent") { fake.sent.last == "stop" }
        await until("stop done") { m.stopLine?.phase == .done("stopped") }
        XCTAssertEqual(m.current?.phase, .stopped)     // the interrupted command's late result is ignored

        m.scanHere()                                   // buttons are back
        await until("scan sent") { fake.sent.last == "scan here" }
    }

    func testStopWorksWithNothingPending() async {
        let fake = FakeRobot()
        let m = TeachPanelModel(send: fake.send)
        m.stop()
        await until("stop done") { m.stopLine?.phase == .done("stopped") }
        XCTAssertEqual(fake.sent, ["stop"])
        XCTAssertNil(m.current)
    }

    func testFailedShowsRobotReason() async {
        let fake = FakeRobot()
        fake.outcome = { _ in throw CommandError.failed("blocked by obstacle") }
        let m = TeachPanelModel(send: fake.send)
        m.forward()
        await until("failed") { m.current?.phase == .failed("blocked by obstacle") }
        XCTAssertFalse(m.busy)
    }

    /// End to end through CommandClient: the robot never finishes, so the client times out. The rover may still be
    /// moving, so the drive buttons stay locked until Stop (PR 40 residual), and Stop unlocks them.
    func testTimeoutThroughCommandClient() async {
        let running = #"{"id":"cmd_t","text":"scan here","created_at":null,"status":"running","result":null}"#
        let client = CommandClient(
            config: BackendConfig(baseURL: URL(string: "http://127.0.0.1:8765")!, token: "t"),
            transport: { req in (Data(running.utf8), HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!) },
            pollInterval: 0.01, timeout: 0.05)
        let m = TeachPanelModel { text, onUpdate in try await client.run(text, onUpdate: onUpdate) }
        m.scanHere()
        await until("timeout") { m.current?.phase == .unknown(CommandError.timeout.message) }
        XCTAssertTrue(m.busy)
        m.stop()
        XCTAssertEqual(m.current?.phase, .stopped)
        XCTAssertFalse(m.busy)
    }

    func testMockSourceSucceeds() async {
        let robot = MockRobotSource()
        let m = TeachPanelModel(robot: robot)
        m.saveMap()
        for _ in 0..<400 where m.busy { try? await Task.sleep(nanoseconds: 10_000_000) }
        guard case .done = m.current?.phase else { return XCTFail("mock should finish: \(String(describing: m.current))") }
        robot.stop()
    }
}
