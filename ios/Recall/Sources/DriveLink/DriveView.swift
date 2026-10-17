import SwiftUI

/// Hold-to-drive pad. Drives while a button is held, stops on release.
struct DriveView: View {
    @ObservedObject var link: DriveLink
    @State private var speed = 150.0

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

            let s = Int(speed)
            HoldButton(title: "Forward", onPress: { link.drive(left: s, right: s) }, onRelease: link.stop)
            HStack(spacing: 20) {
                HoldButton(title: "Left", onPress: { link.drive(left: -s, right: s) }, onRelease: link.stop)
                HoldButton(title: "Right", onPress: { link.drive(left: s, right: -s) }, onRelease: link.stop)
            }
            HoldButton(title: "Back", onPress: { link.drive(left: -s, right: -s) }, onRelease: link.stop)
        }
        .padding()
    }
}

struct HoldButton: View {
    let title: String
    let onPress: () -> Void
    let onRelease: () -> Void
    @State private var down = false

    var body: some View {
        Text(title)
            .frame(width: 120, height: 60)
            .background(down ? Color.blue : Color.gray.opacity(0.3))
            .foregroundColor(down ? .white : .primary)
            .cornerRadius(12)
            .accessibilityLabel("Drive \(title)")
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { _ in if !down { down = true; onPress() } }
                .onEnded { _ in down = false; onRelease() })
    }
}
