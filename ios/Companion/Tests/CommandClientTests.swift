import XCTest
@testable import Companion

// The remote command client (docs/03_CONTRACTS.md 2.9) against a fake transport: what it sends, how it polls, how it fails.

@MainActor
final class CommandClientTests: XCTestCase {
    private let config = BackendConfig(baseURL: URL(string: "http://127.0.0.1:8765")!, token: "dev-local-token")

    /// Answers each request with the next canned (status code, body) and records what was asked.
    private final class FakeServer {
        var replies: [(Int, String)]
        var requests: [URLRequest] = []
        var repeatLast = false
        init(_ replies: [(Int, String)], repeatLast: Bool = false) { self.replies = replies; self.repeatLast = repeatLast }

        func transport(_ req: URLRequest) async throws -> (Data, URLResponse) {
            requests.append(req)
            let (code, body) = repeatLast && replies.count == 1 ? replies[0] : replies.removeFirst()
            return (Data(body.utf8), HTTPURLResponse(url: req.url!, statusCode: code, httpVersion: nil, headerFields: nil)!)
        }
    }

    private func cmd(_ status: String, result: String? = nil) -> String {
        let r = result.map { "\"\($0)\"" } ?? "null"
        return #"{"id":"cmd_x1y2z3","text":"find red umbrella","created_at":"2026-10-18T04:00:00Z","status":"\#(status)","result":\#(r)}"#
    }

    private func client(_ server: FakeServer, timeout: TimeInterval = 5) -> CommandClient {
        CommandClient(config: config, transport: server.transport, pollInterval: 0.01, timeout: timeout)
    }

    func testSendPostsTextWithTokenAndDecodes() async throws {
        let server = FakeServer([(201, cmd("queued"))])
        let c = try await client(server).send("find red umbrella")
        let req = try XCTUnwrap(server.requests.first)
        XCTAssertEqual(req.httpMethod, "POST")
        XCTAssertEqual(req.url?.absoluteString, "http://127.0.0.1:8765/api/commands")
        XCTAssertEqual(req.value(forHTTPHeaderField: "Authorization"), "Bearer dev-local-token")
        XCTAssertEqual(req.value(forHTTPHeaderField: "Content-Type"), "application/json")
        let body = try JSONSerialization.jsonObject(with: try XCTUnwrap(req.httpBody)) as? [String: String]
        XCTAssertEqual(body, ["text": "find red umbrella"])
        XCTAssertEqual(c, RobotCommand(id: "cmd_x1y2z3", text: "find red umbrella", created_at: "2026-10-18T04:00:00Z",
                                       status: .queued, result: nil))
    }

    func testRunPollsUntilDoneAndReportsEachStatus() async throws {
        let server = FakeServer([(201, cmd("queued")), (200, cmd("queued")), (200, cmd("running")),
                                 (200, cmd("done", result: "Found it by the sofa."))])
        var seen: [RobotCommand.Status] = []
        let done = try await client(server).run("find red umbrella") { seen.append($0.status) }
        XCTAssertEqual(done.status, .done)
        XCTAssertEqual(done.result, "Found it by the sofa.")
        XCTAssertEqual(seen, [.queued, .running, .done])   // a repeated status is not reported twice
        XCTAssertEqual(server.requests.map { $0.url!.path }, ["/api/commands"] + Array(repeating: "/api/commands/cmd_x1y2z3", count: 3))
        XCTAssertEqual(server.requests.dropFirst().map(\.httpMethod), ["GET", "GET", "GET"])
    }

    func testFailedCommandThrowsTheRobotsWords() async {
        let server = FakeServer([(201, cmd("running")), (200, cmd("failed", result: "I don't know a place called attic."))])
        do { _ = try await client(server).run("go to attic"); XCTFail("expected failure") } catch {
            XCTAssertEqual(error as? CommandError, .failed("I don't know a place called attic."))
            XCTAssertEqual((error as? CommandError)?.message, "I don't know a place called attic.")
        }
        XCTAssertEqual(CommandError.failed(nil).message, "Soughtbot couldn\u{2019}t do that.")
    }

    func testBusyFromStatusCodeOrResult() async {
        do { _ = try await client(FakeServer([(409, "{}")])).run("find keys"); XCTFail() } catch {
            XCTAssertEqual(error as? CommandError, .busy)
        }
        do { _ = try await client(FakeServer([(201, cmd("failed", result: "Robot is busy exploring"))])).run("find keys"); XCTFail() } catch {
            XCTAssertEqual(error as? CommandError, .busy)
        }
    }

    func testTimesOutWhenTheRobotNeverFinishes() async {
        let server = FakeServer([(200, cmd("running"))], repeatLast: true)
        do { _ = try await client(server, timeout: 0.1).run("find red umbrella"); XCTFail("expected timeout") } catch {
            XCTAssertEqual(error as? CommandError, .timeout)
        }
        XCTAssertGreaterThan(server.requests.count, 2)
    }

