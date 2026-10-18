import Foundation
#if canImport(PlannerCore)
@testable import PlannerCore
#endif
#if canImport(SyncCore)
import SyncCore
#endif

/// Runs a remote command's text the way the find bar does: offline keyword STOP first, then the planner
/// (primary raced against a timeout, keyword grammar on any failure), then each tool call through the
/// coordinator. The result is read from the coordinator's trace entries for this command.
///
/// Remote commands never queue motion: if a task is running or pending, a manual tool is open, or another
/// remote command is still being handled, the command is refused with `CommandPoller.busy`. A stop is
/// obeyed at any time and goes straight to `stopAll()`.
final class RemoteCommandRunner: CommandRunning {
    private let planner: Planner
    private let fallback: Planner
    private let coordinator: RobotCoordinator
    private let context: () -> PlannerContext
    private let plannerTimeout: TimeInterval
    private let lock = NSLock()
    private var handling = false

    /// Trace events that end a remote command as failed (see RobotCoordinator `record` calls).
    static let failureEvents: Set<String> = ["refused", "rejected", "unsupported", "blocked", "error", "cancelled",
                                             "late-return", "drain-timeout", "stop"]

    init(planner: Planner, fallback: Planner = KeywordPlanner(), coordinator: RobotCoordinator,
         plannerTimeout: TimeInterval = 3, context: @escaping () -> PlannerContext = { PlannerContext() }) {
        self.planner = planner; self.fallback = fallback; self.coordinator = coordinator
        self.plannerTimeout = plannerTimeout; self.context = context
    }

    func run(_ text: String) async -> CommandOutcome {
        if (try? KeywordPlanner.parse(text, context: context()))?.contains(.stop) == true { return stop() }
        guard claim() else { return .failed(CommandPoller.busy) }
        defer { release() }

        let calls: [ToolCall]
        do { calls = try await plan(text) } catch {
            return .failed("I did not understand that. Try: find my keys, go to the kitchen, or stop.")
        }
        if calls.contains(.stop) { return stop() }
        // Re-check after planning: a local request may have started meanwhile. Never queue behind it.
        if coordinator.isBusy || coordinator.hasPending || coordinator.manualControlOpen { return .failed(CommandPoller.busy) }

        var results: [String] = []
        for call in calls {
            let mark = coordinator.trace.count
            do { try await coordinator.execute(call) } catch {
                return .failed("Could not do \(call.toolName): \(error)")
            }
            let entries = coordinator.trace.dropFirst(mark).filter { $0.event != "request" && $0.event != "start" }
            if let bad = entries.first(where: { Self.failureEvents.contains($0.event) }) {
                return .failed("\(bad.event): \(bad.detail)")
            }
            if case .say(let spoken) = call { results.append(spoken); continue }
            if let queued = entries.first(where: { $0.event == "queued" }) {
                // Only reachable if a local task slipped in between the busy check and execute.
                results.append("queued: \(queued.detail)")
                continue
            }
            results.append(entries.last.map { "\($0.event): \($0.detail)" } ?? call.toolName)
        }
        return .done(results.joined(separator: "; "))
    }

    private func stop() -> CommandOutcome {
        coordinator.stopAll()
        return .done("Stopped.")
    }

    private func claim() -> Bool {
        if coordinator.isBusy || coordinator.hasPending || coordinator.manualControlOpen { return false }
        lock.lock(); defer { lock.unlock() }
        if handling { return false }
        handling = true
        return true
    }

    private func release() { lock.lock(); handling = false; lock.unlock() }

    /// Same as the find bar: primary raced against the timeout; on timeout or any failure use the keyword grammar.
    private func plan(_ text: String) async throws -> [ToolCall] {
        let ctx = context()
        let primary = planner
        let timeout = plannerTimeout
        do {
            return try await withThrowingTaskGroup(of: [ToolCall].self) { group in
                group.addTask { try await primary.plan(text, context: ctx) }
                group.addTask {
                    try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                    throw PlannerError.timeout
                }
                defer { group.cancelAll() }
                return try await group.next()!
            }
        } catch {
            return try await fallback.plan(text, context: ctx)
        }
    }
}
