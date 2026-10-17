import Foundation

// Test doubles, kept next to the protocols so every test target shares them.

final class FakeRecognizer: SpeechRecognizing {
    var authorized = true
    var isOnDevice = true
    var startError: Error?
    var transcript = "find my keys"
    private(set) var started = 0, cancelled = 0, finished = 0
    var partialSink: ((String) -> Void)?
    var holdFinish = false
    private var finishContinuation: CheckedContinuation<String, Never>?
    var isAwaitingFinish: Bool { finishContinuation != nil }
    var holdAuthorization = false
    private var authorizationContinuation: CheckedContinuation<Bool, Never>?
    var isAwaitingAuthorization: Bool { authorizationContinuation != nil }

    func requestAuthorization() async -> Bool {
        guard holdAuthorization else { return authorized }
        return await withCheckedContinuation { authorizationContinuation = $0 }
    }
    func resolveAuthorization(_ allowed: Bool) {
        authorizationContinuation?.resume(returning: allowed)
        authorizationContinuation = nil
    }
    func start(onPartial: @escaping (String) -> Void) throws {
        if let startError { throw startError }
        started += 1
        partialSink = onPartial
    }
    func finish() async throws -> String {
        finished += 1
        guard holdFinish else { return transcript }
        return await withCheckedContinuation { finishContinuation = $0 }
    }
    func resolveFinish(_ text: String) {
        finishContinuation?.resume(returning: text)
        finishContinuation = nil
    }
    func cancel() { cancelled += 1 }
}

final class FakeSpeaker: Speaking {
    private(set) var spoken: [String] = []
    private(set) var stops = 0
    func speak(_ text: String) { spoken.append(text) }
    func stopSpeaking() { stops += 1 }
}
