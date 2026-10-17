import Foundation

/// Offline planner for the grammar in plan section 6.3. Deterministic, no network.
struct KeywordPlanner: Planner {
    init() {}

    func plan(_ utterance: String, context: PlannerContext) async throws -> [ToolCall] {
        try Self.parse(utterance, context: context)
    }

    private static let filler: Set<String> = ["please", "now", "robot", "immediately", "just", "hey", "ok", "okay"]

    static func parse(_ utterance: String, context: PlannerContext) throws -> [ToolCall] {
        let words = PlannerText.tokens(utterance).filter { !filler.contains($0) }
        guard !words.isEmpty else { throw PlannerError.noMatch }
        let text = words.joined(separator: " ")

        // Safety first: stop/halt as the leading word.
        if ["stop", "halt"].contains(words[0]) { return [.stop] }

        if text.contains("come here") || text.contains("come to me") { return [.comeToMe] }
        if text.contains("what changed") || text.contains("what has changed") { return [.whatChanged(since: nil)] }

        if text.hasPrefix("explore") || text.contains("look around") || text.contains("map the house")
            || text.contains("map this house") || text.contains("map my house") {
            return [.explore(maxMinutes: minutes(in: words))]
        }

        if let name = remainder(of: text, afterAny: ["mark this as", "mark this spot as", "this is"]) {
            return [.markWaypoint(name: try waypointLabel(name))]
        }

        if let name = remainder(of: text, afterAny: ["check the way to", "check the route to", "check the way", "check route"]) {
            return [try ToolCall.checkRoute(name: name).validated(against: context)]
        }

        if words[0] == "patrol" || text.hasPrefix("start patrol") || text.hasPrefix("start a patrol")
            || text.hasPrefix("do a patrol") || text.hasPrefix("run patrol") || text.hasPrefix("run a patrol") {
            return [.startPatrol]
        }

        if let phrase = remainder(of: text, afterAny: ["where is", "where are", "where's", "find", "go to"]) {
            let clean = PlannerText.normalizeName(phrase)
            guard !clean.isEmpty else { throw PlannerError.noMatch }
            // Waypoint name first, else treat it as an object description.
            if let wp = context.resolveWaypoint(clean) ?? context.resolveTrack(clean) { return [.goToWaypoint(name: wp)] }
            guard clean.count <= PlannerTools.maxDescriptionLength else { throw PlannerError.noMatch }
            return [.findObject(description: clean)]
        }
        throw PlannerError.noMatch
    }

    /// Text after the first matching prefix (prefix must start the utterance, optionally after "can you"/"go and").
    private static func remainder(of text: String, afterAny prefixes: [String]) -> String? {
        var t = text
        for lead in ["can you ", "could you ", "go and ", "and "] where t.hasPrefix(lead) { t.removeFirst(lead.count) }
        for p in prefixes.sorted(by: { $0.count > $1.count }) {
            if t == p { return nil }
            if t.hasPrefix(p + " ") { return String(t.dropFirst(p.count + 1)) }
        }
        return nil
    }

    private static func waypointLabel(_ raw: String) throws -> String {
        let n = PlannerText.normalizeName(raw)
        guard !n.isEmpty, n.count <= PlannerTools.maxNameLength else { throw PlannerError.noMatch }
        return n
    }

    /// "explore for 5 minutes" -> 5, clamped to the code-side maximum. Nothing found -> nil.
    private static func minutes(in words: [String]) -> Int? {
        for (i, w) in words.enumerated() where i + 1 < words.count && words[i + 1].hasPrefix("minute") {
            if let n = Int(w), n >= 1 { return min(n, PlannerTools.maxExploreMinutes) }
        }
        return nil
    }
}
