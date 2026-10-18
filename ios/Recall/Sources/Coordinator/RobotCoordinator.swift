import Foundation
#if canImport(PlannerCore)
@testable import PlannerCore
#endif

/// Runs planner tool calls one at a time. LLM-first control: the planner picks the tool, this class only
/// sequences tasks and makes `stop` win. It never sets speeds or limits; those live in the ESP32 and guards.
///
/// Rules:
/// - Exactly one task (explore, find, go_to_waypoint, come_to_me / come_to_waypoint) runs at a time.
/// - A second task request while one runs is held as the single pending request. If that slot is also full,
///   or the request is mark_waypoint, it is refused with a spoken reason. Never throws for that.
/// - `stopAll()` is synchronous: drive STOP first, cancel the owned task and adapter, clear pending,
///   state idle. The slot stays busy until the cancelled runner returns or the drain timeout releases it.
/// - Each running request holds a `DriveLease` token. Cancelling revokes it, so a runner that ignores
///   cancellation (even after the drain timeout hands the slot to a successor) cannot drive: its commands
///   are dropped at the drive boundary. STOP is never filtered.
/// - A manual tool (Manual drive, Teach, Self-test) takes the lease exclusively via `beginManualControl`;
///   new motion is refused until `endManualControl`.
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
        var worker: Task<Void, Error>?
        var cancelled = false
        var started = false
        var token: UInt64?
        /// Lease epoch right after this request was cancelled; the drain timer may brake only if it is unchanged.
        var cancelEpoch: UInt64?
        var drainWatch: Task<Void, Never>?
        var result: Result<Void, Error>?
        var waiters: [CheckedContinuation<Void, Error>] = []
        init(kind: CoordinatorTaskKind, label: String, run: @escaping () async throws -> CoordinatorTaskResult,
             cancel: @escaping () -> Void) {
            self.kind = kind; self.label = label; self.run = run; self.cancel = cancel
        }
    }

    private let deps: CoordinatorDependencies
    private let config: CoordinatorConfig
    // Lifecycle transitions and synchronous collaborator calls are serialized. Recursive so an
    // onChange callback can call stopAll without deadlocking. Callbacks must never wait on
    // another thread to re-enter the coordinator.
    private let lock = NSRecursiveLock()
    private var active: Request?
    private var pending: Request?
    private var _status = CoordinatorStatus.idle
    private var _trace: [CoordinatorTraceEntry] = []

    /// Synchronous, serialized status notification; may re-enter (e.g. STOP). Keep it brief;
    /// dispatch UI updates asynchronously and never synchronously wait on another thread.
    private var _onChange: (CoordinatorStatus) -> Void = { _ in }
    var onChange: (CoordinatorStatus) -> Void {
        get { synchronized { _onChange } }
        set { synchronized { _onChange = newValue } }
    }

    private func synchronized<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock(); defer { lock.unlock() }; return try body()
    }

    init(dependencies: CoordinatorDependencies, config: CoordinatorConfig = CoordinatorConfig()) {
        self.deps = dependencies
        self.config = config
    }

    var status: CoordinatorStatus { lock.lock(); defer { lock.unlock() }; return _status }
    var trace: [CoordinatorTraceEntry] { lock.lock(); defer { lock.unlock() }; return _trace }
    var isBusy: Bool { lock.lock(); defer { lock.unlock() }; return active != nil }
    var hasPending: Bool { lock.lock(); defer { lock.unlock() }; return pending != nil }
    /// A manual tool (Manual drive, Teach, Self-test) holds the drive; new motion is refused until it closes.
    var manualControlOpen: Bool { deps.lease.manualHeld }

    // MARK: - ToolExecuting surface

    func execute(_ call: ToolCall) async throws {
        // Local STOP must reach the brake before tracing or any lifecycle lock.
        if case .stop = call { stopAll(); return }
        record("request", call.toolName)
        switch call {
        case .stop:
            stopAll()
        case .say(let text):
            deps.speaker.say(text)
        case .markWaypoint(let name):
            markWaypoint(name)
        case .explore(let minutes):
            guard config.features.exploreEnabled else { refuseDisabled("explore", "Sorry, exploring is turned off in this build."); return }
            try await submit(makeRequest(.explore, "explore", { [deps] in try await deps.explorer.explore(maxMinutes: minutes) },
                                         { [deps] in deps.explorer.cancel() }))
        case .findObject(let description):
            try await submit(makeRequest(.find, "find: \(description)", { [deps] in try await deps.finder.find(description: description) },
                                         { [deps] in deps.finder.cancel() }))
        case .comeToMe:
            guard config.features.comeToMeEnabled else { refuseDisabled("come_to_me", "Sorry, coming to you is turned off in this build."); return }
            try await submit(makeRequest(.comeToMe, "come to me", { [deps] in try await deps.comer.comeToMe() },
                                         { [deps] in deps.comer.cancel() }))
        case .comeToWaypoint(let name):
            try await comeToMe(target: .waypointName(name), traced: true)
        case .goToWaypoint(let name):
            guard let wp = deps.waypoints.lookup(name) else {
                record("rejected", "unknown waypoint \(name)")
                deps.speaker.say("I don't know a place called \(name).")
                return
            }
            guard wp.inCurrentFrame || (deps.frame.relocalized && !wp.predatesMap) else {
                record("refused", "go to \(wp.name): saved map not relocalized")
                deps.speaker.say(CoordinatorConfig.notRecognisedSpoken)
                return
            }
            try await submit(makeRequest(.goToWaypoint, "go to: \(wp.name)", { [deps] in try await deps.navigator.goTo(wp) },
                                         { [deps] in deps.navigator.cancel() }))
        case .checkRoute, .startPatrol, .whatChanged:
            record("unsupported", call.toolName)
            deps.speaker.say("I can't do that yet.")
        }
    }

    /// Come to me v2 (T-066): drive to a taught place along the taught routes and stop `config.comeToMe.stopShortM`
    /// short. Also the entry point for the remote command poller (`come_to_me` with a waypoint id). Same lifecycle as
    /// every other task: one at a time, STOP wins, runs under the drive lease, every leg is a guarded Controller.goTo.
    /// Refusals (unknown place, not relocalized, map mismatch, outside the taught area) are spoken and return
    /// normally; the outcome is in `trace` and `status`. Throws only what a runner throws (or caller cancellation).
    func comeToMe(target: ComeToMeTarget) async throws {
        try await comeToMe(target: target, traced: false)
    }

    private func comeToMe(target: ComeToMeTarget, traced: Bool) async throws {
        if !traced { record("request", "come_to_me \(target)") }
        guard config.features.comeToPlaceEnabled else {
            refuseComeToMe("disabled by feature flag", "Sorry, coming to a place is turned off in this build.")
            return
        }
        let all = deps.taught.places()
        let targetPlace: TaughtPlace
        let goal: (x: Double, z: Double, label: String)
        switch target {
        case .waypointId(let id):
            guard let p = all.first(where: { $0.id == id }) else {
                refuseComeToMe("unknown waypoint id \(id)", "I don't know that place."); return
            }
            targetPlace = p; goal = (p.x, p.z, p.name)
        case .waypointName(let name):
            let key = PlannerText.normalizeName(name)
            guard let p = all.first(where: { PlannerText.normalizeName($0.name) == key }) else {
                refuseComeToMe("unknown waypoint \(name)", "I don't know a place called \(name)."); return
            }
            targetPlace = p; goal = (p.x, p.z, p.name)
        case .pose(let x, let z, let mapId):
            guard deps.frame.relocalized else {
                refuseComeToMe("pose: saved map not relocalized", CoordinatorConfig.notRecognisedSpoken); return
            }
            guard deps.frame.activeMapId == mapId else {
                refuseComeToMe("pose: map \(mapId) is not the active map", ComeToPlaceRunner.mapMismatchSpoken); return
            }
            guard let near = all.min(by: { ComeToPlacePlanner.dist($0, (x, z)) < ComeToPlacePlanner.dist($1, (x, z)) }),
                  ComeToPlacePlanner.dist(near, (x, z)) <= config.comeToMe.poseMaxFromPlaceM else {
                refuseComeToMe("pose: outside the taught area", ComeToPlaceRunner.poseOutsideSpoken); return
            }
            targetPlace = near; goal = (x, z, ComeToPlaceRunner.userLabel)
        }
        guard targetPlace.inCurrentFrame || deps.frame.relocalized else {
            refuseComeToMe("\(targetPlace.name): saved map not relocalized", CoordinatorConfig.notRecognisedSpoken); return
        }
        let settings = config.comeToMe
        try await submit(makeRequest(.comeToMe, "come to: \(goal.label)", { [deps] in
            try await ComeToPlaceRunner.run(targetId: targetPlace.id, goal: goal, deps: deps, settings: settings)
        }, { [deps] in deps.legs.cancel() }))
    }

    private func refuseComeToMe(_ why: String, _ spoken: String) {
        record("refused", "come_to_me: \(why)")
        deps.speaker.say(spoken)
    }

    /// Stop always wins. Synchronous. Safe with nothing running.
    func stopAll() {
        // Revoke first so no drive command can follow the brake and leave the heartbeat resending it.
        deps.lease.revoke()
        deps.drive.stop()
        synchronized {
            let victim = active
            let hadPending = pending != nil
            pending = nil
            cancel(victim)
            record("stop", "cancelled \(victim?.label ?? "nothing")\(hadPending ? ", dropped pending" : "")")
            publish(.idle)
        }
    }

    /// Cancellation revokes the worker, but the slot stays occupied until it actually returns.
    /// Adapters must check task cancellation before side effects and after every suspension.
    private func cancel(_ req: Request?) {
        guard let req, !req.cancelled else { return }
        req.cancelled = true
        deps.lease.revoke()
        req.monitor?.cancel()
        req.worker?.cancel()
        if req.started {
            req.cancel()
            req.cancelEpoch = deps.lease.currentEpoch
            let limit = config.drainTimeoutS
            req.drainWatch = Task { [weak self] in
                do { try await self?.deps.clock.sleep(seconds: limit) } catch { return }
                self?.forceComplete(req)
            }
        }
    }

    /// A cancelled runner that never returns must not wedge the coordinator. The drive STOP was already
    /// sent and its lease token revoked when the task was cancelled, so the stale runner can no longer drive;
    /// this releases the slot so new requests are accepted again.
    private func forceComplete(_ req: Request) {
        synchronized {
            guard active === req, req.cancelled else { return }
            // Brake only if nothing took over the link since cancellation; a manual tool or successor owns it now.
            if !deps.lease.manualHeld, req.cancelEpoch == deps.lease.currentEpoch { deps.drive.stop() }
            active = nil
            pending = nil
            record("drain-timeout", "\(req.label) did not return within \(config.drainTimeoutS) s; released")
            if _status.state != .blocked && _status.state != .error { publish(.idle) }
            deps.speaker.say("I stopped, but the last task did not finish cleanly. I'm ready for a new request.")
            finishRequest(req, .success(()))
        }
    }

    /// A manual tool (Manual drive, Teach, Self-test) is opening: cancel motion, brake, revoke the lease, and
    /// refuse new motion until `endManualControl` for the same tool. Idempotent per tool.
    func beginManualControl(_ tool: String) {
        deps.lease.holdManual(tool)   // revokes the current token before the brake below
        stopAll()
        synchronized { record("manual-begin", tool) }
    }

    func endManualControl(_ tool: String) {
        deps.drive.stop()
        deps.lease.releaseManual(tool)
        synchronized { record("manual-end", tool) }
    }

    private func refuseDisabled(_ what: String, _ spoken: String) {
        record("refused", "\(what): disabled by feature flag")
        deps.speaker.say(spoken)
    }

    /// Resolve the request's awaiting caller exactly once (runner returned, or drain timeout).
    private func finishRequest(_ req: Request, _ r: Result<Void, Error>) {
        synchronized {
            guard req.result == nil else { return }
            req.result = r
            req.drainWatch?.cancel()
            let waiters = req.waiters
            req.waiters = []
            for w in waiters { w.resume(with: r) }
        }
    }

    private func awaitCompletion(_ req: Request) async throws {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            synchronized {
                if let r = req.result { c.resume(with: r) } else { req.waiters.append(c) }
            }
        }
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
        try await withTaskCancellationHandler {
            let worker: Task<Void, Error>? = try synchronized {
                try Task.checkCancellation()
                if deps.lease.manualHeld {
                    record("refused", "\(req.label): manual control is open")
                    deps.speaker.say("A manual control screen is open. Close it first, then ask me again.")
                } else if active == nil {
                    return start(req)
                } else if active?.cancelled == true {
                    record("refused", "\(req.label): previous task still stopping")
                    deps.speaker.say("I'm still stopping. Please try again once I've stopped.")
                } else if pending == nil {
                    pending = req
                    let current = active?.label ?? "a task"
                    record("queued", "\(req.label) behind \(current)")
                    deps.speaker.say("I'm busy with \(current). I'll do that next.")
                } else {
                    record("refused", "\(req.label): pending slot full")
                    deps.speaker.say("I'm busy and already have something waiting. Say stop first.")
                }
                return nil
            }
            guard worker != nil else { return }
            try await awaitCompletion(req)
        } onCancel: {
            self.synchronized {
                if self.pending === req {
                    // Cancelled while queued (possibly before submit even returned): drop it.
                    self.pending = nil
                    self.record("cancelled", "\(req.label): caller cancelled while queued")
                    return
                }
                guard self.active === req else { return }
                self.deps.lease.revoke()
                self.deps.drive.stop()
                self.pending = nil
                self.cancel(req)
                self.publish(.idle)
            }
        }
    }

    /// Reserve and create the owned task in the same transition. Called with the lock held.
    private func start(_ req: Request) -> Task<Void, Error> {
        active = req
        let worker = Task<Void, Error> {
            do { try await self.runActive(req); self.finishRequest(req, .success(())) }
            catch { self.finishRequest(req, .failure(error)); throw error }
        }
        req.worker = worker
        return worker
    }

    private func markWaypoint(_ name: String) {
        synchronized { markWaypointLocked(name) }
    }

    private func markWaypointLocked(_ name: String) {
        let busy = active
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
            if deps.waypoints.isPersistent {
                record("marked", wp.name)
                deps.speaker.say("Saved this spot as \(wp.name).")
            } else {
                record("marked-temporary", wp.name)
                deps.speaker.say("Saved this spot as \(wp.name), but only until the app closes. Storage is not working, so it will not be remembered.")
            }
        } catch {
            record("error", "mark \(name): \(error)")
            deps.speaker.say("I couldn't save that spot.")
        }
    }

    private func runActive(_ req: Request) async throws {
        let canRun = synchronized { () -> Bool in
            guard active === req else { return false }
            guard !req.cancelled, !Task.isCancelled else { active = nil; return false }
            guard deps.pose.tracking() == .normal else {
                req.cancelled = true
                pending = nil
                publish(CoordinatorStatus(state: .blocked, task: CoordinatorConfig.rescanReason))
                deps.speaker.say("I can't start, I need a rescan.")
                active = nil
                return false
            }
            guard let token = deps.lease.grant() else {
                pending = nil
                record("refused", "\(req.label): manual control is open")
                deps.speaker.say("A manual control screen is open. Close it first, then ask me again.")
                active = nil
                return false
            }
            req.token = token
            publish(CoordinatorStatus(state: state(for: req.kind), task: req.label))
            // A re-entrant status callback can STOP before the runner has even been called.
            guard !req.cancelled, !Task.isCancelled else { active = nil; return false }
            record("start", req.label)
            req.started = true
            req.monitor = Task { [weak self] in await self?.watchTracking(req) }
            return true
        }
        guard canRun else { return }
        let outcome: Result<CoordinatorTaskResult, Error>
        do {
            try Task.checkCancellation()
            outcome = .success(try await DriveLease.$token.withValue(req.token) { try await req.run() })
        } catch { outcome = .failure(error) }

        let error: Error? = synchronized {
            req.monitor?.cancel()
            deps.lease.revoke(req.token)   // child work still unwinding cannot drive; a successor's token is untouched
            guard active === req else { return nil }
            if req.cancelled {
                active = nil
                record("late-return", req.label)
                return nil
            }
            // No successor can start while the old task or its final STOP is unwinding.
            deps.drive.stop()
            var thrown: Error?
            switch outcome {
            case .success(.completed(let summary)):
                record("done", "\(req.label)\(summary.map { ": \($0)" } ?? "")")
                publish(.idle)
            case .success(.refused(let spoken)):
                record("refused", "\(req.label): \(spoken)")
                publish(.idle)
                deps.speaker.say(spoken)
            case .success(.cancelled):
                pending = nil
                record("cancelled", req.label)
                publish(.idle)
            case .success(.blocked(let reason)):
                pending = nil
                record("blocked", "\(req.label): \(reason)")
                publish(CoordinatorStatus(state: .blocked, task: reason))
                deps.speaker.say("I'm stuck: \(reason).")
            case .failure(let error):
                pending = nil
                record("error", "\(req.label): \(error)")
                publish(CoordinatorStatus(state: .error, task: "\(req.label) failed"))
                deps.speaker.say("Something went wrong with \(req.label).")
                thrown = error
            }
            active = nil
            // STOP from a completion callback clears pending before this reservation.
            if let next = pending, !req.cancelled {
                pending = nil
                let worker = start(next)
                Task { _ = try? await worker.value } // queued errors are published by runActive
            }
            return thrown
        }
        if let error { throw error }
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
        synchronized {
            // A cancelled old monitor must never brake or overwrite a successor's status.
            guard active === req, !req.cancelled else { return }
            deps.lease.revoke()
            deps.drive.stop()
            pending = nil
            cancel(req)
            record("tracking-lost", "cancelled \(req.label)")
            publish(CoordinatorStatus(state: .blocked, task: CoordinatorConfig.rescanReason))
            deps.speaker.say("I lost track of where I am. I need a rescan.")
        }
    }

    /// Called only within a lifecycle transition; callback and stored status share the same order.
    private func publish(_ s: CoordinatorStatus) {
        let changed = _status != s
        _status = s
        if changed { _onChange(s) }
    }

    private func record(_ event: String, _ detail: String) {
        let t = deps.clock.now()
        lock.lock(); _trace.append(CoordinatorTraceEntry(t: t, event: event, detail: detail)); lock.unlock()
    }
}
