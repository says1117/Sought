import SwiftUI

// Original T-028 companion screen, kept as a two-phone UWB test under Settings > For testing.
struct ComeToMeTestView: View {
    @StateObject private var model = CompanionModel()
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 24) {
            HStack { Spacer(); Button("Done") { model.cancel(); dismiss() }.font(.headline) }
            Text(statusText).font(.headline).multilineTextAlignment(.center).accessibilityIdentifier("status")
            Text(distanceText).font(.system(size: 48, weight: .semibold, design: .rounded)).monospacedDigit()
                .accessibilityIdentifier("distance")
            Spacer()
            Button(action: model.comeToMe) {
                Text("Come to me").font(.title.bold()).frame(maxWidth: .infinity, minHeight: 120)
            }
            .buttonStyle(.borderedProminent).disabled(!model.canRequest).accessibilityIdentifier("comeToMe")
            Button("Cancel", role: .cancel, action: model.cancel)
                .font(.title3).frame(maxWidth: .infinity, minHeight: 56)
                .buttonStyle(.bordered).disabled(!model.canCancel).accessibilityIdentifier("cancel")
            if !model.uwbSupported {
                Text("This iPhone has no Ultra Wideband chip: distance and direction are unavailable.")
                    .font(.footnote).foregroundStyle(.red)
            }
        }
        .padding(24)
        .onAppear { model.start() }
    }

    private var statusText: String {
        switch model.phase {
        case .searching: return "Looking for Soughtbot"
        case .connected: return "Connected to \(model.peerName ?? "Soughtbot")"
        case .requested: return "Request sent, waiting for Soughtbot"
        case .approaching: return "Soughtbot is coming"
        case .arrived: return "Soughtbot has arrived"
        case let .failed(r): return "Stopped: \(r)"
        }
    }
    private var distanceText: String { model.distanceM.map { String(format: "%.1f m", $0) } ?? "– m" }
}
