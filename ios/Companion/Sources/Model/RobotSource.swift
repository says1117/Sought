import Foundation
import SwiftUI

// Every screen reads from one RobotSource. Swapping mock for real data is one line in SoughtApp.
// Subclasses: MockRobotSource (default, SAMPLE DATA), BackendRobotSource (REST, after T-071 lands).
// A base class rather than a protocol so views can hold it as one @EnvironmentObject type.

@MainActor
class RobotSource: ObservableObject {
    @Published var status = RobotStatus(state: .idle, task: nil, battery: nil, pose: nil, lastHeartbeat: nil) {
        didSet { logStatusChange(from: oldValue, to: status) }
    }
    @Published var objects: [TrackedObject] = []
    @Published var map: MapSnapshot?
    @Published var liveFrame: UIImage?          // nil when no live frames (fallback: latest thumbnail)
    @Published var come: ComeProgress?
    @Published var find: FindProgress? {
        didSet { logFindResult(from: oldValue, to: find) }
    }
    /// Finds started from this app and how they ended (Activity log).
    @Published var findLog: [FindRecord] = []
    /// Soughtbot's own notable state changes seen in its check-ins (Activity log).
    @Published var robotLog: [RobotLogEntry] = []
    /// Pins the person left (saved on this iPhone, shared by every data source).
    @Published var pins: [UserPin] = PinStore.load()
    /// True until the first data arrives. Screens show shimmering placeholders, not an empty state.
    @Published var isLoading = false
    /// Ticks so "N min ago" and the offline check refresh without new data.
    @Published var now = Date()

    /// True when anything shown is sample data. Drives the SAMPLE DATA banner.
    var isSample: Bool { true }
    /// Badge words. "SAMPLE ITEMS" when the status is live but the catalog is still sample data.
    var sampleLabel: String { "Sample" }
    var sampleSpoken: String { "Sample data. This is not from the robot." }
    var sourceName: String { "Sample data" }
    /// Whether Call Soughtbot can reach the robot in this build.
    var canComeToMe: Bool { false }

    private var clock: Timer?

    init() {
        clock = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.now = Date() }
        }
    }

    var showsSamplePlanWithLivePose: Bool { false }

    // Commands. Subclasses override.
    func start() {}
    /// Stop timers and network loops (called when Settings switches the data source).
    func stop() { clock?.invalidate() }
    func startFind(_ query: String, match: TrackedObject?) {}
    func cancelFind() { if var f = find { f.phase = .cancelled; find = f } }
    func clearFind() { find = nil }
    func comeToMe(to target: ComeTarget) {}
    func cancelComeToMe() { if var c = come { c.phase = .cancelled; come = c } }

    // MARK: Derived

    var events: [ActivityEvent] {
        ActivityDeriver.events(objects: objects, map: map, finds: findLog, robotLog: robotLog, now: now)
    }

    private func logFindResult(from old: FindProgress?, to new: FindProgress?) {
        guard let new, old?.phase != new.phase else { return }
        switch new.phase {
        case .arrived: findLog.append(FindRecord(query: new.query, objectId: new.match?.id, found: true, at: Date()))
        case .notFound, .failed: findLog.append(FindRecord(query: new.query, objectId: new.match?.id, found: false, at: Date()))
        default: break
        }
    }

    private func logStatusChange(from old: RobotStatus, to new: RobotStatus) {
        if old.state != new.state {
            let place = currentRoom.map { " in the \($0.lowercased())" } ?? ""
            switch new.state {
            case .blocked: robotLog.append(RobotLogEntry(text: "Soughtbot got stuck\(place)", at: Date()))
            case .error: robotLog.append(RobotLogEntry(text: "Soughtbot needed help\(place)", at: Date()))
            default: break
            }
            if old.state == .comingToUser && new.state == .idle {
                robotLog.append(RobotLogEntry(text: "Soughtbot came to you", at: Date()))
            }
        }
        if let a = old.battery, let b = new.battery, a >= 0.2, b < 0.2 {
            robotLog.append(RobotLogEntry(text: "Soughtbot\u{2019}s battery is low (\(Int(b * 100))%)", at: Date()))
        }
    }

    /// Everything the person can look for: Soughtbot's sightings plus their own pins.
    var items: [TrackedObject] { objects + pins.map(\.asItem) }

    /// Soughtbot's sightings only (pins are not "finds").
    var recentFinds: [TrackedObject] { objects.sorted { $0.lastSeen > $1.lastSeen } }
    var essentials: [TrackedObject] { objects.filter(\.isEssential).sorted { $0.lastSeen > $1.lastSeen } }
    var frequentlySought: [TrackedObject] { objects.filter { $0.timesSought > 0 }.sorted { $0.timesSought > $1.timesSought } }
    var pinnedItems: [TrackedObject] { pins.sorted { $0.createdAt > $1.createdAt }.map(\.asItem) }

    func addPin(_ pin: UserPin) { pins.append(pin); PinStore.save(pins) }
    func removePin(id: String) { pins.removeAll { $0.id == id }; PinStore.save(pins) }

    /// Rooms in a stable order with their objects, for the Item Log.
    var byRoom: [(room: String, items: [TrackedObject])] {
        let grouped = Dictionary(grouping: items.filter { $0.room != nil }, by: { $0.room! })
        return grouped.keys.sorted().map { ($0, grouped[$0]!.sorted { $0.lastSeen > $1.lastSeen }) }
    }

    /// Room the robot is in now, for the map widget label.
    /// Nil when the floor plan is sample data but the robot's position is live: naming a sample room would be a claim.
    var currentRoom: String? {
        if showsSamplePlanWithLivePose { return nil }
        guard let p = status.pose, let m = map else { return nil }
        return m.room(atX: p.x, z: p.z)?.name ?? m.nearestWaypoint(x: p.x, z: p.z)?.name.capitalized
    }

    /// Best object for a typed or spoken query. Plain word overlap; the robot runs its own retrieval.
    func bestMatch(for query: String) -> TrackedObject? {
        let stop: Set<String> = ["my", "the", "a", "an", "find", "where", "is", "are", "where's"]
        let words = Self.words(query).subtracting(stop)
        guard !words.isEmpty else { return nil }
        var best: (TrackedObject, Int)?
        for o in items {
            let hay = Self.words(o.label + " " + (o.description ?? ""))
            let s = words.filter { w in hay.contains { h in Self.close(h, w) } }.count
            guard s > 0 else { continue }
            if let b = best, b.1 > s || (b.1 == s && b.0.lastSeen >= o.lastSeen) { continue }
            best = (o, s)
        }
        return best?.0
    }

    private static func words(_ s: String) -> Set<String> {
        Set(s.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init))
    }

    /// "slipper" matches "slippers", "umbrella" matches "umbrellas".
    private static func close(_ a: String, _ b: String) -> Bool {
        if a == b { return true }
        guard min(a.count, b.count) > 2 else { return false }
        return a.hasPrefix(b) || b.hasPrefix(a)
    }
}
