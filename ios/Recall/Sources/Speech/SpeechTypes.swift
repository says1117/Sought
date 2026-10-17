import Foundation

// Speech contracts (plan v2 section 6.5). Pure Foundation so they build under SwiftPM and unit test with fakes.

enum SpeechError: Error, Equatable {
    case notAuthorized
    case unavailable
    case notStationary
    case cancelled
    case recognitionFailed(String)
}

/// Push-to-talk recognizer. `start` begins listening; `stop` ends it and delivers the final transcript.
@MainActor
protocol SpeechRecognizing: AnyObject {
    /// Ask for mic + speech permission. Returns true when both are granted.
    func requestAuthorization() async -> Bool
    /// True when recognition runs on the phone (no audio leaves the device).
    var isOnDevice: Bool { get }
    /// Begin listening. `onPartial` receives live text; throws if it cannot start.
    func start(onPartial: @escaping (String) -> Void) throws
    /// Stop listening and return the final transcript (may be empty).
    func finish() async throws -> String
    /// Abort without a result.
    func cancel()
}

/// Speaks short confirmations.
@MainActor
protocol Speaking: AnyObject {
    func speak(_ text: String)
    func stopSpeaking()
}

/// Whether the robot is stationary right now. Provided by the drive/controller layer, not hardware here.
typealias StationaryProvider = () -> Bool

/// Push-to-talk state machine. Refuses to listen unless the robot is stationary, and aborts if it moves.
@MainActor
final class PushToTalk {
    enum State: Equatable { case idle, authorizing, listening, finishing }

    private(set) var state: State = .idle
    private(set) var partial = ""
    var onAbort: (() -> Void)?
    private let recognizer: SpeechRecognizing
    private let isStationary: StationaryProvider
    private var stationaryMonitor: Task<Void, Never>?
    private var generation = 0

    init(recognizer: SpeechRecognizing, isStationary: @escaping StationaryProvider) {
        self.recognizer = recognizer
        self.isStationary = isStationary
    }

    func begin(onPartial: @escaping (String) -> Void = { _ in }) async throws {
        guard state == .idle else { return }
        let currentGeneration = generation
        guard isStationary() else { state = .idle; throw SpeechError.notStationary }
        state = .authorizing
        guard await recognizer.requestAuthorization() else {
            guard generation == currentGeneration else { throw SpeechError.cancelled }
            state = .idle
            throw SpeechError.notAuthorized
        }
        guard generation == currentGeneration, state == .authorizing else { throw SpeechError.cancelled }
        guard isStationary() else { state = .idle; throw SpeechError.notStationary }
        partial = ""
        do {
            try recognizer.start { [weak self] text in
                Task { @MainActor in
                    guard let self, self.state == .listening else { return }
                    self.partial = text
                    onPartial(text)
                }
            }
        } catch {
            recognizer.cancel()
            state = .idle
            throw error
        }
        guard generation == currentGeneration, state == .authorizing else {
            recognizer.cancel()
            throw SpeechError.cancelled
        }
        state = .listening
        stationaryMonitor = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 100_000_000)
                guard !Task.isCancelled, let self else { return }
                self.checkStationary()
            }
        }
    }

    /// Release the button: returns the final transcript.
    func end() async throws -> String {
        guard state == .listening else { return "" }
        guard isStationary() else { abort(); throw SpeechError.notStationary }
        state = .finishing
        defer {
            stationaryMonitor?.cancel()
            stationaryMonitor = nil
            state = .idle
        }
        let transcript = try await recognizer.finish()
        guard state == .finishing, isStationary() else {
            recognizer.cancel()
            throw SpeechError.notStationary
        }
        return transcript
    }

    /// Call when the robot starts moving or the app backgrounds.
    func abort() {
        generation &+= 1
        let wasActive = state != .idle
        stationaryMonitor?.cancel()
        stationaryMonitor = nil
        if wasActive { recognizer.cancel() }
        state = .idle
        if wasActive { onAbort?() }
    }

    /// Poll point for the UI: stop listening if the robot is no longer stationary.
    func checkStationary() {
        if (state == .listening || state == .finishing) && !isStationary() { abort() }
    }
}
