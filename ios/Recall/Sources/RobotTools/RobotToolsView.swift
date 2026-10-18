import SwiftUI

/// "Robot tools" sheet: Scan here, last find trace, memory inspector. Read-only except Scan and STOP.
struct RobotToolsView: View {
    @ObservedObject var runtime: AppRuntime
    @StateObject private var scan: ScanHereModel
    @Environment(\.scenePhase) private var scenePhase
    @State private var tab = 0
    @State private var trace = FindTraceDisplay.make(from: nil, connected: false)
    @State private var memory = MemoryInspectorDisplay.make(tracks: .success([]), now: 0, modelsInstalled: true)
    private let traceSource: FindTraceSource
    let onClose: () -> Void

    init(runtime: AppRuntime, traceSource: FindTraceSource = FindTraceRecorder.shared, onClose: @escaping () -> Void) {
        self.runtime = runtime
        self.traceSource = traceSource
        self.onClose = onClose
        _scan = StateObject(wrappedValue: ScanHereModel(
            drive: ControllerScanDrive(controller: runtime.makeScanController()), clock: ScanSystemClock(),
            poses: runtime.scanPoses, gate: runtime.makeScanGate(),
            stopAll: { Task { @MainActor in runtime.stopEverything() } }))
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker("Section", selection: $tab) {
                Text("Scan here").tag(0)
                Text("Last find").tag(1)
                Text("Memory").tag(2)
                Text("Pair phone").tag(4)
                if runtime.features.exploreEnabled { Text("Explore").tag(3) }
            }
            .pickerStyle(.segmented)
            .padding()
            ScrollView {
                switch tab {
                case 0: scanSection
                case 1: findSection
                case 3: ExplorePreviewSection(runtime: runtime)
                case 4: PairedPhoneSection(link: runtime.pairedPhone)
                default: memorySection
                }
            }
            stopBar
        }
        .navigationTitle("Robot tools")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .topBarLeading) { Button("Done") { scan.cancel(); onClose() } } }
        .onAppear(perform: refresh)
        .onChange(of: tab) { _, _ in refresh() }
        .onChange(of: scenePhase) { _, phase in if phase != .active { scan.cancel() } }   // never resumes: needs a new tap
        .onDisappear { scan.cancel() }          // leaving the screen cancels a scan and sends STOP
    }

    private func refresh() {
        trace = FindTraceDisplay.make(from: traceSource.lastTrace(), connected: traceSource.isConnected)
        let tracks = Result { try runtime.trackProvider.allTracks() }
        memory = MemoryInspectorDisplay.make(tracks: tracks, now: Date().timeIntervalSince1970,
                                             modelsInstalled: runtime.encoderSet.isAvailable,
                                             perceptionNote: runtime.perceptionNote)
    }

    // MARK: Scan

    private var scanSection: some View {
        VStack(spacing: 16) {
            Text("Turns the robot in place four times, 90 degrees each, and waits at each stop so it can look. Wheels off the ground for the first try.")
                .font(.callout).foregroundStyle(.secondary)
            Text(scan.state.stepLabel ?? "–/\(scan.total)")
                .font(.system(size: 64, weight: .bold, design: .rounded)).monospacedDigit()
                .accessibilityLabel(scan.state.stepLabel.map { "Stop \($0.replacingOccurrences(of: "/", with: " of "))" } ?? "Not scanning")
            Text(scan.state.progressText).font(.title3).multilineTextAlignment(.center)
                .accessibilityLabel(scan.state.progressText)
            Button {
                scan.start()
            } label: {
                Label("Scan here", systemImage: "arrow.triangle.2.circlepath.camera")
                    .font(.title2.bold()).frame(maxWidth: .infinity, minHeight: 64)
            }
            .buttonStyle(.borderedProminent)
            .disabled(scan.state.isRunning)
            .accessibilityHint("Turns the robot in four steps of 90 degrees, pausing to look at each")
            // Debug: what the forward obstacle guard sees. The "Scan turns" line is the TurnGuard policy.
            TimelineView(.periodic(from: .now, by: 0.25)) { _ in
                Text(runtime.guardReadout())
                    .font(.system(.footnote, design: .monospaced)).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding()
    }

    // MARK: Last find

    private var findSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let empty = trace.emptyMessage {
                Text(empty).font(.body).foregroundStyle(.secondary)
            } else {
                Text("\u{201C}\(trace.query)\u{201D}").font(.title2.bold())
                Text("\(trace.outcomeTitle) · \(trace.timeText) · \(trace.nearMissesText)").font(.headline)
                if !trace.spoken.isEmpty { Text("Said: \(trace.spoken)").font(.body) }
                if let none = trace.noCandidatesMessage { Text(none).foregroundStyle(.secondary) }
                ForEach(trace.candidates, id: \.rank) { c in candidateRow(c) }
                if !trace.notes.isEmpty { Text("Notes: \(trace.notes)").font(.footnote).foregroundStyle(.secondary) }
            }
            Button("Refresh", action: refresh).buttonStyle(.bordered)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
    }

    private func candidateRow(_ c: FindTraceDisplay.Candidate) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("#\(c.rank)  \(c.trackID)  score \(c.scoreText)").font(.headline)
            Text(c.positionText).font(.subheadline).foregroundStyle(.secondary)
            if let a = c.attempt {
                Text(a.verdictTitle).font(.headline).foregroundStyle(a.isAccept ? Color.green : Color.red)
                Text(a.scoresText).font(.subheadline).monospacedDigit()
                Text(a.reason).font(.footnote).foregroundStyle(.secondary)
            } else {
                Text("Not visited").font(.subheadline).foregroundStyle(.secondary)
            }
        }
        .padding(10).frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
        .accessibilityElement(children: .combine)
    }

    // MARK: Memory

    private var memorySection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(memory.countText).font(.title2.bold())
            ForEach(memory.notices, id: \.self) { n in
                Text(n).font(.callout).padding(10).frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.orange.opacity(0.2), in: RoundedRectangle(cornerRadius: 10))
            }
            if let e = memory.errorMessage { Text(e).foregroundStyle(.red) }
            if let e = memory.emptyMessage { Text(e).foregroundStyle(.secondary) }
            ForEach(memory.rows, id: \.id) { r in
                VStack(alignment: .leading, spacing: 2) {
                    Text(r.id).font(.headline)
                    Text("\(r.positionText) · \(r.sightingsText) · \(r.persistenceText)").font(.subheadline)
                    Text(r.lastSeenText).font(.footnote).foregroundStyle(.secondary)
                    if !r.hasThumbnail { Text("No thumbnail stored").font(.caption2).foregroundStyle(.secondary) }
                }
                .padding(10).frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
                .accessibilityElement(children: .combine)
            }
            Button("Refresh", action: refresh).buttonStyle(.bordered)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
    }

    // MARK: STOP (always visible)

    private var stopBar: some View {
        Button {
            scan.cancel()          // also brakes the coordinator and the link
        } label: {
            Text("STOP").font(.system(size: 32, weight: .heavy)).frame(maxWidth: .infinity, minHeight: 72)
        }
        .buttonStyle(.borderedProminent).tint(.red)
        .padding()
        .accessibilityLabel("Stop the robot")
    }
}

