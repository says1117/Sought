import Foundation
#if canImport(PlannerCore)
@testable import PlannerCore
#endif

/// Runs planner tool calls one at a time. LLM-first control: the planner picks the tool, this class only
/// sequences tasks and makes `stop` win. It never sets speeds or limits; those live in the ESP32 and guards.
///
/// Rules:
/// - Exactly one task (explore, find, go_to_waypoint, come_to_me) runs at a time.
/// - A second task request while one runs is held as the single pending request. If that slot is also full,
///   or the request is mark_waypoint, it is refused with a spoken reason. Never throws for that.
/// - `stopAll()` is synchronous: drive STOP first, then cancel the sub-task, clear pending, state idle.
/// - Tracking not normal for more than 1 s cancels the motion task and reports "need a rescan" (blocked).
/// - Reported failures become `blocked`; a thrown error becomes `error` and is rethrown to the caller.
final class RobotCoordinator {
    private final class Request {
        let id = UUID()
        let kind: CoordinatorTaskKind
        let label: String
        let run: () async throws -> CoordinatorTaskResult
        let cancel: () -> Void
        var monitor: Task<Void, Never>?
        init(kind: CoordinatorTaskKind, label: String, run: @escaping () async throws -> CoordinatorTaskResult,
             cancel: @escaping () -> Void) {
            self.kind = kind; self.label = label; self.run = run; self.cancel = cancel
        }
    }

    private let deps: CoordinatorDependencies
    private let config: CoordinatorConfig
    private let lock = NSLock()
    private var active: Request?
    private var pending: Request?
    private var _status = CoordinatorStatus.idle
    private var _trace: [CoordinatorTraceEntry] = []

    /// Called on every status change, outside the lock, possibly from any thread.
    var onChange: (CoordinatorStatus) -> Void = { _ in }

    init(dependencies: CoordinatorDependencies, config: CoordinatorConfig = CoordinatorConfig()) {
        self.deps = dependencies
        self.config = config
    }

    var status: CoordinatorStatus { lock.lock(); defer { lock.unlock() }; return _status }
    var trace: [CoordinatorTraceEntry] { lock.lock(); defer { lock.unlock() }; return _trace }
    var isBusy: Bool { lock.lock(); defer { lock.unlock() }; return active != nil }
    var hasPending: Bool { lock.lock(); defer { lock.unlock() }; return pending != nil }

    // MARK: - ToolExecuting surface

    func execute(_ call: ToolCall) async throws {
        record("request", call.toolName)
        switch call {
        case .stop:
            stopAll()
        case .say(let text):
            deps.speaker.say(text)
        case .markWaypoint(let name):
            markWaypoint(name)
        case .explore(let minutes):
            try await submit(makeRequest(.explore, "explore", { [deps] in try await deps.explorer.explore(maxMinutes: minutes) },
                                         { [deps] in deps.explorer.cancel() }))
        case .findObject(let description):
            try await submit(makeRequest(.find, "find: \(description)", { [deps] in try await deps.finder.find(description: description) },
                                         { [deps] in deps.finder.cancel() }))
        case .comeToMe:
            try await submit(makeRequest(.comeToMe, "come to me", { [deps] in try await deps.comer.comeToMe() },
                                         { [deps] in deps.comer.cancel() }))
        case .goToWaypoint(let name):
            guard let wp = deps.waypoints.lookup(name) else {
                record("rejected", "unknown waypoint \(name)")
                deps.speaker.say("I don't know a place called \(name).")
                return
            }
            try await submit(makeRequest(.goToWaypoint, "go to: \(wp.name)", { [deps] in try await deps.navigator.goTo(wp) },
                                         { [deps] in deps.navigator.cancel() }))
        case .checkRoute, .startPatrol, .whatChanged:
            record("unsupported", call.toolName)
            deps.speaker.say("I can't do that yet.")
        }
    }

    /// Stop always wins. Synchronous. Safe with nothing running.
    func stopAll() {
        deps.drive.stop()
        lock.lock()
        let victim = active
        let hadPending = pending != nil
        active = nil
        pending = nil
        lock.unlock()
        victim?.monitor?.cancel()
        victim?.cancel()
        record("stop", "cancelled \(victim?.label ?? "nothing")\(hadPending ? ", dropped pending" : "")")
        publish(.idle)
    }

    // MARK: - Internals

    private func makeRequest(_ kind: CoordinatorTaskKind, _ label: String,
                             _ run: @escaping () async throws -> CoordinatorTaskResult,
                             _ cancel: @escaping () -> Void) -> Request {
        Request(kind: kind, label: label, run: run, cancel: cancel)
    }

    private func state(for kind: CoordinatorTaskKind) -> CoordinatorState {
        switch kind {
        case .explore: return .exploring
        case .find, .goToWaypoint: return .finding
        case .comeToMe: return .comingToUser
        }
    }

