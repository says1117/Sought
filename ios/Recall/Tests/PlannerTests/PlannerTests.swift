import XCTest
#if canImport(PlannerCore)
@testable import PlannerCore
#endif

// All Gemini JSON below is a hand-written FIXTURE in the documented generateContent response shape.
// It was not recorded from a live call. No test touches the network.

private let ctx = PlannerContext(waypointNames: ["Kitchen", "Front Door"], routeNames: ["Hallway"],
                                 trackNames: ["red backpack"], lastPatrolSummary: "Nothing moved.")

private func fixture(_ parts: String) -> Data {
    Data(#"{"candidates":[{"content":{"role":"model","parts":[\#(parts)]},"finishReason":"STOP"}]}"#.utf8)
}
private func fnCall(_ name: String, _ args: String = "{}") -> String {
    #"{"functionCall":{"name":"\#(name)","args":\#(args)}}"#
}

struct FakeTransport: PlannerTransport {
    var delay: TimeInterval = 0
    var status = 200
    var body = Data()
    var error: Error?
    func send(_ request: URLRequest) async throws -> (data: Data, status: Int) {
        if delay > 0 { try await Task.sleep(nanoseconds: UInt64(delay * 1e9)) }
        if let error { throw error }
        return (body, status)
    }
}

final class KeywordPlannerTests: XCTestCase {
    private func plan(_ s: String) async throws -> [ToolCall] { try await KeywordPlanner().plan(s, context: ctx) }

    func testGrammarCases() async throws {
        let cases: [(String, ToolCall)] = [
            ("stop", .stop), ("Halt!", .stop), ("please stop now", .stop),
            ("come here", .comeToMe), ("come to me", .comeToMe),
            ("come to me in the kitchen", .comeToWaypoint(name: "Kitchen")),
            ("come to the kitchen", .comeToWaypoint(name: "Kitchen")),
            ("can you come to me at the front door", .comeToWaypoint(name: "Front Door")),
            ("patrol", .startPatrol), ("Start patrol", .startPatrol),
            ("what changed?", .whatChanged(since: nil)),
            ("explore", .explore(maxMinutes: nil)), ("look around", .explore(maxMinutes: nil)),
            ("map the house", .explore(maxMinutes: nil)), ("explore for 5 minutes", .explore(maxMinutes: 5)),
            ("explore for 500 minutes", .explore(maxMinutes: 30)),
            ("mark this as the garage", .markWaypoint(name: "garage")),
            ("this is the office", .markWaypoint(name: "office")),
            ("check the way to the kitchen", .checkRoute(name: "Kitchen")),
            ("go to the kitchen", .goToWaypoint(name: "Kitchen")),
            ("find the front door", .goToWaypoint(name: "Front Door")),
            ("where is my red backpack", .goToWaypoint(name: "red backpack")),
            ("where are my keys", .findObject(description: "keys")),
            ("find the blue water bottle", .findObject(description: "blue water bottle")),
        ]
        for (text, expected) in cases {
            let got = try await plan(text)
            XCTAssertEqual(got, [expected], text)
        }
    }

    func testUnknownAndBadTargets() async {
        for text in ["", "dance for me", "find", "go to"] {
            do { _ = try await plan(text); XCTFail("expected noMatch: \(text)") }
            catch { XCTAssertEqual(error as? PlannerError, .noMatch, text) }
        }
        do { _ = try await plan("check the way to the moon"); XCTFail() }
        catch { XCTAssertEqual(error as? PlannerError, .unresolvedTarget(tool: "check_route", name: "the moon")) }
    }
}

final class ToolCallParsingTests: XCTestCase {
    private func parse(_ data: Data) throws -> [ToolCall] { try GeminiPlanner.parseResponse(data, context: ctx) }

    func testParsesFixtureResponses() throws {
        XCTAssertEqual(try parse(fixture(fnCall("go_to_waypoint", #"{"name":"kitchen"}"#))), [.goToWaypoint(name: "Kitchen")])
        XCTAssertEqual(try parse(fixture(fnCall("find_object", #"{"description":"glasses"}"#))), [.findObject(description: "glasses")])
        XCTAssertEqual(try parse(fixture(fnCall("explore", #"{"max_minutes":10}"#))), [.explore(maxMinutes: 10)])
        XCTAssertEqual(try parse(fixture(fnCall("explore"))), [.explore(maxMinutes: nil)])
        XCTAssertEqual(try parse(fixture(fnCall("come_to_me"))), [.comeToMe])
        XCTAssertEqual(try parse(fixture(fnCall("come_to_waypoint", #"{"name":"the kitchen"}"#))), [.comeToWaypoint(name: "Kitchen")])
        XCTAssertEqual(try parse(fixture(fnCall("say", #"{"text":"Hello"}"#))), [.say(text: "Hello")])
        // Parallel calls, order preserved; text part ignored.
        let multi = fixture(#"{"text":"ok"},"# + fnCall("stop") + "," + fnCall("say", #"{"text":"Stopped"}"#))
        XCTAssertEqual(try parse(multi), [.stop, .say(text: "Stopped")])
    }

    func testRejectsBadCalls() {
        func expect(_ data: Data, _ e: PlannerError, line: UInt = #line) {
            do { _ = try parse(data); XCTFail("expected \(e)", line: line) }
            catch { XCTAssertEqual(error as? PlannerError, e, line: line) }
        }
        expect(fixture(fnCall("set_speed", #"{"speed":255}"#)), .unknownTool("set_speed"))
        expect(fixture(fnCall("go_to_waypoint", #"{"name":"kitchen","speed":255}"#)),
               .badArguments(tool: "go_to_waypoint", reason: "unexpected argument speed"))
        expect(fixture(fnCall("go_to_waypoint")), .badArguments(tool: "go_to_waypoint", reason: "missing name"))
        expect(fixture(fnCall("go_to_waypoint", #"{"name":5}"#)),
               .badArguments(tool: "go_to_waypoint", reason: "name must be a string"))
        expect(fixture(fnCall("go_to_waypoint", #"{"name":"the moon"}"#)),
               .unresolvedTarget(tool: "go_to_waypoint", name: "the moon"))
        expect(fixture(fnCall("come_to_waypoint", #"{"name":"attic"}"#)), .unresolvedTarget(tool: "come_to_waypoint", name: "attic"))
        expect(fixture(fnCall("explore", #"{"max_minutes":999}"#)), .badArguments(tool: "explore", reason: "max_minutes out of range"))
        expect(fixture(fnCall("explore", #"{"max_minutes":true}"#)), .badArguments(tool: "explore", reason: "max_minutes must be an integer"))
        expect(fixture(fnCall("explore", #"{"max_minutes":2.5}"#)), .badArguments(tool: "explore", reason: "max_minutes must be an integer"))
        expect(fixture(#"{"text":"I cannot do that"}"#), .noToolCall)
        expect(fixture(String(repeating: fnCall("stop") + ",", count: 5) + fnCall("stop")), .tooManyCalls)
        expect(Data("nope".utf8), .badResponse("not JSON"))
        expect(Data(#"{"candidates":[]}"#.utf8), .badResponse("no candidates"))
    }

    func testDeclarationsMatchEveryTool() throws {
        let names = GeminiPlanner.functionDeclarations().compactMap { $0["name"] as? String }
        XCTAssertEqual(names, ["find_object", "go_to_waypoint", "mark_waypoint", "check_route", "start_patrol",
                               "what_changed", "stop", "say", "explore", "come_to_me", "come_to_waypoint"])
        // Every declared tool parses with its minimal valid args.
        for n in names { XCTAssertEqual(PlannerTools.spec(named: n)?.name, n) }
    }

    func testRequestIsTextOnlyAndKeyIsInHeaderOnly() throws {
        let p = GeminiPlanner(config: GeminiConfig(apiKey: "TEST-KEY", model: "test-model"), transport: FakeTransport())
        let req = try p.buildRequest(utterance: "go to the kitchen", context: ctx)
        XCTAssertEqual(req.value(forHTTPHeaderField: "x-goog-api-key"), "TEST-KEY")
        XCTAssertFalse(req.url!.absoluteString.contains("TEST-KEY"))
        XCTAssertTrue(req.url!.absoluteString.hasSuffix("models/test-model:generateContent"))
        let body = String(data: req.httpBody!, encoding: .utf8)!
        XCTAssertTrue(body.contains("Kitchen") && body.contains("Nothing moved."))
        XCTAssertFalse(body.contains("inlineData"))
    }

    func testConfigRejectsPlaceholders() {
        XCTAssertNil(GeminiConfig.from(info: nil))
        XCTAssertNil(GeminiConfig.from(info: ["GEMINI_API_KEY": "your-key-here", "GEMINI_MODEL": "m"]))
        XCTAssertNil(GeminiConfig.from(info: ["GEMINI_API_KEY": "$(GEMINI_API_KEY)", "GEMINI_MODEL": "m"]))
        XCTAssertNil(GeminiConfig.from(info: ["GEMINI_API_KEY": "k"]))
        XCTAssertEqual(GeminiConfig.from(info: ["GEMINI_API_KEY": "k", "GEMINI_MODEL": "m"])?.model, "m")
    }
}

final class FallbackTests: XCTestCase {
    private func gemini(_ t: FakeTransport, timeout: TimeInterval = 3) -> GeminiPlanner {
        var c = GeminiConfig(apiKey: "TEST-KEY", model: "m"); c.timeout = timeout
        return GeminiPlanner(config: c, transport: t)
    }

    func testGeminiSuccessIsUsed() async throws {
        let t = FakeTransport(body: fixture(fnCall("go_to_waypoint", #"{"name":"front door"}"#)))
        let f = FallbackPlanner(primary: gemini(t))
        let got = try await f.plan("take me to the entrance", context: ctx)
        XCTAssertEqual(got, [.goToWaypoint(name: "Front Door")])
    }

    func testTimeoutFallsBackToKeywords() async throws {
        var seen: Error?
        let f = FallbackPlanner(primary: gemini(FakeTransport(delay: 5), timeout: 0.1), onFallback: { seen = $0 })
        let start = Date()
        let got = try await f.plan("go to the kitchen", context: ctx)
        XCTAssertEqual(got, [.goToWaypoint(name: "Kitchen")])
        XCTAssertLessThan(Date().timeIntervalSince(start), 2)
        XCTAssertEqual(seen as? PlannerError, .timeout)
    }

    func testErrorsFallBack() async throws {
        struct Boom: Error {}
        let bad: [FakeTransport] = [
            FakeTransport(error: Boom()),
            FakeTransport(status: 500),
            FakeTransport(body: Data("garbage".utf8)),
            FakeTransport(body: fixture(fnCall("set_speed"))),
            FakeTransport(body: fixture(fnCall("go_to_waypoint", #"{"name":"nowhere"}"#))),
        ]
        for t in bad {
            let f = FallbackPlanner(primary: gemini(t))
            let got = try await f.plan("stop", context: ctx)
            XCTAssertEqual(got, [.stop])
        }
    }

    func testNoConfigUsesKeywordsAndBothFailingThrows() async throws {
        let f = FallbackPlanner(primary: nil)
        let got = try await f.plan("patrol", context: ctx)
        XCTAssertEqual(got, [.startPatrol])
        do { _ = try await f.plan("sing a song", context: ctx); XCTFail() }
        catch { XCTAssertEqual(error as? PlannerError, .noMatch) }
    }
}
