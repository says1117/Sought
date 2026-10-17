import Foundation

// Test doubles, kept next to the protocols so every test target shares them.

final class FakeRecognizer: SpeechRecognizing {
    var authorized = true
    var isOnDevice = true
    var startError: Error?
    var transcript = "find my keys"
    private(set) var started = 0, cancelled = 0, finished = 0
    var partialSink: ((String) -> Void)?

    func requestAuthorization() async -> Bool { authorized }
    func start(onPartial: @escaping (String) -> Void) throws {
        if let startError { throw startError }
        started += 1
        partialSink = onPartial
    }
    func finish() async throws -> String { finished += 1; return transcript }
    func cancel() { cancelled += 1 }
}

final class FakeSpeaker: Speaking {
    private(set) var spoken: [String] = []
    private(set) var stops = 0
    func speak(_ text: String) { spoken.append(text) }
    func stopSpeaking() { stops += 1 }
}

