import Foundation

// Activity log, derived on the user phone (plan section 5.5). Change detection is cut on the robot, so this
// compares each object's two newest history points. A move over 0.75 m becomes "Slippers moved to the front door".
// This is "based on where items were last seen", not detection.

enum ActivityDeriver {
    static let minMoveM = 0.75

    static func items(objects: [TrackedObject], map: MapSnapshot?) -> [ActivityItem] {
        objects.compactMap { o -> ActivityItem? in
            let h = o.history.sorted { $0.t < $1.t }
            guard h.count >= 2 else { return nil }
            let prev = h[h.count - 2], last = h[h.count - 1]
            guard hypot(last.x - prev.x, last.z - prev.z) > minMoveM else { return nil }
            return ActivityItem(id: "\(o.id)-\(last.t.timeIntervalSince1970)", objectId: o.id,
                                text: "\(o.label.capitalizedFirst) moved \(place(x: last.x, z: last.z, object: o, map: map))",
                                at: last.t)
        }
        .sorted { $0.at > $1.at }
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
}

extension String {
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}
