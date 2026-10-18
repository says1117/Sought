import Foundation
import SwiftUI

// Every screen reads from one RobotSource. Swapping mock for real data is one line in SoughtApp.
// Subclasses: MockRobotSource (default, SAMPLE DATA), BackendRobotSource (REST, after T-071 lands).
// A base class rather than a protocol so views can hold it as one @EnvironmentObject type.

@MainActor
class RobotSource: ObservableObject {
    @Published var status = RobotStatus(state: .idle, task: nil, battery: nil, pose: nil, lastHeartbeat: nil)
    @Published var objects: [TrackedObject] = []
    @Published var map: MapSnapshot?
    @Published var liveFrame: UIImage?          // nil when no live frames (fallback: latest thumbnail)
    @Published var find: FindProgress?
    /// True until the first data arrives. Screens show shimmering placeholders, not an empty state.
    @Published var isLoading = false
    /// Ticks so "N min ago" and the offline check refresh without new data.
    @Published var now = Date()

    /// True when anything shown is sample data. Drives the SAMPLE DATA banner.
    var isSample: Bool { true }
    var sourceName: String { "Sample data" }
    /// Whether Call Soughtbot can reach the robot in this build.
    var canComeToMe: Bool { false }

    private var clock: Timer?

    init() {
        clock = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.now = Date() }
        }
    }

    // Commands. Subclasses override.
    func start() {}
    func startFind(_ query: String, match: TrackedObject?) {}
    func cancelFind() { if var f = find { f.phase = .cancelled; find = f } }
    func clearFind() { find = nil }
    func comeToMe() {}

    // MARK: Derived

    var activity: [ActivityItem] { ActivityDeriver.items(objects: objects, map: map) }

    var recentFinds: [TrackedObject] { objects.sorted { $0.lastSeen > $1.lastSeen } }
    var essentials: [TrackedObject] { objects.filter(\.isEssential).sorted { $0.lastSeen > $1.lastSeen } }
    var frequentlySought: [TrackedObject] { objects.filter { $0.timesSought > 0 }.sorted { $0.timesSought > $1.timesSought } }

    /// Rooms in a stable order with their objects, for the Item Log.
    var byRoom: [(room: String, items: [TrackedObject])] {
        let grouped = Dictionary(grouping: objects.filter { $0.room != nil }, by: { $0.room! })
        return grouped.keys.sorted().map { ($0, grouped[$0]!.sorted { $0.lastSeen > $1.lastSeen }) }
    }

    /// Room the robot is in now, for the map widget label.
    var currentRoom: String? {
        guard let p = status.pose, let m = map else { return nil }
        return m.room(atX: p.x, z: p.z)?.name ?? m.nearestWaypoint(x: p.x, z: p.z)?.name.capitalized
    }

    /// Best object for a typed or spoken query. Plain word overlap; the robot runs its own retrieval.
    func bestMatch(for query: String) -> TrackedObject? {
        let stop: Set<String> = ["my", "the", "a", "an", "find", "where", "is", "are", "where's"]
        let words = Self.words(query).subtracting(stop)
        guard !words.isEmpty else { return nil }
        var best: (TrackedObject, Int)?
        for o in objects {
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
