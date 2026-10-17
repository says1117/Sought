import Foundation

// Planner contract (plan v2 section 6). Pure Foundation, no UIKit, so it builds under SwiftPM and swiftc.
// The model may only pick one of these tools and fill typed arguments. Speeds, distances and safety are
// constants in the executors, never arguments here.

/// Every tool in plan section 6.2 with typed arguments.
enum ToolCall: Equatable {
    case findObject(description: String)
    case goToWaypoint(name: String)
    case markWaypoint(name: String)
    case checkRoute(name: String)
    case startPatrol
    case whatChanged(since: String?)
    case stop
    case say(text: String)
    case explore(maxMinutes: Int?)
    case comeToMe

    /// Wire name, identical to the Gemini function declaration name.
    var toolName: String {
        switch self {
        case .findObject: return "find_object"
        case .goToWaypoint: return "go_to_waypoint"
        case .markWaypoint: return "mark_waypoint"
        case .checkRoute: return "check_route"
        case .startPatrol: return "start_patrol"
        case .whatChanged: return "what_changed"
        case .stop: return "stop"
        case .say: return "say"
        case .explore: return "explore"
        case .comeToMe: return "come_to_me"
        }
    }
}

/// Text-only context. Nothing here is an image or a pose.
struct PlannerContext: Equatable {
    var waypointNames: [String]
    var routeNames: [String]
    /// Names of tracked things (e.g. a remembered object track) that go_to may also target.
    var trackNames: [String]
    var lastPatrolSummary: String?

    init(waypointNames: [String] = [], routeNames: [String] = [], trackNames: [String] = [],
         lastPatrolSummary: String? = nil) {
        self.waypointNames = waypointNames
        self.routeNames = routeNames
        self.trackNames = trackNames
        self.lastPatrolSummary = lastPatrolSummary
    }

    func resolveWaypoint(_ raw: String) -> String? { Self.resolve(raw, in: waypointNames) }
    func resolveRoute(_ raw: String) -> String? { Self.resolve(raw, in: routeNames) }
    func resolveTrack(_ raw: String) -> String? { Self.resolve(raw, in: trackNames) }

    static func resolve(_ raw: String, in names: [String]) -> String? {
        let key = PlannerText.normalizeName(raw)
        guard !key.isEmpty else { return nil }
        return names.first { PlannerText.normalizeName($0) == key }
    }
}

enum PlannerError: Error, Equatable {
    case noMatch                       // keyword grammar did not understand the utterance
    case unknownTool(String)
    case badArguments(tool: String, reason: String)
    case unresolvedTarget(tool: String, name: String)
    case noToolCall                    // model answered with text only
    case tooManyCalls
    case timeout
    case transport(String)
    case badResponse(String)
    case notConfigured
}

protocol Planner {
    func plan(_ utterance: String, context: PlannerContext) async throws -> [ToolCall]
}

enum PlannerText {
    /// Lowercase, strip punctuation, collapse spaces, drop leading articles/possessives.
    static func normalizeName(_ s: String) -> String {
        var words = tokens(s)
        while let f = words.first, ["the", "a", "an", "my", "our"].contains(f) { words.removeFirst() }
        return words.joined(separator: " ")
    }

    static func tokens(_ s: String) -> [String] {
        let lowered = s.lowercased()
        let cleaned = lowered.map { $0.isLetter || $0.isNumber || $0 == "'" ? $0 : " " }
        return String(cleaned).split(separator: " ").map(String.init)
    }
}

// MARK: - Tool specs (single source for Gemini declarations and argument validation)

struct ToolParam {
    enum Kind: String { case string = "STRING", integer = "INTEGER" }
    let name: String
    let kind: Kind
    let description: String
    let required: Bool
}

struct ToolSpec {
    let name: String
    let description: String
    let params: [ToolParam]
}

enum PlannerTools {
    // Safety bounds enforced in code, not trusted from the model.
    static let maxExploreMinutes = 30
    static let maxNameLength = 40
    static let maxDescriptionLength = 120
    static let maxSayLength = 300
    static let maxCallsPerPlan = 4

