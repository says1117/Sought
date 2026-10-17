import SwiftUI

extension DriveLink: TeachDriving {}

/// Teach fallback screen: hold-to-drive, mark named waypoints, save the world map.
/// Reachable from the "Fallback tools" menu (see `FallbackToolsMenu`).
struct TeachView: View {
    @ObservedObject var model: TeachViewModel
    @ObservedObject var link: DriveLink
    @ObservedObject var tracker: PoseTracker
    let monitor: RelocalizationMonitor
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
        .onChange(of: tracker.tracking) { _, _ in reloc = monitor.update(tracking: tracker.tracking, mapping: tracker.mapping) }
        .onChange(of: tracker.mapping) { _, _ in reloc = monitor.update(tracking: tracker.tracking, mapping: tracker.mapping) }
        .onReceive(ticker) { _ in reloc = monitor.tick() }
        .onAppear { model.beginSession() }
        .onDisappear { model.stopDriving() }
    }

    @ViewBuilder private var relocBanner: some View {
        switch reloc {
        case .idle, .relocalized: EmptyView()
        case .waiting(let t):
            Text("Relocalizing: look around the room (\(Int(t)) s)").font(.callout).foregroundStyle(.orange)
        case .rescanNeeded:
            VStack(spacing: 6) {
                Text("Rescan needed").font(.headline).foregroundStyle(.red)
                Button("Start fresh Teach") {
                    monitor.startFreshTeach()
                    reloc = .idle
                    tracker.start(resetTracking: true)
                }.buttonStyle(.borderedProminent)
            }
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
/// "Fallback tools" menu: `.sheet(isPresented:) { TeachContainer(link: link, tracker: pose) }`.
struct TeachContainer: View {
    @StateObject private var session: TeachSession
    @ObservedObject var link: DriveLink
    @ObservedObject var tracker: PoseTracker

    init(link: DriveLink, tracker: PoseTracker) {
        self.link = link
        self.tracker = tracker
        _session = StateObject(wrappedValue: TeachSession(link: link, tracker: tracker))
    }

    var body: some View {
        TeachView(model: session.model, link: link, tracker: tracker, monitor: session.monitor)
    }
}

final class TeachSession: ObservableObject {
    let adapter: ARWorldMapAdapter
    let monitor = RelocalizationMonitor()
    let model: TeachViewModel

    init(link: DriveLink, tracker: PoseTracker) {
        let dir = WorldMapStore.defaultURL().deletingLastPathComponent()
        let store = (try? WaypointStore(path: dir.appendingPathComponent("recall.sqlite").path))
            ?? (try! WaypointStore(path: ":memory:"))
        adapter = ARWorldMapAdapter(tracker: tracker)
        model = TeachViewModel(store: store, driver: link, mapSaver: adapter, currentPose: { tracker.pose })
    }
}
