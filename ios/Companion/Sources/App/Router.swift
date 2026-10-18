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

    /// Screenshot and UI test hooks: launch with `-tab items`, `-search "red umbrella"` or `-detail obj_sample0007`.
    func applyLaunchArguments(robot: RobotSource) {
        let d = UserDefaults.standard
        if let t = d.string(forKey: "tab"), let tab = AppTab(rawValue: t) { self.tab = tab }
        if let q = d.string(forKey: "search") { search(q, in: robot) }
        if let id = d.string(forKey: "detail"), let o = robot.objects.first(where: { $0.id == id }) { detail = o }
    }

    func find(_ o: TrackedObject) {
        detail = nil
        findRequest = FindRequest(query: o.label, match: o, confirmed: true)
    }

    func search(_ query: String, in robot: RobotSource) {
        findRequest = FindRequest(query: query, match: robot.bestMatch(for: query), confirmed: false)
    }

    func open(_ o: TrackedObject) { detail = o }
}
