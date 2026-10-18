import SwiftUI

/// Real paired-phone flow; the original Settings entry point uses this same screen.
struct ComeToMeTestView: View {
    @StateObject private var model = CompanionModel()
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                HStack {
                    Text("Come to my phone").font(.title2.bold())
                    Spacer()
                    Button("Done") { model.shutdown(); dismiss() }.font(.headline)
                }
                Text("Same room · keep both apps open")
                    .font(.headline)
                Text("Enter the same six-digit code here and on the robot phone’s Robot tools → Pair phone screen, then tap Pair on both phones.")
                    .font(.body)
                TextField("Six-digit pairing code", text: $model.pairingCode)
                    .keyboardType(.numberPad).textContentType(.oneTimeCode)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel("Six-digit pairing code")
                    .accessibilityIdentifier("pairingCode")
                Button("Pair with Soughtbot", action: model.start)
                    .buttonStyle(.borderedProminent).disabled(!model.canPair || scenePhase != .active)
                    .accessibilityIdentifier("pairPhones")
                Text(statusText).font(.headline).multilineTextAlignment(.center).accessibilityIdentifier("status")
                Text(model.distanceM.map { String(format: "%.1f m", $0) } ?? "– m")
                    .font(.system(size: 48, weight: .semibold, design: .rounded)).monospacedDigit()
                    .accessibilityIdentifier("distance")
                if model.peerName != nil && !model.rangingReady {
                    Text("Hold the phones upright, facing each other, with a clear view. Waiting for fresh distance and direction.")
                        .font(.callout).multilineTextAlignment(.center)
                }
                Button(action: model.comeToMe) {
                    Text("Come to my phone").font(.title.bold()).frame(maxWidth: .infinity, minHeight: 100)
                }
                .buttonStyle(.borderedProminent).disabled(!model.canRequest || scenePhase != .active)
                .accessibilityIdentifier("comeToMe")
                Button("Stop / retry Stop", role: .destructive, action: model.cancel)
                    .font(.title3).frame(maxWidth: .infinity, minHeight: 56)
                    .buttonStyle(.bordered).disabled(!model.canCancel)
                    .accessibilityIdentifier("cancel")
                Text("Soughtbot follows the paired phone nearby and stops about 1 m away. Keep it in sight; this does not navigate between rooms or search for a person.")
                    .font(.footnote)
                if !model.uwbSupported {
                    Text("This device does not currently support both precise nearby distance and direction. Phone following is unavailable.")
                        .font(.footnote).foregroundStyle(.red)
                }
            }
            .padding(24)
        }
        .onDisappear { model.shutdown() }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { model.shutdown() }
        }
    }

    private var statusText: String {
        switch model.phase {
        case .idle: return "Enter the matching code to pair."
        case .searching: return "Looking for the robot phone with the matching code."
        case .connected: return "Paired with \(model.peerName ?? "Soughtbot"). Waiting for nearby readiness."
        case .requested: return "Request sent, waiting for Soughtbot."
        case .approaching: return "Soughtbot is coming to this phone."
        case .arrived: return "Soughtbot has arrived near this phone."
        case .stopping: return "Stop requested. Waiting for the robot to confirm; retry Stop if needed."
        case let .failed(reason), let .lostContact(reason): return reason
        }
    }
}
