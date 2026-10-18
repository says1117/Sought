import Foundation

// Gemini REST format used here (text only, function calling):
//   Request/response: https://ai.google.dev/api/generate-content  (models/{model}:generateContent)
//   Function calling guide: https://ai.google.dev/gemini-api/docs/function-calling
// Note: the guide now leads with a newer "Interactions API" (/v1beta/interactions); this file deliberately
// uses the documented generateContent endpoint. Re-check both pages, and the model id, before the demo.
// The key goes in the x-goog-api-key header, never in the URL, and never in the repo.

/// API key and model id, read from Info.plist keys GEMINI_API_KEY / GEMINI_MODEL, which Xcode fills from
/// the gitignored Secrets.xcconfig. Returns nil when unset or still a placeholder.
struct GeminiConfig: Equatable {
    var apiKey: String
    var model: String
    var timeout: TimeInterval = 3
    var baseURL = URL(string: "https://generativelanguage.googleapis.com/v1beta")!

    static func from(info: [String: Any]?) -> GeminiConfig? {
        guard let info,
              let key = (info["GEMINI_API_KEY"] as? String)?.trimmingCharacters(in: .whitespaces),
              let model = (info["GEMINI_MODEL"] as? String)?.trimmingCharacters(in: .whitespaces),
              !key.isEmpty, !model.isEmpty,
              key != "your-key-here", !key.hasPrefix("$(") , !model.hasPrefix("$(") else { return nil }
        return GeminiConfig(apiKey: key, model: model)
    }

    static func fromBundle(_ bundle: Bundle = .main) -> GeminiConfig? { from(info: bundle.infoDictionary) }
}

/// Seam for tests: no live calls in unit tests.
protocol PlannerTransport {
    func send(_ request: URLRequest) async throws -> (data: Data, status: Int)
}

struct URLSessionPlannerTransport: PlannerTransport {
    var session: URLSession = .shared
    func send(_ request: URLRequest) async throws -> (data: Data, status: Int) {
        let (data, resp) = try await session.data(for: request)
        return (data, (resp as? HTTPURLResponse)?.statusCode ?? 0)
    }
}

struct GeminiPlanner: Planner {
    let config: GeminiConfig
    let transport: PlannerTransport

    init(config: GeminiConfig, transport: PlannerTransport = URLSessionPlannerTransport()) {
        self.config = config
        self.transport = transport
    }

    static let systemPrompt = """
    You control a small home rover. Pick the tool that matches the user's request. \
    You may only call the provided tools; you cannot set speeds, distances or safety. \
    For go_to_waypoint and come_to_waypoint use only a name from the known waypoints. If no tool fits, call say with a short reply.
    """

    func plan(_ utterance: String, context: PlannerContext) async throws -> [ToolCall] {
        let request = try buildRequest(utterance: utterance, context: context)
        let (data, status) = try await withTimeout(config.timeout) { try await transport.send(request) }
        guard (200..<300).contains(status) else { throw PlannerError.transport("HTTP \(status)") }
        return try Self.parseResponse(data, context: context)
    }

    // MARK: request

    func buildRequest(utterance: String, context: PlannerContext) throws -> URLRequest {
        let url = config.baseURL.appendingPathComponent("models/\(config.model):generateContent")
        var req = URLRequest(url: url, timeoutInterval: config.timeout)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(config.apiKey, forHTTPHeaderField: "x-goog-api-key")
        req.httpBody = try JSONSerialization.data(withJSONObject: Self.requestBody(utterance: utterance, context: context))
        return req
    }

    static func requestBody(utterance: String, context: PlannerContext) -> [String: Any] {
        [
            "systemInstruction": ["parts": [["text": systemPrompt]]],
            "contents": [["role": "user", "parts": [["text": userText(utterance, context)]]]],
            "tools": [["functionDeclarations": functionDeclarations()]],
            // ANY: the model must answer with a function call (say covers plain replies).
            "toolConfig": ["functionCallingConfig": ["mode": "ANY"]],
        ]
    }

    /// Text only: transcript, waypoint names, route names, last patrol summary.
    static func userText(_ utterance: String, _ ctx: PlannerContext) -> String {
        var lines = ["Request: \(utterance)"]
        lines.append("Known waypoints: " + (ctx.waypointNames.isEmpty ? "none" : ctx.waypointNames.joined(separator: ", ")))
        if !ctx.routeNames.isEmpty { lines.append("Known routes: " + ctx.routeNames.joined(separator: ", ")) }
        if !ctx.trackNames.isEmpty { lines.append("Known tracks: " + ctx.trackNames.joined(separator: ", ")) }
        if let s = ctx.lastPatrolSummary, !s.isEmpty { lines.append("Last patrol summary: " + String(s.prefix(500))) }
        return lines.joined(separator: "\n")
    }

    /// Generated from PlannerTools.specs, the same list ToolCall.parse validates against.
    static func functionDeclarations() -> [[String: Any]] {
        PlannerTools.specs.map { spec in
            var decl: [String: Any] = ["name": spec.name, "description": spec.description]
            if !spec.params.isEmpty {
                var props: [String: Any] = [:]
                for p in spec.params { props[p.name] = ["type": p.kind.rawValue, "description": p.description] }
                decl["parameters"] = [
                    "type": "OBJECT",
                    "properties": props,
                    "required": spec.params.filter(\.required).map(\.name),
                ]
            }
            return decl
        }
    }

    // MARK: response

    /// candidates[0].content.parts[].functionCall {name, args}
    static func parseResponse(_ data: Data, context: PlannerContext) throws -> [ToolCall] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw PlannerError.badResponse("not JSON")
        }
        guard let cand = (root["candidates"] as? [[String: Any]])?.first,
              let parts = (cand["content"] as? [String: Any])?["parts"] as? [[String: Any]] else {
            throw PlannerError.badResponse("no candidates")
        }
        let calls = parts.compactMap { $0["functionCall"] as? [String: Any] }
        guard !calls.isEmpty else { throw PlannerError.noToolCall }
        guard calls.count <= PlannerTools.maxCallsPerPlan else { throw PlannerError.tooManyCalls }
        return try calls.map { call in
            guard let name = call["name"] as? String else { throw PlannerError.badResponse("functionCall without name") }
            let args = call["args"] as? [String: Any] ?? [:]
            return try ToolCall.parse(name: name, args: args).validated(against: context)
        }
    }

    // MARK: timeout

    private func withTimeout<T>(_ seconds: TimeInterval, _ op: @escaping () async throws -> T) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await op() }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                throw PlannerError.timeout
            }
            defer { group.cancelAll() }
            guard let first = try await group.next() else { throw PlannerError.timeout }
            return first
        }
    }
}
