import SwiftUI

// Self-test screen: human checklist, big START, always-visible STOP, per-step pass/fail with a live reading, share-sheet export.
// NOT compiled or run by the author (no Xcode).

struct SelfTestView: View {
    @ObservedObject var runner: SelfTestRunner
    @Environment(\.scenePhase) private var scenePhase

    @State private var checks = Array(repeating: false, count: SelfTestView.checklist.count)
    @State private var fwdTape = ""
    @State private var squareTape = ""

    static let checklist = [
        "Rover wheels are OFF the ground (on a stand) for steps 0 and 1",
        "Battery switch is ON and the ESP32 shows connected below",
        "A person stays next to the rover for the whole run",
        "I can reach the red STOP button, and the power switch, at any time",
        "For the floor steps: 3 m x 3 m of clear floor and a soft box ready",
        "Phone is mounted, charged and screen stays on",
    ]

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text("Motion self-test").font(.title2.bold())
                    Text("Thresholds are placeholders, to be calibrated by Steven, not measured. This screen reports only what it measures.")
                        .font(.footnote).foregroundStyle(.secondary)
                    if runner.state == .idle || runner.state.isTerminal { idleSection } else { runningSection }
                    stepList
                    if runner.trackingIncidents > 0 || runner.bleDisconnects > 0 || runner.state != .idle {
                        Text("Incidents so far: tracking \(runner.trackingIncidents), BLE disconnects \(runner.bleDisconnects)")
                            .font(.system(.footnote, design: .monospaced))
                    }
                    if runner.state.isTerminal { finishedSection }
                }
                .padding()
            }
            stopBar
        }
        .onChange(of: scenePhase) { _, p in if p != .active { runner.stop() } }
        .onDisappear { runner.stop() }
    }

    private var idleSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Human checklist").font(.headline)
            ForEach(Array(Self.checklist.enumerated()), id: \.offset) { i, text in
                Toggle(text, isOn: $checks[i]).font(.subheadline)
            }
            Button {
                runner.start(checklistConfirmed: checks.allSatisfy { $0 })
            } label: {
                Text("START").font(.title.bold()).frame(maxWidth: .infinity, minHeight: 64)
            }
            .buttonStyle(.borderedProminent)
            .disabled(!checks.allSatisfy { $0 })
            .accessibilityLabel("Start self-test")
        }
    }

    private var runningSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let c = runner.current { Text(c.title).font(.headline) }
            Text(runner.live.isEmpty ? " " : runner.live).font(.system(.footnote, design: .monospaced))
            if let p = runner.prompt {
                Text(p).padding().background(Color.yellow.opacity(0.25)).cornerRadius(10)
                Button { runner.confirm() } label: {
                    Text("Continue").font(.title3.bold()).frame(maxWidth: .infinity, minHeight: 52)
                }.buttonStyle(.borderedProminent)
            }
        }
    }

    private var stepList: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(SelfTestStepID.allCases, id: \.rawValue) { id in
                let r = runner.results.first { $0.id == id }
                HStack(alignment: .top) {
                    Image(systemName: r == nil ? (runner.current == id ? "circle.dotted" : "circle")
                          : (r!.pass ? "checkmark.circle.fill" : "xmark.octagon.fill"))
                        .foregroundStyle(r == nil ? Color.secondary : (r!.pass ? Color.green : Color.red))
                    VStack(alignment: .leading) {
                        Text(id.title).font(.subheadline)
                        if let r { Text(r.reason).font(.caption).foregroundStyle(r.pass ? Color.secondary : Color.red) }
                    }
                }
            }
        }
    }

    private var finishedSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(stateText).font(.headline)
            Text("Optional: tape-measured distance of the rover from its start mark, in cm (the human truth, not ARKit)")
                .font(.footnote)
            HStack {
                TextField("after step 2", text: $fwdTape).keyboardType(.decimalPad).textFieldStyle(.roundedBorder)
                Button("Log") { if let v = Double(fwdTape) { runner.recordManual(step: .forwardBack, key: "return_error_m", value: v / 100) } }
            }
            HStack {
                TextField("after step 3", text: $squareTape).keyboardType(.decimalPad).textFieldStyle(.roundedBorder)
                Button("Log") { if let v = Double(squareTape) { runner.recordManual(step: .square, key: "final_error_m", value: v / 100) } }
            }
            if let url = runner.exportURL {
                ShareLink(item: url) { Label("Export log (JSONL)", systemImage: "square.and.arrow.up") }
                Text("Then run: python3 tools/motion_report.py <file>").font(.caption)
            }
        }
    }

    private var stateText: String {
        switch runner.state {
        case .finished: return "Run finished"
        case .halted(let why): return "Run halted: \(why)"
        case .aborted(let r): return "Run aborted: \(r.rawValue). Motors were stopped."
        default: return ""
        }
    }

    /// Always on screen, whatever the run is doing.
    private var stopBar: some View {
        Button { runner.stop() } label: {
            Text("STOP").font(.system(size: 34, weight: .heavy)).foregroundColor(.white)
                .frame(maxWidth: .infinity, minHeight: 72).background(Color.red)
        }
        .accessibilityLabel("Stop the rover now")
    }
}

/// Owns the runner so callers only pass the shared DriveLink and PoseTracker.
struct SelfTestContainer: View {
    @StateObject private var runner: SelfTestRunner
    init(link: DriveLink, tracker: PoseTracker) {
        _runner = StateObject(wrappedValue: SelfTestRunner(link: link, tracker: tracker))
    }
    var body: some View { SelfTestView(runner: runner) }
}
