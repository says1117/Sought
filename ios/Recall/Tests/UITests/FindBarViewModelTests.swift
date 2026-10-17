import XCTest
#if canImport(PlannerCore)
@testable import PlannerCore
#endif
#if canImport(SpeechCore)
@testable import SpeechCore
#endif
#if canImport(UICore)
@testable import UICore
#endif

struct StubPlanner: Planner {
    var result: Result<[ToolCall], Error>
    var delay: TimeInterval = 0
    func plan(_ utterance: String, context: PlannerContext) async throws -> [ToolCall] {
        if delay > 0 { try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
        return try result.get()
    }
}

final class FailingExecutor: ToolExecuting {
    private(set) var stopCount = 0
    func execute(_ call: ToolCall) async throws { throw PlannerError.transport("boom") }
    func stopAll() { stopCount += 1 }
}

@MainActor
final class FindBarViewModelTests: XCTestCase {
    private func make(_ planner: Planner, executor: ToolExecuting = LoggingToolExecutor(),
                       speaker: FakeSpeaker = FakeSpeaker(), talk: PushToTalk? = nil,
                       timeout: TimeInterval = 3) -> FindBarViewModel {
        FindBarViewModel(planner: planner, executor: executor, speaker: speaker, talk: talk, plannerTimeout: timeout)
    }

    func testTextRunsPlannerExecutesAndSpeaks() async {
        let exec = LoggingToolExecutor(); exec.log = { _ in }
        let sp = FakeSpeaker()
        let vm = make(StubPlanner(result: .success([.findObject(description: "keys")])), executor: exec, speaker: sp)
        await vm.run("find my keys").value
        XCTAssertEqual(exec.executed, [.findObject(description: "keys")])
        XCTAssertEqual(vm.state, .idle)
        XCTAssertEqual(vm.lastToolCall, "Looking for keys")
        XCTAssertEqual(sp.spoken, ["Looking for keys"])
    }

    func testSubmitTextClearsFieldAndIgnoresBlank() async {
        let exec = LoggingToolExecutor(); exec.log = { _ in }
        let vm = make(StubPlanner(result: .success([.startPatrol])), executor: exec)
        vm.text = "   "
        vm.submitText()
        XCTAssertEqual(vm.state, .idle)
        vm.text = "patrol"
        vm.submitText()
        XCTAssertEqual(vm.text, "")
        XCTAssertEqual(vm.state, .planning)
    }

    func testSlowPlannerFallsBackToKeywordsAfterTimeout() async {
        let exec = LoggingToolExecutor(); exec.log = { _ in }
        let slow = StubPlanner(result: .success([.comeToMe]), delay: 5)
        let vm = make(slow, executor: exec, timeout: 0.05)
        await vm.run("stop").value
        XCTAssertEqual(exec.executed, [.stop])
    }

    func testPlannerErrorFallsBackToKeywords() async {
        let exec = LoggingToolExecutor(); exec.log = { _ in }
        let vm = make(StubPlanner(result: .failure(PlannerError.transport("offline"))), executor: exec)
        await vm.run("stop").value
        XCTAssertEqual(exec.executed, [.stop])
    }

    func testUnintelligibleRequestIsErrorState() async {
        let sp = FakeSpeaker()
        let vm = make(StubPlanner(result: .failure(PlannerError.noMatch)), speaker: sp)
        await vm.run("blorp").value
        guard case .error = vm.state else { return XCTFail("expected error, got \(vm.state)") }
        XCTAssertFalse(sp.spoken.isEmpty)
    }

    func testExecutorFailureIsErrorState() async {
        let vm = make(StubPlanner(result: .success([.startPatrol])), executor: FailingExecutor())
        await vm.run("patrol").value
        guard case .error = vm.state else { return XCTFail("expected error, got \(vm.state)") }
    }

    func testSayIsSpokenNotExecuted() async {
        let exec = LoggingToolExecutor(); exec.log = { _ in }
        let sp = FakeSpeaker()
        let vm = make(StubPlanner(result: .success([.say(text: "Hello there")])), executor: exec, speaker: sp)
        await vm.run("hi").value
        XCTAssertTrue(exec.executed.isEmpty)
        XCTAssertEqual(sp.spoken, ["Hello there"])
    }

    func testStopBrakesExecutorDirectlyAndCancelsPlanning() async {
        let exec = LoggingToolExecutor(); exec.log = { _ in }
        let vm = make(StubPlanner(result: .success([.comeToMe]), delay: 5), executor: exec)
        let task = vm.run("come here")
        XCTAssertEqual(vm.state, .planning)
        vm.stop()
        await task.value
        XCTAssertEqual(exec.stopCount, 1)
        XCTAssertTrue(exec.executed.isEmpty)
        XCTAssertEqual(vm.state, .idle)
    }

    func testVoiceFlowTranscriptGoesThroughPlanner() async {
        let exec = LoggingToolExecutor(); exec.log = { _ in }
        let rec = FakeRecognizer(); rec.transcript = "start patrol"
        let talk = PushToTalk(recognizer: rec, isStationary: { true })
        let vm = make(StubPlanner(result: .success([.startPatrol])), executor: exec, talk: talk)
        await vm.toggleListening()
        XCTAssertEqual(vm.state, .listening)
        await vm.toggleListening()
        XCTAssertEqual(exec.executed, [.startPatrol])
        XCTAssertEqual(vm.state, .idle)
    }

    func testVoiceRefusedWhileMovingShowsError() async {
        let rec = FakeRecognizer()
        let talk = PushToTalk(recognizer: rec, isStationary: { false })
        let vm = make(StubPlanner(result: .success([])), talk: talk)
        await vm.startListening()
        guard case .error(let m) = vm.state else { return XCTFail("expected error") }
        XCTAssertTrue(m.contains("moving"))
        XCTAssertEqual(rec.started, 0)
    }

    func testRobotMovedStopsListening() async {
        let rec = FakeRecognizer()
        let talk = PushToTalk(recognizer: rec, isStationary: { true })
        let vm = make(StubPlanner(result: .success([])), talk: talk)
        await vm.startListening()
        vm.robotMoved()
        XCTAssertEqual(vm.state, .idle)
        XCTAssertEqual(rec.cancelled, 1)
    }

    func testDescriptions() {
        XCTAssertEqual(ToolCallDescription.describe(.goToWaypoint(name: "kitchen")), "Going to kitchen")
        XCTAssertEqual(ToolCallDescription.describe([.markWaypoint(name: "desk"), .stop]),
                       "Saving this spot as desk, then Stopping")
    }
}
