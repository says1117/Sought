import Foundation

// Activity log, built on the user phone from data the app already gets (plan section 5.5, redesign approved by
// Isaac 2026-10-17). Change detection and patrol are cut on the robot, so nothing here is "detected":
//   moved      an item's two newest history points are more than 0.75 m apart
//   new        an item first seen in the last 6 hours with only one sighting spot
//   found / notFound   finds started from this app (RobotSource.findLog)
//   robot      Soughtbot's own state changes seen in its check-ins (RobotSource.robotLog)
// The log says "based on what Soughtbot reported".

enum ActivityKind: Equatable {
    case moved, new, found, notFound, robot

    /// The word in the pill: "Moved · 12 min ago".
    var word: String {
        switch self {
        case .moved: "Moved"
        case .new: "New"
        case .found: "Found"
        case .notFound: "Not found"
        case .robot: "Soughtbot"
        }
    }
}

struct ActivityEvent: Identifiable, Equatable {
    var id: String
    var kind: ActivityKind
    var text: String
    var at: Date
    var objectId: String?
    var from: (x: Double, z: Double)?
    var to: (x: Double, z: Double)?

    static func == (a: ActivityEvent, b: ActivityEvent) -> Bool { a.id == b.id && a.text == b.text && a.at == b.at }
}

struct FindRecord: Equatable {
    var query: String
    var objectId: String?
    var found: Bool
    var at: Date
}

struct RobotLogEntry: Equatable {
    var text: String
    var at: Date
}

enum ActivityDeriver {
    static let minMoveM = 0.75
    static let newWindow: TimeInterval = 6 * 3600

    static func events(objects: [TrackedObject], map: MapSnapshot?, finds: [FindRecord], robotLog: [RobotLogEntry],
                       now: Date = Date()) -> [ActivityEvent] {
        var out: [ActivityEvent] = []
        for o in objects {
            let h = o.history.sorted { $0.t < $1.t }
            if h.count >= 2 {
                let prev = h[h.count - 2], last = h[h.count - 1]
                if hypot(last.x - prev.x, last.z - prev.z) > minMoveM {
                    out.append(ActivityEvent(id: "move-\(o.id)-\(last.t.timeIntervalSince1970)", kind: .moved,
                                             text: "\(o.label.capitalizedFirst) moved \(place(x: last.x, z: last.z, object: o, map: map))",
                                             at: last.t, objectId: o.id, from: (prev.x, prev.z), to: (last.x, last.z)))
                }
            } else if now.timeIntervalSince(o.firstSeen) < newWindow {
                let room = map?.room(atX: o.x, z: o.z)?.name.lowercased() ?? o.room?.lowercased()
                out.append(ActivityEvent(id: "new-\(o.id)", kind: .new,
                                         text: "Soughtbot noticed \(article(o.label)) \(o.label.lowercased())" + (room.map { " in the \($0)" } ?? ""),
                                         at: o.firstSeen, objectId: o.id, to: (o.x, o.z)))
            }
        }
        for f in finds {
            let label = (f.objectId.flatMap { id in objects.first { $0.id == id }?.label } ?? f.query).lowercased()
            out.append(ActivityEvent(id: "find-\(f.at.timeIntervalSince1970)", kind: f.found ? .found : .notFound,
                                     text: f.found ? "Found your \(label)" : "Couldn\u{2019}t find your \(label)",
                                     at: f.at, objectId: f.objectId))
        }
        for r in robotLog {
            out.append(ActivityEvent(id: "bot-\(r.at.timeIntervalSince1970)", kind: .robot, text: r.text, at: r.at))
        }
        return out.sorted { $0.at > $1.at }
    }

    /// "to the front door" from the nearest waypoint, else the room, else the object's where text.
    static func place(x: Double, z: Double, object: TrackedObject, map: MapSnapshot?) -> String {
        if let w = near(x, z, map) { return "to the \(w.name)" }
        if let r = map?.room(atX: x, z: z) { return "to the \(r.name.lowercased())" }
        return object.whereText.lowercased()
    }

    /// "At the front door" / "In the living room", for history lists.
    static func location(x: Double, z: Double, object: TrackedObject, map: MapSnapshot?) -> String {
        if let w = near(x, z, map) { return "At the \(w.name)" }
        if let r = map?.room(atX: x, z: z) { return "In the \(r.name.lowercased())" }
        return object.whereText
    }

    private static func near(_ x: Double, _ z: Double, _ map: MapSnapshot?) -> Waypoint? {
        guard let w = map?.nearestWaypoint(x: x, z: z), hypot(w.x - x, w.z - z) < 1.5 else { return nil }
        return w
    }

    private static func article(_ word: String) -> String {
        guard let c = word.lowercased().first else { return "a" }
        return "aeiou".contains(c) ? "an" : "a"
    }
}

extension String {
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}
