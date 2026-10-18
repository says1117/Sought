import SwiftUI

// App-wide navigation: which tab, which item sheet, and the find flow.

struct FindRequest: Identifiable, Equatable {
    let id = UUID()
    var query: String
    var match: TrackedObject?
    /// Started from a card's Find it: skip the "Looking for X?" confirm step.
    var confirmed: Bool
}

@MainActor
final class Router: ObservableObject {
    @Published var tab: AppTab = .home
    @Published var detail: TrackedObject?
    @Published var findRequest: FindRequest?
    /// Source id of the photo or search bar that opened the current sheet or find flow (zoom transition).
    @Published var heroID: String?
    /// Set by a card or search bar right before it calls find/open/search.
    var pendingHero: String?
    /// "Pin where I left them": the Map starts placing a pin with this name.
    @Published var pinDraft: String?
    /// Come to me sheet (place picker, then progress).
    @Published var showComeToMe = false

    func startPin(named name: String) {
        findRequest = nil
        detail = nil
        tab = .map
        pinDraft = name
    }

    /// Screenshot and UI test hooks: launch with `-tab items`, `-search "red umbrella"` `-detail obj_sample0007` or `-find obj_sample0007`.
    func applyLaunchArguments(robot: RobotSource) {
        let d = UserDefaults.standard
        if let t = d.string(forKey: "tab"), let tab = AppTab(rawValue: t) { self.tab = tab }
        if let q = d.string(forKey: "search") { search(q, in: robot) }
        if let id = d.string(forKey: "detail"), let o = robot.items.first(where: { $0.id == id }) { detail = o }
        if let id = d.string(forKey: "find") {
            Task { @MainActor in   // server data arrives after launch: wait up to 6 s for the item
                for _ in 0..<30 {
                    if let o = robot.items.first(where: { $0.id == id }) { self.find(o); return }
                    try? await Task.sleep(nanoseconds: 200_000_000)
                }
            }
        }
        // `-showComeToMe YES` opens the place picker; `-comeTo wpt_x` also starts going there.
        if d.bool(forKey: "showComeToMe") { showComeToMe = true }
        if let id = d.string(forKey: "comeTo"), let w = robot.map?.waypoints.first(where: { $0.id == id }) {
            robot.comeToMe(to: ComeTarget(waypointId: w.id, name: "the \(w.name)", x: w.x, z: w.z))
            showComeToMe = true
        }
        // `-demoOpen obj_x` / `-demoFind obj_x`: after Home settles, open or find from its Recent Finds card (zoom demo).
        for (key, open) in [("demoOpen", true), ("demoFind", false)] {
            guard let id = d.string(forKey: key), let o = robot.objects.first(where: { $0.id == id }) else { continue }
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 2_500_000_000)
                self.pendingHero = "home-\(id)"
                if open { self.open(o) } else { self.find(o) }
            }
        }
    }

    func find(_ o: TrackedObject) {
        detail = nil
        takeHero()
        findRequest = FindRequest(query: o.label, match: o, confirmed: true)
    }

    func search(_ query: String, in robot: RobotSource) {
        takeHero()
        findRequest = FindRequest(query: query, match: robot.bestMatch(for: query), confirmed: false)
    }

    func open(_ o: TrackedObject) { takeHero(); detail = o }

    private func takeHero() { heroID = pendingHero; pendingHero = nil }
}
