import SwiftUI

/// Robot-mode header for the phone on the rover ("Sought Robot"): what it is doing, whether it knows the room,
/// and whether the Sought app can reach it. Read-only; the find bar and the setup tools stay below and in the menu.
struct RobotStatusCard: View {
    @ObservedObject var runtime: AppRuntime

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Sought Robot").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            Text(doing).font(.title.bold()).lineLimit(2).minimumScaleFactor(0.6)
            Label(runtime.perceptionNote, systemImage: roomOK ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(roomOK ? .green : .orange)
            Label(runtime.remoteLinked ? "Listening for the Sought app" : "Sought app link off (no backend configured)",
                  systemImage: runtime.remoteLinked ? "antenna.radiowaves.left.and.right" : "antenna.radiowaves.left.and.right.slash")
                .foregroundStyle(runtime.remoteLinked ? .green : .secondary)
        }
        .font(.callout)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16))
        .accessibilityElement(children: .combine)
    }

    private var roomOK: Bool { runtime.perceptionNote.hasPrefix("Memory fills") }

    private var doing: String {
        let s = runtime.coordinatorStatus
        if let task = s.task {
            if task.hasPrefix("find: ") { return "Finding \(task.dropFirst(6))…" }
            return task.prefix(1).uppercased() + task.dropFirst() + "…"
        }
        switch s.state.heartbeatValue {
        case "idle": return "Ready"
        default: return s.state.heartbeatValue.capitalized
        }
    }
}