    static let specs: [ToolSpec] = [
        ToolSpec(name: "find_object",
                 description: "Find a thing the user describes (an object, not a taught place). Searches memory, drives toward it and checks on arrival.",
                 params: [ToolParam(name: "description", kind: .string, description: "What to find, e.g. 'blue water bottle'.", required: true)]),
        ToolSpec(name: "go_to_waypoint",
                 description: "Drive to a taught waypoint. The name must be one of the known waypoints.",
                 params: [ToolParam(name: "name", kind: .string, description: "Waypoint name from the known list.", required: true)]),
        ToolSpec(name: "mark_waypoint",
                 description: "Save the robot's current position as a named waypoint.",
                 params: [ToolParam(name: "name", kind: .string, description: "Name for the new waypoint.", required: true)]),
        ToolSpec(name: "check_route",
                 description: "Drive a route and report whether it is clear or blocked.",
                 params: [ToolParam(name: "name", kind: .string, description: "Route or waypoint name from the known list.", required: true)]),
        ToolSpec(name: "start_patrol",
                 description: "Run the default patrol.",
                 params: []),
        ToolSpec(name: "what_changed",
                 description: "Read aloud the latest change report.",
                 params: [ToolParam(name: "since", kind: .string, description: "Optional time phrase such as 'yesterday'.", required: false)]),
        ToolSpec(name: "stop",
                 description: "Brake immediately and cancel the current task.",
                 params: []),
        ToolSpec(name: "say",
                 description: "Speak a short sentence to the user. Use when no other tool fits.",
                 params: [ToolParam(name: "text", kind: .string, description: "What to say.", required: true)]),
        ToolSpec(name: "explore",
                 description: "Run Explore mode to map the surroundings.",
                 params: [ToolParam(name: "max_minutes", kind: .integer, description: "Optional time limit in minutes.", required: false)]),
        ToolSpec(name: "come_to_me",
                 description: "Drive to the companion iPhone the user is carrying.",
                 params: []),
    ]

    static func spec(named name: String) -> ToolSpec? { specs.first { $0.name == name } }
}

// MARK: - Parsing and validation

extension ToolCall {
    /// Parse a model-supplied function call. Unknown tool, unknown argument, missing or ill-typed
    /// argument, or an out-of-range value is rejected. Does not check targets against context.
    static func parse(name: String, args: [String: Any]) throws -> ToolCall {
        guard let spec = PlannerTools.spec(named: name) else { throw PlannerError.unknownTool(name) }
        func bad(_ r: String) -> PlannerError { .badArguments(tool: name, reason: r) }

        let allowed = Set(spec.params.map(\.name))
        if let extra = args.keys.sorted().first(where: { !allowed.contains($0) }) { throw bad("unexpected argument \(extra)") }
        for p in spec.params where p.required && args[p.name] == nil { throw bad("missing \(p.name)") }

        func string(_ key: String, max: Int) throws -> String {
            guard let v = args[key] as? String else { throw bad("\(key) must be a string") }
            let t = v.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !t.isEmpty else { throw bad("\(key) is empty") }
            guard t.count <= max else { throw bad("\(key) too long") }
            return t
        }

        switch name {
        case "find_object": return .findObject(description: try string("description", max: PlannerTools.maxDescriptionLength))
        case "go_to_waypoint": return .goToWaypoint(name: try string("name", max: PlannerTools.maxNameLength))
        case "mark_waypoint": return .markWaypoint(name: try string("name", max: PlannerTools.maxNameLength))
        case "check_route": return .checkRoute(name: try string("name", max: PlannerTools.maxNameLength))
        case "start_patrol": return .startPatrol
        case "what_changed":
            return .whatChanged(since: args["since"] == nil ? nil : try string("since", max: PlannerTools.maxNameLength))
        case "stop": return .stop
        case "say": return .say(text: try string("text", max: PlannerTools.maxSayLength))
        case "explore":
            guard let raw = args["max_minutes"] else { return .explore(maxMinutes: nil) }
            // JSON numbers decode as NSNumber; accept integral values only, never booleans.
            guard let n = raw as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(),
                  n.doubleValue == n.doubleValue.rounded() else { throw bad("max_minutes must be an integer") }
            let v = n.intValue
            guard v >= 1, v <= PlannerTools.maxExploreMinutes else { throw bad("max_minutes out of range") }
            return .explore(maxMinutes: v)
        case "come_to_me": return .comeToMe
        default: throw PlannerError.unknownTool(name)
        }
    }

    /// Check go_to / check_route targets against known names and canonicalize them.
    /// go_to_waypoint resolves to a waypoint or a track; check_route to a route or waypoint.
    func validated(against ctx: PlannerContext) throws -> ToolCall {
        switch self {
        case .goToWaypoint(let n):
            guard let r = ctx.resolveWaypoint(n) ?? ctx.resolveTrack(n) else {
                throw PlannerError.unresolvedTarget(tool: toolName, name: n)
            }
            return .goToWaypoint(name: r)
        case .checkRoute(let n):
            guard let r = ctx.resolveRoute(n) ?? ctx.resolveWaypoint(n) else {
                throw PlannerError.unresolvedTarget(tool: toolName, name: n)
            }
            return .checkRoute(name: r)
        default:
            return self
        }
    }
}
