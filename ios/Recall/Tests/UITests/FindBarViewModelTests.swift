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

actor PlannerGate {
    private var continuation: CheckedContinuation<[ToolCall], Never>?
    func wait() async -> [ToolCall] {
        await withCheckedContinuation { continuation = $0 }
    }
    func isPending() -> Bool { continuation != nil }
    func resume(_ calls: [ToolCall]) {
        continuation?.resume(returning: calls)
        continuation = nil
    }
}

struct LatePlanner: Planner {
    let gate: PlannerGate
    func plan(_ utterance: String, context: PlannerContext) async throws -> [ToolCall] {
        await gate.wait()
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
                       speaker: FakeSpeaker? = nil, talk: PushToTalk? = nil,
                       timeout: TimeInterval = 3) -> FindBarViewModel {
        FindBarViewModel(planner: planner, executor: executor, speaker: speaker ?? FakeSpeaker(), talk: talk, plannerTimeout: timeout)
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
        await vm.run("patrol").value
        XCTAssertEqual(exec.executed, [.startPatrol])
    }

    func testPlannerErrorFallsBackToKeywords() async {
        let exec = LoggingToolExecutor(); exec.log = { _ in }
        let vm = make(StubPlanner(result: .failure(PlannerError.transport("offline"))), executor: exec)
        await vm.run("patrol").value
        XCTAssertEqual(exec.executed, [.startPatrol])
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

    func testSpokenOrTypedStopUsesImmediateBrakeWithoutExecutingTools() async {
        var braked = false
        let exec = LoggingToolExecutor(stop: { braked = true }); exec.log = { _ in }
        let vm = make(StubPlanner(result: .success([.comeToMe])), executor: exec)
        await vm.run("please stop immediately").value
        XCTAssertTrue(braked)
        XCTAssertTrue(exec.executed.isEmpty)
        XCTAssertEqual(vm.statusLine, "Stopped.")
    }

    func testLatePlannerResultAfterStopDoesNotExecute() async {
        let gate = PlannerGate()
        let exec = LoggingToolExecutor(); exec.log = { _ in }
        let vm = make(LatePlanner(gate: gate), executor: exec)
        let task = vm.run("patrol")
        for _ in 0..<100 {
            if await gate.isPending() { break }
            await Task.yield()
        }
        let plannerStarted = await gate.isPending()
        XCTAssertTrue(plannerStarted)
        vm.stop()
        await gate.resume([.startPatrol])
        await task.value
        XCTAssertTrue(exec.executed.isEmpty)
        XCTAssertEqual(vm.statusLine, "Stopped.")
    }

    func testStopDuringPermissionPromptDoesNotStartListeningLater() async {
        let rec = FakeRecognizer(); rec.holdAuthorization = true
        let talk = PushToTalk(recognizer: rec, isStationary: { true })
        let vm = make(StubPlanner(result: .success([])), talk: talk)
        let startup = Task { await vm.startListening() }
        for _ in 0..<100 where !rec.isAwaitingAuthorization { await Task.yield() }
        XCTAssertTrue(rec.isAwaitingAuthorization)
        XCTAssertEqual(vm.state, .starting)
        vm.stop()
        rec.resolveAuthorization(true)
        await startup.value
        XCTAssertEqual(vm.state, .idle)
        XCTAssertEqual(vm.statusLine, "Stopped.")
        XCTAssertEqual(rec.started, 0)
    }

    func testTypedSubmitDoesNotOverlapSpeechStartup() async {
        let rec = FakeRecognizer(); rec.holdAuthorization = true
        let talk = PushToTalk(recognizer: rec, isStationary: { true })
        let vm = make(StubPlanner(result: .success([.startPatrol])), talk: talk)
        let startup = Task { await vm.startListening() }
        for _ in 0..<100 where !rec.isAwaitingAuthorization { await Task.yield() }
        XCTAssertTrue(rec.isAwaitingAuthorization)
        vm.text = "patrol"
        vm.submitText()
        XCTAssertEqual(vm.state, .starting)
        rec.resolveAuthorization(true)
        await startup.value
        vm.stop()
    }

    func testLoggingExecutorInvokesImmediateStopHandler() {
        var braked = false
        let executor = LoggingToolExecutor(stop: { braked = true })
        executor.stopAll()
        XCTAssertTrue(braked)
        XCTAssertEqual(executor.stopCount, 1)
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

    func testStationaryMonitorAbortsWhenRobotStartsMoving() async throws {
        let rec = FakeRecognizer()
        var stationary = true
        let talk = PushToTalk(recognizer: rec, isStationary: { stationary })
        try await talk.begin()
        stationary = false
        try await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertEqual(talk.state, .idle)
        XCTAssertEqual(rec.cancelled, 1)
    }

    func testDescriptions() {
        XCTAssertEqual(ToolCallDescription.describe(.goToWaypoint(name: "kitchen")), "Going to kitchen")
        XCTAssertEqual(ToolCallDescription.describe([.markWaypoint(name: "desk"), .stop]),
                       "Saving this spot as desk, then Stopping")
    }
}
