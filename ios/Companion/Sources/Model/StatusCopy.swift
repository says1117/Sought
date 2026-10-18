import Foundation

// Plain-word copy for every heartbeat state (plan section 5.1). No em dashes in user-facing copy.

enum StatusCopy {
    static func line(_ s: RobotStatus, now: Date = Date()) -> String {
        guard s.isOnline(now: now) else { return offline(s, now: now) }
        let base: String
        switch s.state {
        case .idle: base = "Soughtbot is resting"
        case .teaching: base = "Soughtbot is learning the room"
        case .finding: base = "Soughtbot is looking for \(item(from: s.task) ?? "something")"
        case .exploring, .patrolling, .checkingRoute: base = "Soughtbot is roaming"
        case .comingToUser: base = "Soughtbot is coming to you"
        case .blocked: base = "Soughtbot is stuck. Something is in the way"
        case .error: base = "Soughtbot needs help"
        }
        guard let b = s.battery else { return base }
        return "\(base) · \(Int((b * 100).rounded()))%"
    }

    static func offline(_ s: RobotStatus, now: Date) -> String {
        guard let t = s.lastHeartbeat else { return "Soughtbot is offline" }
        return "Soughtbot is offline · last seen \(ago(t, now: now))"
    }

    /// Spoken form for VoiceOver and announcements: no middle dot, battery spelled out.
    static func spoken(_ s: RobotStatus, now: Date = Date()) -> String {
        line(s, now: now).replacingOccurrences(of: " · ", with: ". ").replacingOccurrences(of: "%", with: " percent battery")
    }

    /// "find: blue backpack" -> "blue backpack"
    static func item(from task: String?) -> String? {
        guard let task, let r = task.range(of: ":") else { return task }
        return task[r.upperBound...].trimmingCharacters(in: .whitespaces)
    }

    static func ago(_ d: Date, now: Date = Date()) -> String {
        let s = max(0, now.timeIntervalSince(d))
        switch s {
        case ..<60: return "just now"
        case ..<3600: return "\(Int(s / 60)) min ago"
        case ..<7200: return "1 hour ago"
        case ..<86400: return "\(Int(s / 3600)) hours ago"
        case ..<172800: return "yesterday"
        default: return "\(Int(s / 86400)) days ago"
        }
    }

    /// Longer form for VoiceOver: "12 minutes ago".
    static func agoSpoken(_ d: Date, now: Date = Date()) -> String {
        ago(d, now: now).replacingOccurrences(of: " min ", with: " minutes ")
    }
}
