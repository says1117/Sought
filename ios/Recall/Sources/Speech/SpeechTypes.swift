import Foundation

// Speech contracts (plan v2 section 6.5). Pure Foundation so they build under SwiftPM and unit test with fakes.

enum SpeechError: Error, Equatable {
    case notAuthorized
    case unavailable
    case notStationary
    case recognitionFailed(String)
}

/// Push-to-talk recognizer. `start` begins listening; `stop` ends it and delivers the final transcript.
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
protocol Speaking: AnyObject {
    func speak(_ text: String)
    func stopSpeaking()
}

/// Whether the robot is stationary right now. Provided by the drive/controller layer, not hardware here.
typealias StationaryProvider = () -> Bool

/// Push-to-talk state machine. Refuses to listen unless the robot is stationary, and aborts if it moves.
@MainActor
final class PushToTalk {
    enum State: Equatable { case idle, listening, finishing }

    private(set) var state: State = .idle
    private(set) var partial = ""
    private let recognizer: SpeechRecognizing
    private let isStationary: StationaryProvider

    init(recognizer: SpeechRecognizing, isStationary: @escaping StationaryProvider) {
        self.recognizer = recognizer
        self.isStationary = isStationary
    }

    func begin(onPartial: @escaping (String) -> Void = { _ in }) async throws {
        guard state == .idle else { return }
        guard isStationary() else { throw SpeechError.notStationary }
        guard await recognizer.requestAuthorization() else { throw SpeechError.notAuthorized }
        guard isStationary() else { throw SpeechError.notStationary }
        partial = ""
        try recognizer.start { [weak self] text in
            Task { @MainActor in
                guard let self, self.state == .listening else { return }
                self.partial = text
                onPartial(text)
            }
        }
        state = .listening
    }

    /// Release the button: returns the final transcript.
    func end() async throws -> String {
        guard state == .listening else { return "" }
        state = .finishing
        defer { state = .idle }
        return try await recognizer.finish()
    }

    /// Call when the robot starts moving or the app backgrounds.
    func abort() {
        guard state != .idle else { return }
        recognizer.cancel()
        state = .idle
    }

    /// Poll point for the UI: stop listening if the robot is no longer stationary.
    func checkStationary() {
        if state == .listening && !isStationary() { abort() }
    }
}