    func testHTTPAndNetworkErrorsHavePlainCopy() async {
        let cases: [(Int, CommandError)] = [(401, .unauthorized), (404, .notAvailable), (500, .http(500))]
        for (code, want) in cases {
            do { _ = try await client(FakeServer([(code, "{}")])).send("stop"); XCTFail() } catch {
                XCTAssertEqual(error as? CommandError, want)
            }
        }
        let offline = CommandClient(config: config, transport: { _ in throw URLError(.notConnectedToInternet) })
        do { _ = try await offline.send("stop"); XCTFail() } catch { XCTAssertEqual(error as? CommandError, .network) }
        XCTAssertEqual(CommandError.network.message, "Can\u{2019}t reach Soughtbot\u{2019}s server. Check the Wi-Fi and try again.")
    }

    func testFindAndComeTextUseTheRobotsNames() {
        let umbrella = TrackedObject(id: "o", label: "Red Umbrella", description: nil, x: 0, z: 0, firstSeen: Date(), lastSeen: Date(),
                                     sightings: 1, history: [], whereText: "By the door", room: nil, photo: .none)
        XCTAssertEqual(BackendRobotSource.findText(query: "where is my umbrella", match: umbrella), "find red umbrella")
        XCTAssertEqual(BackendRobotSource.findText(query: "car keys", match: nil), "find car keys")
        XCTAssertEqual(BackendRobotSource.findText(query: "Where is my wallet", match: nil), "Where is my wallet")
        let wps = [Waypoint(id: "wpt_1", name: "kitchen table", x: 0, z: 0)]
        XCTAssertEqual(BackendRobotSource.placeName(ComeTarget(waypointId: "wpt_1", name: "the kitchen table", x: 0, z: 0), waypoints: wps),
                       "kitchen table")
        XCTAssertEqual(BackendRobotSource.placeName(ComeTarget(waypointId: nil, name: "the hallway", x: 0, z: 0), waypoints: wps), "hallway")
    }

    // MARK: Accepted, then the status checks fail (PR 40 residual): the command may still run, so keep Stop.

    private let pollFailures: [Int] = [401, 403, 404, 405, 409, 423, 429, 500]

    func testStatusCheckErrorsAfterAcceptanceAreLostTrackNotTerminal() async {
        for code in pollFailures {
            let server = FakeServer([(201, cmd("queued")), (code, "{}")])
            do { _ = try await client(server).run("find red umbrella"); XCTFail("\(code)") } catch {
                XCTAssertEqual(error as? CommandError, .lostTrack(code == 403 ? 401 : code == 405 ? 404 : [423, 429].contains(code) ? 409 : code), "\(code)")
                XCTAssertTrue(BackendRobotSource.isTransportProblem(error as! CommandError), "\(code)")
            }
        }
        // A rejected POST is still a plain answer, and a robot-reported failure stays terminal.
        do { _ = try await client(FakeServer([(409, "{}")])).run("find keys"); XCTFail() } catch { XCTAssertEqual(error as? CommandError, .busy) }
        do { _ = try await client(FakeServer([(201, cmd("running")), (200, cmd("failed", result: "blocked"))])).run("x"); XCTFail() } catch {
            XCTAssertEqual(error as? CommandError, .failed("blocked"))
        }
    }

    private func source(_ server: FakeServer) -> BackendRobotSource {
        BackendRobotSource(config: config, commands: client(server))
    }

    private func settle(_ done: @escaping () -> Bool) async {
        for _ in 0..<200 where !done() { try? await Task.sleep(nanoseconds: 10_000_000) }
    }

    func testFindKeepsStopWhenStatusChecksFailAfterAcceptance() async {
        for code in pollFailures {
            let server = FakeServer([(201, cmd("running")), (code, "{}"), (201, cmd("queued"))])
            let s = source(server)
            s.startFind("red umbrella", match: nil)
            await settle { if case .lostContact? = s.find?.phase { return true }; return false }
            guard case .lostContact? = s.find?.phase else { XCTFail("\(code): \(String(describing: s.find?.phase))"); continue }
            s.cancelFind()   // Stop is offered and actually posts "stop"
            await settle { server.requests.count >= 3 }
            let last = server.requests.last.flatMap { $0.httpBody }.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: String] }
            XCTAssertEqual(last?["text"], "stop", "\(code)")
        }
    }

    func testComeToMeKeepsStopWhenStatusChecksFailAfterAcceptance() async {
        for code in pollFailures {
            let server = FakeServer([(201, cmd("running")), (code, "{}"), (201, cmd("queued"))])
            let s = source(server)
            s.comeToMe(to: ComeTarget(waypointId: nil, name: "the sofa", x: 0, z: 0))
            await settle { if case .lostContact? = s.come?.phase { return true }; return false }
            guard case .lostContact? = s.come?.phase else { XCTFail("\(code): \(String(describing: s.come?.phase))"); continue }
            s.cancelComeToMe()
            await settle { server.requests.count >= 3 }
            let last = server.requests.last.flatMap { $0.httpBody }.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: String] }
            XCTAssertEqual(last?["text"], "stop", "\(code)")
        }
    }
}
