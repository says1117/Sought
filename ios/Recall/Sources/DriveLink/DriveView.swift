import SwiftUI

/// Hold-to-drive pad. Drives while a button is held; release or a cancelled touch stops.
struct DriveView: View {
    @ObservedObject var link: DriveLink
    @State private var speed = 150.0
    @Environment(\.scenePhase) private var scenePhase
    /// Resets to nil on release AND on cancellation (call, system gesture), unlike DragGesture.onEnded.
    @GestureState private var held: DriveIntent?
    @State private var requireRelease = false

    var body: some View {
        VStack(spacing: 16) {
            Text(link.statusText).font(.headline)
            if let r = link.robot {
                Text("L \(r.left) R \(r.right)  front \(r.frontDistanceCm.map(String.init) ?? "-") cm  rear \(r.rearDistanceCm.map(String.init) ?? "-") cm")
                    .font(.system(.footnote, design: .monospaced))
                if r.flags.contains(.watchdogStopped) { Text("Watchdog stopped").foregroundStyle(.red) }
                if r.flags.contains(.frontBlocked) { Text("Front blocked").foregroundStyle(.orange) }
                if r.flags.contains(.rearBlocked) { Text("Rear blocked").foregroundStyle(.orange) }
            }
            Slider(value: $speed, in: 60...200, step: 10) { Text("Speed") }
            Text("Speed \(Int(speed))").font(.caption)

            HoldButton(title: "Forward", intent: .forward, held: $held)
            HStack(spacing: 20) {
                HoldButton(title: "Left", intent: .left, held: $held)
                HoldButton(title: "Right", intent: .right, held: $held)
            }
            HoldButton(title: "Back", intent: .back, held: $held)
        }
        .padding()
        .allowsHitTesting(link.isConnected && scenePhase == .active)
        .onChange(of: held) { _, intent in
            if intent == nil { requireRelease = false }
            apply()
        }
        .onChange(of: speed) { _, _ in apply() }
        .onChange(of: link.isConnected) { _, _ in
            requireRelease = held != nil
            link.stop()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { requireRelease = held != nil; link.stop() }
        }
        .onDisappear { link.stop() }
    }

    private func apply() {
        switch DrivePad.action(held: held, speed: Int(speed),
                               isEnabled: link.isConnected && scenePhase == .active && !requireRelease) {
        case .stop: link.stop()
        case .drive(let l, let r): link.drive(left: l, right: r)
        }
    }
}

struct HoldButton: View {
    let title: String
    let intent: DriveIntent
    let held: GestureState<DriveIntent?>

    var body: some View {
        let down = held.wrappedValue == intent
        Text(title)
            .frame(width: 120, height: 60)
            .background(down ? Color.blue : Color.gray.opacity(0.3))
            .foregroundColor(down ? .white : .primary)
            .cornerRadius(12)
            .accessibilityLabel("Drive \(title)")
            .gesture(DragGesture(minimumDistance: 0)
                .updating(held) { _, state, _ in state = intent })
    }
}
