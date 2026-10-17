import SwiftUI

struct ContentView: View {
    @ObservedObject var model: CompanionModel

    var body: some View {
        VStack(spacing: 24) {
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
    }

    private var statusText: String {
        switch model.phase {
        case .searching: return "Looking for the robot…"
        case .connected: return "Connected to \(model.peerName ?? "robot")"
        case .requested: return "Request sent, waiting for the robot"
        case .approaching: return "Robot is coming"
        case .arrived: return "Robot has arrived"
        case let .failed(r): return "Stopped: \(r)"
        }
    }
    private var distanceText: String { model.distanceM.map { String(format: "%.1f m", $0) } ?? "– m" }
}
