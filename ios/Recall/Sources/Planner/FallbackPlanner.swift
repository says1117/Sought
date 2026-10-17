import Foundation

/// Try the primary (Gemini) planner; on any failure (timeout, offline, bad response, rejected tool or
/// target) fall back to the offline keyword grammar. If the keywords also fail, that error propagates.
struct FallbackPlanner: Planner {
    let primary: Planner?
    let fallback: Planner
    /// Called with the primary's error when falling back (for logging/UI). Never receives the key.
    var onFallback: ((Error) -> Void)?

    init(primary: Planner?, fallback: Planner = KeywordPlanner(), onFallback: ((Error) -> Void)? = nil) {
        self.primary = primary
        self.fallback = fallback
        self.onFallback = onFallback
    }

    /// Gemini when a key is configured, keywords only otherwise.
    static func make(config: GeminiConfig? = GeminiConfig.fromBundle(),
                     transport: PlannerTransport = URLSessionPlannerTransport()) -> FallbackPlanner {
        FallbackPlanner(primary: config.map { GeminiPlanner(config: $0, transport: transport) })
    }

    func plan(_ utterance: String, context: PlannerContext) async throws -> [ToolCall] {
        if let primary {
            do { return try await primary.plan(utterance, context: context) }
            catch is CancellationError { throw CancellationError() }
            catch { onFallback?(error) }
        } else {
            onFallback?(PlannerError.notConfigured)
        }
        return try await fallback.plan(utterance, context: context)
    }
}
