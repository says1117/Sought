import Foundation
import Speech
import AVFoundation

/// SFSpeechRecognizer push-to-talk, preferring on-device recognition. Not compiled under SwiftPM
/// (needs the app's audio session); mic and speech do not work in the Simulator.
@MainActor
final class AppleSpeechRecognizer: SpeechRecognizing {
    private let recognizer: SFSpeechRecognizer?
    private let engine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var latest = ""
    private var continuation: CheckedContinuation<String, Error>?
    private var recognitionGeneration = 0

    init(locale: Locale = .current) { recognizer = SFSpeechRecognizer(locale: locale) }

    var isOnDevice: Bool { recognizer?.supportsOnDeviceRecognition ?? false }

    func requestAuthorization() async -> Bool {
        let speech = await withCheckedContinuation { c in
            SFSpeechRecognizer.requestAuthorization { c.resume(returning: $0 == .authorized) }
        }
        guard speech else { return false }
        return await AVAudioApplication.requestRecordPermission()
    }

    func start(onPartial: @escaping (String) -> Void) throws {
        guard let recognizer, recognizer.isAvailable else { throw SpeechError.unavailable }
        cancel()
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .measurement, options: .duckOthers)
        try session.setActive(true, options: .notifyOthersOnDeactivation)

        let req = SFSpeechAudioBufferRecognitionRequest()
        let generation = recognitionGeneration
        req.shouldReportPartialResults = true
        req.requiresOnDeviceRecognition = recognizer.supportsOnDeviceRecognition
        request = req
        latest = ""

        task = recognizer.recognitionTask(with: req) { [weak self] result, error in
            Task { @MainActor [weak self] in
                guard let self, self.recognitionGeneration == generation else { return }
                if let result {
                    self.latest = result.bestTranscription.formattedString
                    onPartial(self.latest)
                    if result.isFinal { self.complete(.success(self.latest)) }
                } else if let error {
                    // A stopped session with some text is still a usable transcript.
                    self.complete(self.latest.isEmpty ? .failure(SpeechError.recognitionFailed(error.localizedDescription))
                                                      : .success(self.latest))
                }
            }
        }

        let input = engine.inputNode
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: input.outputFormat(forBus: 0)) { [weak req] buf, _ in
            req?.append(buf)
        }
        engine.prepare()
        try engine.start()
    }

    func finish() async throws -> String {
        let generation = recognitionGeneration
        stopAudio()
        request?.endAudio()
        return try await withCheckedThrowingContinuation { c in
            continuation = c
            // Safety net: never hang if the recognizer never reports final.
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                guard let self, self.recognitionGeneration == generation, self.continuation != nil else { return }
                self.complete(.success(self.latest))
            }
        }
    }

    func cancel() {
        recognitionGeneration &+= 1
        stopAudio()
        task?.cancel()
        task = nil
        request = nil
        complete(.success(""))
    }

    private func stopAudio() {
        if engine.isRunning { engine.stop() }
        engine.inputNode.removeTap(onBus: 0)
    }

    private func complete(_ result: Result<String, Error>) {
        guard let c = continuation else { return }
        continuation = nil
        task = nil
        request = nil
        c.resume(with: result)
    }
}