private struct PairedPhoneSection: View {
    @ObservedObject var link: PairedPhoneLink

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Come to the paired phone").font(.title2.bold())
            Text("Keep both apps open in the same room. Enter the same six-digit code on both phones.")
            SecureField("Six-digit pairing code", text: $link.code)
                .keyboardType(.numberPad).textContentType(.oneTimeCode).textFieldStyle(.roundedBorder)
                .disabled(link.pairing)
            Button("Pair phone", action: link.beginPairing).buttonStyle(.borderedProminent)
                .disabled(!link.supported || link.pairing)
            Button("Disconnect", action: link.stopPairing).buttonStyle(.bordered)
                .disabled(!link.pairing)
            Text(link.message)
            if !link.supported { Text("Distance and direction ranging are unavailable on this phone.").foregroundStyle(.secondary) }
            Text(link.distance.map { String(format: "Distance %.2f m", $0) } ?? "Distance unavailable")
            Text(link.bearing.map { String(format: "Bearing %.0f° (positive is left)", $0) } ?? "Direction unavailable")
            Text("With the wheels raised and the robot stationary, check that the bearing reads ahead, left and right correctly as you move the handheld phone. Then enable approach for this pairing session.")
                .font(.footnote)
            Toggle("Enable approach after checking bearing", isOn: $link.approachEnabled)
                .disabled(!link.connected || link.distance == nil || link.bearing == nil)
            Text("The robot approaches in short guarded segments and stops about one metre away. An obstacle can stop it; this mode does not find routes around walls.")
                .font(.footnote).foregroundStyle(.secondary)
        }
        .padding()
    }
}
