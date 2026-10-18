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
    /// Come to me v2: drive to the user at a taught place ("come to me in the kitchen").
    case comeToWaypoint(name: String)
    /// Remote Teach: drive straight `meters` along the current heading (negative = back). Range-checked by the parsers.
    case move(meters: Double)
    /// Remote Teach: turn in place by `degrees` (positive = left / counter-clockwise, negative = right).
    case turn(degrees: Double)
    /// Remote Teach: the Scan here routine (4 x 90 degree turns with a dwell) as a coordinator task.
    case scanHere
    /// Remote Teach: save the ARWorldMap and adopt it, exactly like Teach's Save map.
    case saveMap

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
        case .comeToWaypoint: return "come_to_waypoint"
        case .move: return "move"
        case .turn: return "turn"
        case .scanHere: return "scan_here"
        case .saveMap: return "save_map"
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
    enum Kind: String { case string = "STRING", integer = "INTEGER", number = "NUMBER" }
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
    // Remote Teach ranges (command spec shared with Sought). Magnitudes outside are clamped; zero is refused.
    static let moveRangeM: ClosedRange<Double> = 0.1...1.0
    static let defaultMoveM = 0.5
    static let turnRangeDeg: ClosedRange<Double> = 10...180
    static let defaultTurnDeg = 90.0

    /// Signed metres with the magnitude clamped into `moveRangeM`; nil for zero or not a number.
    static func clampMove(_ m: Double) -> Double? { clampSigned(m, moveRangeM) }
    /// Signed degrees with the magnitude clamped into `turnRangeDeg`; nil for zero or not a number.
    static func clampTurn(_ d: Double) -> Double? { clampSigned(d, turnRangeDeg) }
    private static func clampSigned(_ v: Double, _ r: ClosedRange<Double>) -> Double? {
        guard v.isFinite, v != 0 else { return nil }
        let mag = Swift.min(Swift.max(abs(v), r.lowerBound), r.upperBound)
        return v < 0 ? -mag : mag
    }

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
        ToolSpec(name: "come_to_waypoint",
                 description: "Come to the user at a taught place they name, e.g. 'come to me in the kitchen' or 'come to the kitchen'. Follows taught routes and stops about 1 m short. The name must be one of the known waypoints.",
                 params: [ToolParam(name: "name", kind: .string, description: "Waypoint name from the known list.", required: true)]),
        ToolSpec(name: "move",
                 description: "Drive straight forward (positive) or back (negative) a short distance, e.g. 'forward 0.5 m' or 'back 0.3 m'.",
                 params: [ToolParam(name: "meters", kind: .number, description: "Signed metres, 0.1 to 1.0 either way. Negative drives back.", required: true)]),
        ToolSpec(name: "turn",
                 description: "Turn in place, e.g. 'turn left 90' or 'turn right 45'.",
                 params: [ToolParam(name: "degrees", kind: .number, description: "Signed degrees, 10 to 180 either way. Positive turns left, negative turns right.", required: true)]),
        ToolSpec(name: "scan_here",
                 description: "Look around from here: turn in place in four steps, pausing at each so objects are remembered.",
                 params: []),
        ToolSpec(name: "save_map",
                 description: "Save the room map now, like Teach's Save map.",
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

        func number(_ key: String) throws -> Double {
            guard let n = args[key] as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() else { throw bad("\(key) must be a number") }
            return n.doubleValue
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
        case "come_to_waypoint": return .comeToWaypoint(name: try string("name", max: PlannerTools.maxNameLength))
        case "move":
            guard let m = PlannerTools.clampMove(try number("meters")) else { throw bad("meters must not be zero") }
            return .move(meters: m)
        case "turn":
            guard let d = PlannerTools.clampTurn(try number("degrees")) else { throw bad("degrees must not be zero") }
            return .turn(degrees: d)
        case "scan_here": return .scanHere
        case "save_map": return .saveMap
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
        case .comeToWaypoint(let n):
            guard let r = ctx.resolveWaypoint(n) else { throw PlannerError.unresolvedTarget(tool: toolName, name: n) }
            return .comeToWaypoint(name: r)
        default:
            return self
        }
    }
}

// MARK: - Remote Teach text

/// Short numbers for Remote Teach acks and labels: "0.5", "1", "0.25"; degrees as whole numbers.
enum RemoteTeachText {
    static func meters(_ m: Double) -> String {
        let r = (m * 100).rounded() / 100
        if r == r.rounded() { return String(Int(r)) }
        var s = String(format: "%.2f", r)
        while s.hasSuffix("0") { s.removeLast() }
        return s
    }
    static func degrees(_ d: Double) -> String { String(Int(d.rounded())) }
}
