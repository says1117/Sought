import Foundation
#if canImport(PlannerCore)
@testable import PlannerCore
#endif

/// Runs planned tool calls. The real coordinator is built later; the Find bar only depends on this.
protocol ToolExecuting: AnyObject {
    /// Run one call to completion (or until cancelled). Throwing surfaces as an error state in the UI.
    func execute(_ call: ToolCall) async throws
    /// Brake and cancel everything now. Must be synchronous and must not depend on the planner.
    func stopAll()
}

/// No-op executor that records calls. Used until the coordinator exists, and in tests.
final class LoggingToolExecutor: ToolExecuting {
    private(set) var executed: [ToolCall] = []
    private(set) var stopCount = 0
    private let stopHandler: () -> Void
    var log: (String) -> Void = { print("[tool] \($0)") }

    init(stop: @escaping () -> Void = {}) { stopHandler = stop }

    func execute(_ call: ToolCall) async throws {
        executed.append(call)
        log("execute \(call.toolName)")
    }

    func stopAll() {
        stopCount += 1
        stopHandler()
        log("stopAll")
    }
}

/// Plain-words text for a tool call, for the screen and for spoken confirmations.
enum ToolCallDescription {
    static func describe(_ call: ToolCall) -> String {
        switch call {
        case .findObject(let d): return "Looking for \(d)"
        case .goToWaypoint(let n): return "Going to \(n)"
        case .markWaypoint(let n): return "Saving this spot as \(n)"
        case .checkRoute(let n): return "Checking the way to \(n)"
        case .startPatrol: return "Starting patrol"
        case .whatChanged(let s): return s.map { "Reporting what changed since \($0)" } ?? "Reporting what changed"
        case .stop: return "Stopping"
        case .say(let t): return t
        case .explore(let m): return m.map { "Exploring for up to \($0) minutes" } ?? "Exploring"
        case .comeToMe: return "Coming to you"
        }
    }

    static func describe(_ calls: [ToolCall]) -> String {
        calls.map(describe).joined(separator: ", then ")
    }
}
