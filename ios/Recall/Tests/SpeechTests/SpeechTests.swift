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

    func testAbortDuringAuthorizationPreventsRecognizerStart() async {
        let r = FakeRecognizer(); r.holdAuthorization = true
        let t = PushToTalk(recognizer: r, isStationary: { true })
        let begin = Task { try await t.begin() }
        for _ in 0..<100 where !r.isAwaitingAuthorization { await Task.yield() }
        XCTAssertTrue(r.isAwaitingAuthorization)
        XCTAssertEqual(t.state, .authorizing)
        t.abort()
        r.resolveAuthorization(true)
        do { try await begin.value; XCTFail("cancelled startup should not begin listening") }
        catch { XCTAssertEqual(error as? SpeechError, .cancelled) }
        XCTAssertEqual(t.state, .idle)
        XCTAssertEqual(r.started, 0)
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

    func testOldPartialCannotEnterNewSession() async throws {
        let r = FakeRecognizer()
        let t = PushToTalk(recognizer: r, isStationary: { true })
        var seen: [String] = []
        try await t.begin { seen.append($0) }
        let oldPartial = r.partialSink
        _ = try await t.end()
        try await t.begin { seen.append($0) }
        oldPartial?("stale command")
        r.partialSink?("new command")
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(seen, ["new command"])
        XCTAssertEqual(t.partial, "new command")
        t.abort()
    }

    func testOldFinishCannotCancelNewSession() async throws {
        let r = FakeRecognizer(); r.holdFinish = true
        let t = PushToTalk(recognizer: r, isStationary: { true })
        try await t.begin()
        let ending = Task { try await t.end() }
        for _ in 0..<100 where !r.isAwaitingFinish { await Task.yield() }
        XCTAssertTrue(r.isAwaitingFinish)
        t.abort()
        try await t.begin()
        let cancelCount = r.cancelled
        r.resolveFinish("stale command")
        do { _ = try await ending.value; XCTFail("old session must be cancelled") }
        catch { XCTAssertEqual(error as? SpeechError, .cancelled) }
        XCTAssertEqual(t.state, .listening)
        XCTAssertEqual(r.cancelled, cancelCount)
        t.abort()
    }

    func testEndWhenIdleIsEmpty() async throws {
        let t = PushToTalk(recognizer: FakeRecognizer(), isStationary: { true })
        let text = try await t.end()
        XCTAssertEqual(text, "")
    }
}
