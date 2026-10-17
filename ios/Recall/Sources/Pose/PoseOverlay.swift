import SwiftUI

/// Small debug HUD: tracking state, mapping status, pose, floor height, publish rate.
struct PoseOverlay: View {
    @ObservedObject var tracker: PoseTracker

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("tracking: \(tracker.tracking.rawValue)\(tracker.trackingReason.isEmpty ? "" : " (\(tracker.trackingReason))")")
                .foregroundStyle(color)
            Text("mapping: \(tracker.mapping.rawValue)")
            if let p = tracker.pose {
                Text(String(format: "x %.2f  z %.2f  yaw %.1f°", p.x, p.z, p.yawDeg))
            } else {
                Text("pose: --")
            }
            Text(tracker.floorY.map { String(format: "floor_y %.2f", $0) } ?? "floor_y: --")
            Text(String(format: "%.0f Hz", tracker.publishedHz))
        }
        .font(.system(.caption, design: .monospaced))
        .padding(8)
        .background(.black.opacity(0.65), in: RoundedRectangle(cornerRadius: 8))
        .foregroundStyle(.white)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Pose debug")
    }

    private var color: Color {
        switch tracker.tracking {
        case .normal: return .green
        case .limited: return .yellow
        case .notAvailable: return .red
        }
    }
}
