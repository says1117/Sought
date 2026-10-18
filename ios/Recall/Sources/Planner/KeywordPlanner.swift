import Foundation

/// Offline planner for the grammar in plan section 6.3. Deterministic, no network.
struct KeywordPlanner: Planner {
    init() {}

    func plan(_ utterance: String, context: PlannerContext) async throws -> [ToolCall] {
        try Self.parse(utterance, context: context)
    }

    private static let filler: Set<String> = ["please", "now", "robot", "immediately", "just", "hey", "ok", "okay"]

    static func parse(_ utterance: String, context: PlannerContext) throws -> [ToolCall] {
        if let teach = try remoteTeach(utterance) { return [teach] }
        let words = PlannerText.tokens(utterance).filter { !filler.contains($0) }
        guard !words.isEmpty else { throw PlannerError.noMatch }
        let text = words.joined(separator: " ")

        // Safety first: stop/halt as the leading word.
        if ["stop", "halt"].contains(words[0]) { return [.stop] }

        // "come to me in the kitchen", "come to the kitchen": a taught place (come to me v2). Plain "come to me" stays v1.
        if let place = remainder(of: text, afterAny: ["come to me in", "come to me at", "come to me by", "come to"]),
           PlannerText.normalizeName(place) != "me" {
            return [try ToolCall.comeToWaypoint(name: place).validated(against: context)]
        }
        if text.contains("come here") || text.contains("come to me") { return [.comeToMe] }
        if text.contains("what changed") || text.contains("what has changed") { return [.whatChanged(since: nil)] }

        if text.hasPrefix("explore") || text.contains("look around") || text.contains("map the house")
            || text.contains("map this house") || text.contains("map my house") {
            return [.explore(maxMinutes: minutes(in: words))]
        }

        if let name = remainder(of: text, afterAny: ["mark this as", "mark this spot as", "this is", "mark"]) {
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

    // Remote Teach grammar (spec shared with Sought; keep in step): "forward <x> m" / "back <x> m" (x 0.1-1.0, default
    // 0.5), "turn left <deg>" / "turn right <deg>" (10-180, default 90), "scan here", "save map". "mark <name>" and
    // "stop" are handled by the general grammar. Numbers are read from the raw text because tokens split "0.5".
    private static let moveRegex = try! NSRegularExpression(pattern:
        #"^(?:move |go |drive )?(forward|forwards|ahead|back|backward|backwards)(?: (-?\d+(?:\.\d+)?|\.\d+))? ?(?:m|meter|meters|metre|metres)?$"#)
    private static let turnRegex = try! NSRegularExpression(pattern:
        #"^(?:turn|rotate) (left|right)(?: (-?\d+(?:\.\d+)?))? ?(?:°|deg|degree|degrees)?$"#)

    /// A Remote Teach command, nil when the text is not one. Magnitudes are clamped into range; zero throws `noMatch`.
    static func remoteTeach(_ utterance: String) throws -> ToolCall? {
        var t = utterance.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        while let last = t.last, ".!?".contains(last) { t.removeLast() }
        t = t.split(whereSeparator: { $0 == " " || $0 == "\t" }).joined(separator: " ")
        for lead in ["please ", "robot ", "ok ", "okay "] where t.hasPrefix(lead) { t.removeFirst(lead.count) }
        if t.hasSuffix(" please") { t.removeLast(" please".count) }
        let range = NSRange(t.startIndex..., in: t)
        func group(_ m: NSTextCheckingResult, _ i: Int) -> String? {
            Range(m.range(at: i), in: t).map { String(t[$0]) }
        }
        if let m = moveRegex.firstMatch(in: t, range: range), let dir = group(m, 1) {
            let raw = group(m, 2).flatMap(Double.init) ?? PlannerTools.defaultMoveM
            guard raw > 0, let mag = PlannerTools.clampMove(raw) else { throw PlannerError.noMatch }
            return .move(meters: dir.hasPrefix("back") ? -mag : mag)
        }
        if let m = turnRegex.firstMatch(in: t, range: range), let dir = group(m, 1) {
            let raw = group(m, 2).flatMap(Double.init) ?? PlannerTools.defaultTurnDeg
            guard raw > 0, let mag = PlannerTools.clampTurn(raw) else { throw PlannerError.noMatch }
            return .turn(degrees: dir == "left" ? mag : -mag)
        }
        let words = PlannerText.tokens(t).filter { !filler.contains($0) }.joined(separator: " ")
        if ["scan here", "scan", "scan this room", "scan the room"].contains(words) { return .scanHere }
        if ["save map", "save the map", "save this map", "save room map", "save the room map"].contains(words) { return .saveMap }
        return nil
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
