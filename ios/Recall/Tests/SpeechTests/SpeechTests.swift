import XCTest
#if canImport(SpeechCore)
@testable import SpeechCore
#endif

@MainActor
final class PushToTalkTests: XCTestCase {
    func testRefusesWhenMoving() async {
        let r = FakeRecognizer()
        let t = PushToTalk(recognizer: r, isStationary: { false })
        do { try await t.begin(); XCTFail("should throw") } catch { XCTAssertEqual(error as? SpeechError, .notStationary) }
        XCTAssertEqual(t.state, .idle)
        XCTAssertEqual(r.started, 0)
    }

    func testRefusesWithoutAuthorization() async {
        let r = FakeRecognizer(); r.authorized = false
        let t = PushToTalk(recognizer: r, isStationary: { true })
        do { try await t.begin(); XCTFail("should throw") } catch { XCTAssertEqual(error as? SpeechError, .notAuthorized) }
        XCTAssertEqual(t.state, .idle)
    }

    func testListenThenEndReturnsTranscript() async throws {
        let r = FakeRecognizer()
        let t = PushToTalk(recognizer: r, isStationary: { true })
        try await t.begin()
        XCTAssertEqual(t.state, .listening)
        let text = try await t.end()
        XCTAssertEqual(text, "find my keys")
        XCTAssertEqual(t.state, .idle)
    }

    func testPartialsForwardedWhileListening() async throws {
        let r = FakeRecognizer()
        let t = PushToTalk(recognizer: r, isStationary: { true })
        var seen: [String] = []
        try await t.begin { seen.append($0) }
        r.partialSink?("find")
        await Task.yield(); await Task.yield()
        XCTAssertEqual(seen, ["find"])
    }

    func testAbortsWhenRobotStartsMoving() async throws {
        let r = FakeRecognizer()
        var stationary = true
        let t = PushToTalk(recognizer: r, isStationary: { stationary })
        try await t.begin()
        stationary = false
        t.checkStationary()
        XCTAssertEqual(t.state, .idle)
        XCTAssertEqual(r.cancelled, 1)
    }

    func testStartFailureLeavesIdle() async {
        let r = FakeRecognizer(); r.startError = SpeechError.unavailable
        let t = PushToTalk(recognizer: r, isStationary: { true })
        do { try await t.begin(); XCTFail("should throw") } catch {}
        XCTAssertEqual(t.state, .idle)
    }

    func testEndWhenIdleIsEmpty() async throws {
        let t = PushToTalk(recognizer: FakeRecognizer(), isStationary: { true })
        let text = try await t.end()
        XCTAssertEqual(text, "")
    }
}