    private func submit(_ req: Request) async throws {
        lock.lock()
        if active == nil {
            active = req
            lock.unlock()
            try await runActive(req)
        } else if pending == nil {
            pending = req
            let current = active?.label ?? "a task"
            lock.unlock()
            record("queued", "\(req.label) behind \(current)")
            deps.speaker.say("I'm busy with \(current). I'll do that next.")
        } else {
            let current = active?.label ?? "a task"
            lock.unlock()
            record("refused", "\(req.label): busy with \(current) and one already waiting")
            deps.speaker.say("I'm busy and already have something waiting. Say stop first.")
        }
    }

    private func markWaypoint(_ name: String) {
        lock.lock(); let busy = active; lock.unlock()
        if let busy {
            record("refused", "mark \(name): busy with \(busy.label)")
            deps.speaker.say("I'm moving right now. Stop me first, then I can save this spot.")
            return
        }
        guard deps.pose.tracking() == .normal else {
            record("refused", "mark \(name): tracking not normal")
            deps.speaker.say("I can't save a spot until I know where I am. I need a rescan.")
            return
        }
        do {
            let wp = try deps.waypoints.markHere(name: name)
            record("marked", wp.name)
            deps.speaker.say("Saved this spot as \(wp.name).")
        } catch {
            record("error", "mark \(name): \(error)")
            deps.speaker.say("I couldn't save that spot.")
        }
    }

    private func runActive(_ req: Request) async throws {
        publish(CoordinatorStatus(state: state(for: req.kind), task: req.label))
        record("start", req.label)

        guard deps.pose.tracking() == .normal else {
            finishBlocked(req, reason: CoordinatorConfig.rescanReason, speak: "I can't start, I need a rescan.")
            return
        }
        req.monitor = Task { [weak self] in await self?.watchTracking(req) }

        let outcome: Result<CoordinatorTaskResult, Error>
        do { outcome = .success(try await req.run()) } catch { outcome = .failure(error) }
        req.monitor?.cancel()

        // Stopped or tracking-lost while running: that path already released the slot and published.
        lock.lock()
        guard active === req else { lock.unlock(); record("late-return", req.label); return }
        active = nil
        let next = pending
        pending = nil
        lock.unlock()

        switch outcome {
        case .success(.completed(let summary)):
            record("done", "\(req.label)\(summary.map { ": \($0)" } ?? "")")
            publish(.idle)
            startPending(next)
        case .success(.cancelled):
            record("cancelled", req.label)
            publish(.idle)
            startPending(next)
        case .success(.blocked(let reason)):
            record("blocked", "\(req.label): \(reason)")
            publish(CoordinatorStatus(state: .blocked, task: reason))
            deps.speaker.say("I'm stuck: \(reason).")
            startPending(next)
        case .failure(let error):
            record("error", "\(req.label): \(error)")
            publish(CoordinatorStatus(state: .error, task: "\(req.label) failed"))
            deps.speaker.say("Something went wrong with \(req.label).")
            startPending(next)
            throw error
        }
    }

    private func finishBlocked(_ req: Request, reason: String, speak: String) {
        lock.lock()
        guard active === req else { lock.unlock(); return }
        active = nil
        let next = pending
        pending = nil
        lock.unlock()
        record("blocked", "\(req.label): \(reason)")
        publish(CoordinatorStatus(state: .blocked, task: reason))
        deps.speaker.say(speak)
        startPending(next)
    }

    private func startPending(_ next: Request?) {
        guard let next else { return }
        lock.lock()
        guard active == nil else { lock.unlock(); return }
        active = next
        lock.unlock()
        Task { [weak self] in try? await self?.runActive(next) }
    }

    private func watchTracking(_ req: Request) async {
        var lostSince: TimeInterval?
        while !Task.isCancelled {
            do { try await deps.clock.sleep(seconds: config.trackingPollS) } catch { return }
            if Task.isCancelled { return }
            if deps.pose.tracking() == .normal { lostSince = nil; continue }
            let now = deps.clock.now()
            if lostSince == nil { lostSince = now }
            if now - (lostSince ?? now) > config.trackingLossLimitS {
                trackingLost(req)
                return
            }
        }
    }

    private func trackingLost(_ req: Request) {
        deps.drive.stop()
        lock.lock()
        guard active === req else { lock.unlock(); return }
        active = nil
        pending = nil   // motion is unsafe without tracking; do not auto-start queued work
        lock.unlock()
        req.cancel()
        record("tracking-lost", "cancelled \(req.label)")
        publish(CoordinatorStatus(state: .blocked, task: CoordinatorConfig.rescanReason))
        deps.speaker.say("I lost track of where I am. I need a rescan.")
    }

    private func publish(_ s: CoordinatorStatus) {
        lock.lock()
        let changed = _status != s
        _status = s
        lock.unlock()
        if changed { onChange(s) }
    }

    private func record(_ event: String, _ detail: String) {
        let t = deps.clock.now()
        lock.lock(); _trace.append(CoordinatorTraceEntry(t: t, event: event, detail: detail)); lock.unlock()
    }
}
