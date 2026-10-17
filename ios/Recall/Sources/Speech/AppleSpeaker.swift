import Foundation
import AVFoundation

/// AVSpeechSynthesizer-backed Speaker.
final class AppleSpeaker: Speaking {
    private let synth = AVSpeechSynthesizer()

    func speak(_ text: String) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        synth.stopSpeaking(at: .immediate)
        synth.speak(AVSpeechUtterance(string: t))
    }

    func stopSpeaking() { synth.stopSpeaking(at: .immediate) }
}
