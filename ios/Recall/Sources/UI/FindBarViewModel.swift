import Foundation
import Combine
#if canImport(PlannerCore)
@testable import PlannerCore
#endif
#if canImport(SpeechCore)
@testable import SpeechCore
#endif

/// Find bar logic: text or transcript -> Planner -> ToolCalls -> ToolExecuting. No UIKit.
/// Safety never goes through here: `stop()` brakes the executor directly and cancels any in-flight work.
@MainActor
final class FindBarViewModel: ObservableObject {
    enum State: Equatable {
        case idle, listening, planning, executing
        case error(String)
    }

    @Published var text = ""
    @Published private(set) var state: State = .idle
    @Published private(set) var statusLine = "Type or tap Talk, then say what to find."
    @Published private(set) var lastToolCall: String?

    private let planner: Planner
    private let fallback: Planner
    private let executor: ToolExecuting
    private let speaker: Speaking
    private let talk: PushToTalk?
    private let contextProvider: () -> PlannerContext
    private let plannerTimeout: TimeInterval
    private var work: Task<Void, Never>?

    init(planner: Planner,
         fallback: Planner = KeywordPlanner(),
         executor: ToolExecuting,
         speaker: Speaking,
         talk: PushToTalk? = nil,
         plannerTimeout: TimeInterval = 3,
         context: @escaping () -> PlannerContext = { PlannerContext() }) {
        self.planner = planner
        self.fallback = fallback
        self.executor = executor
        self.speaker = speaker
        self.talk = talk
        self.plannerTimeout = plannerTimeout
        self.contextProvider = context
    }

    var canTalk: Bool { talk != nil }
    var isBusy: Bool { state == .planning || state == .executing }

    // MARK: Text

    /// Submit the typed text. Always works, even with no speech or network.
    func submitText() {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, state != .listening else { return }
        text = ""
        run(t)
    }

    /// Start planning for an utterance (typed or transcribed). Returns the task so tests can await it.
    @discardableResult
    func run(_ utterance: String) -> Task<Void, Never> {
        work?.cancel()
        state = .planning
        statusLine = "Thinking about \u{201C}\(utterance)\u{201D}"
        let task = Task { [weak self] in
            guard let self else { return }
            await self.process(utterance)
        }
        work = task
        return task
    }

    // MARK: Voice (tap to start, tap again to send)

    func toggleListening() async {
        if state == .listening { await finishListening() } else { await startListening() }
    }

    func startListening() async {
        guard let talk, !isBusy, state != .listening else { return }
        speaker.stopSpeaking()
        do {
            try await talk.begin { [weak self] partial in self?.text = partial }
            state = .listening
            statusLine = "Listening. Tap again when done."
        } catch SpeechError.notStationary {
            fail("The robot is moving. Press Stop first, then talk.")
        } catch SpeechError.notAuthorized {
            fail("Microphone or speech access is off. You can still type.")
        } catch {
            fail("Voice is unavailable. You can still type.")
        }
    }

    func finishListening() async {
        guard let talk, state == .listening else { return }
        do {
            let transcript = try await talk.end().trimmingCharacters(in: .whitespacesAndNewlines)
            text = ""
            if transcript.isEmpty {
                state = .idle
                statusLine = "I did not hear anything. Try again or type."
            } else {
                await run(transcript).value
            }
        } catch {
            fail("Could not understand the audio. You can still type.")
        }
    }

    /// Robot started moving, or the app left the foreground.
    func robotMoved() {
        guard state == .listening else { return }
        talk?.abort()
        state = .idle
        statusLine = "Stopped listening because the robot moved."
    }

    // MARK: Stop (always available, never goes through the planner)

    func stop() {
        executor.stopAll()
        work?.cancel()
        work = nil
        talk?.abort()
        speaker.stopSpeaking()
        state = .idle
        statusLine = "Stopped."
        lastToolCall = ToolCallDescription.describe(.stop)
        speaker.speak("Stopped")
    }

    // MARK: Pipeline

    private func process(_ utterance: String) async {
        let calls: [ToolCall]
        do {
            calls = try await plan(utterance)
        } catch is CancellationError {
            return
        } catch {
            if Task.isCancelled { return }
            fail("I did not understand that. Try: find my keys, go to the kitchen, or stop.")
            return
        }
        if Task.isCancelled { return }

        let summary = ToolCallDescription.describe(calls)
        lastToolCall = summary
        statusLine = summary
        state = .executing
        speaker.speak(summary)

        for call in calls {
            if Task.isCancelled { return }
            if case .say = call { continue }          // already spoken as the confirmation
            do { try await executor.execute(call) }
            catch is CancellationError { return }
            catch {
                if Task.isCancelled { return }
                fail("Could not do that: \(ToolCallDescription.describe(call)).")
                return
            }
        }
        if Task.isCancelled { return }
        state = .idle
        statusLine = "Done: \(summary)"
    }

    /// Primary planner raced against the timeout; on timeout or any failure use the keyword grammar.
    private func plan(_ utterance: String) async throws -> [ToolCall] {
        let ctx = contextProvider()
        let primary = planner
        let timeout = plannerTimeout
        do {
            return try await withThrowingTaskGroup(of: [ToolCall].self) { group in
                group.addTask { try await primary.plan(utterance, context: ctx) }
                group.addTask {
                    try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                    throw PlannerError.timeout
                }
                defer { group.cancelAll() }
                return try await group.next()!
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            if Task.isCancelled { throw CancellationError() }
            return try await fallback.plan(utterance, context: ctx)
        }
    }

    private func fail(_ message: String) {
        state = .error(message)
        statusLine = message
        speaker.speak(message)
    }
}
