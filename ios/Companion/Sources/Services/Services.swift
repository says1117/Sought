import AVFoundation
import Speech
import SwiftUI
import UIKit

// Speech in (mic search), speech out (spoken updates while guiding), haptics, and app settings.

// MARK: - Settings

@MainActor
final class AppSettings: ObservableObject {
    @AppStorage("userName") var userName = "Luca"
    @AppStorage("highContrast") var highContrast = false
    @AppStorage("voiceFeedback") var voiceFeedback = true
    @AppStorage("haptics") var haptics = true
}

// MARK: - Speech input

@MainActor
final class SpeechInput: ObservableObject {
    @Published var transcript = ""
    @Published var isListening = false
    @Published var errorText: String?

    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    private let engine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var silence: Timer?

    func start() {
        errorText = nil
        SFSpeechRecognizer.requestAuthorization { status in
            Task { @MainActor in
                guard status == .authorized else { self.errorText = "Speech is off. You can type instead."; return }
                AVAudioApplication.requestRecordPermission { ok in
                    Task { @MainActor in
                        guard ok else { self.errorText = "Microphone is off. You can type instead."; return }
                        self.begin()
                    }
                }
            }
        }
    }

    private func begin() {
        guard let recognizer, recognizer.isAvailable else { errorText = "Speech is not available right now. You can type instead."; return }
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playAndRecord, mode: .measurement, options: [.duckOthers, .defaultToSpeaker])
            try session.setActive(true, options: .notifyOthersOnDeactivation)
            let req = SFSpeechAudioBufferRecognitionRequest()
            req.shouldReportPartialResults = true
            request = req
            let input = engine.inputNode
            input.removeTap(onBus: 0)
            input.installTap(onBus: 0, bufferSize: 1024, format: input.outputFormat(forBus: 0)) { buf, _ in req.append(buf) }
            engine.prepare()
            try engine.start()
            transcript = ""
            isListening = true
            UIAccessibility.post(notification: .announcement, argument: "Listening")
            task = recognizer.recognitionTask(with: req) { [weak self] result, error in
                Task { @MainActor in
                    guard let self else { return }
                    if let result {
                        self.transcript = result.bestTranscription.formattedString
                        self.armSilenceTimer()
                        if result.isFinal { self.stop() }
                    }
                    if error != nil { self.stop() }
                }
            }
        } catch {
            errorText = "Could not start the microphone. You can type instead."
            stop()
        }
    }

    /// Stop 1.5 s after the person stops talking.
    private func armSilenceTimer() {
        silence?.invalidate()
        silence = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.stop() }
        }
    }

    func stop() {
        silence?.invalidate()
        if engine.isRunning { engine.stop(); engine.inputNode.removeTap(onBus: 0) }
        request?.endAudio()
        task?.cancel()
        request = nil; task = nil
        if isListening { isListening = false }
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
}

// MARK: - Speech output and announcements

@MainActor
final class Speaker {
    static let shared = Speaker()
    private let synth = AVSpeechSynthesizer()
    var enabled = true

    /// VoiceOver users get an announcement (VoiceOver speaks it); everyone else gets the synthesizer.
    func say(_ text: String) {
        if UIAccessibility.isVoiceOverRunning {
            UIAccessibility.post(notification: .announcement, argument: text)
            return
        }
        guard enabled else { return }
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
        synth.stopSpeaking(at: .word)
        let u = AVSpeechUtterance(string: text)
        u.rate = AVSpeechUtteranceDefaultSpeechRate * 0.95
        synth.speak(u)
    }
}

// MARK: - Haptics

@MainActor
final class Haptics {
    static let shared = Haptics()
    var enabled = true
    private let impact = UIImpactFeedbackGenerator(style: .medium)
    private let notify = UINotificationFeedbackGenerator()

    func tap() { guard enabled else { return }; impact.impactOccurred() }
    func success() { guard enabled else { return }; notify.notificationOccurred(.success) }
    func warning() { guard enabled else { return }; notify.notificationOccurred(.warning) }

    /// Pulse interval that gets shorter as the robot closes in: 1.2 s at 4 m and above, 0.25 s at 1 m.
    static func pulseInterval(distanceM: Double) -> Double {
        let t = max(0, min(1, (distanceM - 1) / 3))
        return 0.25 + t * 0.95
    }
}
