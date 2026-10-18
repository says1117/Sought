import SwiftUI
import Combine

extension DriveLink: TeachDriving {}

/// Teach fallback screen: hold-to-drive, mark named waypoints, save the world map.
/// Reachable from the "Fallback tools" menu (see `FallbackToolsMenu`).
struct TeachView: View {
    @ObservedObject var model: TeachViewModel
    @ObservedObject var link: DriveLink
    @ObservedObject var tracker: PoseTracker
    /// The app's frame gate state (`AppRuntime.relocalizationState`): one source of truth with Memory.
    let relocState: () -> RelocalizationState
    let hasSavedMap: Bool
    @State private var reloc: RelocalizationState = .idle
    @GestureState private var held: DriveIntent?
    @State private var requireRelease = false
    @Environment(\.scenePhase) private var scenePhase
    private let ticker = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                relocBanner
                Text(link.statusText).font(.headline)
                Slider(value: Binding(get: { model.speed }, set: { model.setSpeed($0) }), in: 60...200, step: 10) { Text("Speed") }
                Text("Speed \(Int(model.speed))").font(.caption)
                HoldButton(title: "Forward", intent: .forward, held: $held)
                HStack(spacing: 20) {
                    HoldButton(title: "Left", intent: .left, held: $held)
                    HoldButton(title: "Right", intent: .right, held: $held)
                }
                HoldButton(title: "Back", intent: .back, held: $held)

                HStack {
                    TextField("Waypoint name", text: $model.nameDraft).textFieldStyle(.roundedBorder)
                    Button("Mark waypoint") { model.markWaypoint() }.buttonStyle(.borderedProminent)
                }
                Button(model.isSaving ? "Saving map" : "Save map") { model.saveMap() }
                    .buttonStyle(.bordered).disabled(model.isSaving)
                Text(arReadout)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(WorldMapSavePolicy.canSave(tracking: tracker.tracking, mapping: tracker.mapping) ? .green : .orange)
                if let warning = model.storageWarning { Text(warning).font(.footnote).foregroundStyle(.orange) }
                if !model.message.isEmpty { Text(model.message).font(.footnote) }

                ForEach(model.waypoints, id: \.id) { w in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(w.name).font(.body)
                            Text(String(format: "x %.2f  z %.2f  yaw %.0f", w.x, w.z, w.yawDeg))
                                .font(.system(.caption, design: .monospaced))
                        }
                        Spacer()
                        if w.id != WaypointStore.homeId {
                            Button("Delete", role: .destructive) { model.delete(w) }.buttonStyle(.bordered)
                        }
                    }
                }
            }
            .padding()
        }
        .allowsHitTesting(scenePhase == .active)
        .onChange(of: held) { _, intent in
            if intent == nil { requireRelease = false }
            model.setHeld(intent, enabled: !requireRelease && scenePhase == .active)
        }
        .onChange(of: link.isConnected) { _, _ in
            requireRelease = held != nil
            model.stopDriving()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { requireRelease = held != nil; model.stopDriving() }
        }
        .onChange(of: tracker.tracking) { _, _ in reloc = relocState() }
        .onChange(of: model.isSaving) { _, _ in reloc = relocState() }
        .onReceive(ticker) { _ in reloc = relocState() }
        .onAppear {
            model.beginSession(hasSavedMap: hasSavedMap)
            reloc = relocState()
        }
        .onDisappear { model.stopDriving() }
    }

    /// Live ARKit state next to Save map: saving needs normal tracking and a mapped or extending status.
    private var arReadout: String {
        let reason = tracker.trackingReason.isEmpty ? "" : " (\(tracker.trackingReason))"
        return "Tracking \(tracker.tracking.rawValue)\(reason) · map \(tracker.mapping.rawValue)"
    }

    @ViewBuilder private var relocBanner: some View {
        switch reloc {
        case .relocalized:
            Text("Room recognised: memory is on").font(.callout).foregroundStyle(.green)
        case .idle:
            Text("No room map in use: look around, then Save map to turn memory on").font(.callout).foregroundStyle(.orange)
        case .waiting(let t):
            VStack(spacing: 6) {
                Text("Relocalizing: look around the room (\(Int(t)) s)").font(.callout).foregroundStyle(.orange)
                // Saving needs normal tracking, which never comes while ARKit is still looking for the old map.
                Text("Room changed or never recognised? Start fresh, scan, then Save map.").font(.caption)
                freshTeachButton.buttonStyle(.bordered)
            }
        case .rescanNeeded:
            VStack(spacing: 6) {
                Text("Rescan needed").font(.headline).foregroundStyle(.red)
                freshTeachButton.buttonStyle(.borderedProminent)
            }
        }
    }

    /// New ARKit run without the saved map. The gate goes to a fresh id; Save map then adopts this session.
    private var freshTeachButton: some View {
        Button("Start fresh Teach") {
            tracker.start(resetTracking: true)
            reloc = relocState()
        }
    }
}

/// Menu for the root screen's toolbar. The find-bar root screen owns where it is placed;
/// it only needs to present `TeachView` from the menu item.
struct FallbackToolsMenu: View {
    let onTeach: () -> Void
    var body: some View {
        Menu("Fallback tools") {
            Button("Teach (manual drive)", action: onTeach)
        }
    }
}

/// Owns the Teach objects for one presentation of the screen. Present it from the root screen's
/// "Fallback tools" menu: `.sheet(isPresented:) { TeachContainer(link: link, tracker: pose, runtime: runtime) }`.
struct TeachContainer: View {
    @StateObject private var session: TeachSession
    @ObservedObject var link: DriveLink
    @ObservedObject var tracker: PoseTracker
    let runtime: AppRuntime

    init(link: DriveLink, tracker: PoseTracker, runtime: AppRuntime) {
        self.link = link
        self.tracker = tracker
        self.runtime = runtime
        _session = StateObject(wrappedValue: TeachSession(link: link, tracker: tracker, runtime: runtime))
    }

    var body: some View {
        TeachView(model: session.model, link: link, tracker: tracker, relocState: { [runtime] in runtime.relocalizationState() },
                  hasSavedMap: session.adapter.hasSavedMap)
    }
}

final class TeachSession: ObservableObject {
    let adapter: ARWorldMapAdapter
    let model: TeachViewModel

    init(link: DriveLink, tracker: PoseTracker, runtime: AppRuntime) {
        let dir = WorldMapStore.defaultURL().deletingLastPathComponent()
        let store: WaypointStore
        let storageWarning: String?
        do {
            store = try WaypointStore(path: dir.appendingPathComponent("recall.sqlite").path)
            storageWarning = nil
        } catch {
            store = try! WaypointStore(path: ":memory:")
            storageWarning = "Waypoint storage unavailable. New waypoints are temporary and will be lost when Teach closes."
        }
        adapter = ARWorldMapAdapter(tracker: tracker)
        // Both run on the main queue: saveMap is a button action and the adapter calls back on main.
        adapter.currentGeneration = { [weak runtime] in MainActor.assumeIsolated { runtime?.frameGeneration ?? -1 } }
        adapter.onSaved = { [weak runtime] id, generation in
            MainActor.assumeIsolated { runtime?.mapSaved(mapId: id, generation: generation) }
        }
        model = TeachViewModel(store: store, driver: link, mapSaver: adapter, currentPose: { tracker.pose }, storageWarning: storageWarning)
    }
}
