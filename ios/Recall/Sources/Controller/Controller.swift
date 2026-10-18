import Foundation
#if canImport(PoseCore)
import PoseCore
#endif

// Thin driver around ControlSession: polls a pose source at 10 Hz and writes to a drive sink.
// Sources and sinks are protocols so tests can use fakes; the real adapters are in ControllerAdapters.swift.

protocol PoseSource {
    /// Latest published pose and tracking state. `pose` is nil when tracking is unavailable.
    func latest() -> (pose: Pose2D?, tracking: TrackingKind)
}

protocol DriveSink {
    func drive(left: Int, right: Int)
    func stop()
}

final class Controller {
    private let poses: PoseSource
    private let sink: DriveSink
    private let guardState: () -> GuardState
    private let turnGuard: (() -> GuardState)?
    private let clock: () -> Double
    private let sleep: (Double) async -> Void
    private let stopLock = NSLock()
    private var stopGeneration: UInt64 = 0

    /// Monotonic count of stop() calls. Thread-safe. A run ends as soon as this differs from the value it saw
    /// when it started, so a stop that lands at any point after a run was entered always wins and nothing resets it.
    var stopEpoch: UInt64 { stopLock.lock(); defer { stopLock.unlock() }; return stopGeneration }

    /// `clock` returns seconds (monotonic); `sleep` waits that many seconds. Both are injectable for tests.
    /// `turnGuard`: when set, rotateBy obeys it instead of `guardState` (see TickInput.turnGuardState).
    init(poses: PoseSource, sink: DriveSink,
         guardState: @escaping () -> GuardState = { .clear },
         turnGuard: (() -> GuardState)? = nil,
         clock: @escaping () -> Double = { ProcessInfo.processInfo.systemUptime },
         sleep: @escaping (Double) async -> Void = { try? await Task.sleep(nanoseconds: UInt64($0 * 1_000_000_000)) }) {
        self.poses = poses; self.sink = sink; self.guardState = guardState; self.turnGuard = turnGuard
        self.clock = clock; self.sleep = sleep
    }

    /// Ends the current goTo/rotateBy at the next tick (also on task cancellation). Sends STOP immediately.
    func stop() {
        stopLock.lock(); stopGeneration &+= 1; stopLock.unlock()
        sink.stop()
    }

    /// `since`: the `stopEpoch` the caller read before it could have been told to stop; a stop issued after that
    /// (even before this call begins) cancels the run. Defaults to the epoch at entry.
    func goTo(x: Double, z: Double, stopDistance: Double, since: UInt64? = nil) async -> ControlStatus {
        await run(ControlSession(goal: .goTo(x: x, z: z, stopDistance: stopDistance)), since: since)
    }

    func rotateBy(_ deg: Double, since: UInt64? = nil) async -> ControlStatus {
        await run(ControlSession(goal: .rotateBy(deg: deg)), since: since)
    }

    /// What the last finished goTo/rotateBy did, for failure messages ("timeout: held by the guard 80%..."). Diagnostic
    /// only; nothing decides on it.
    var lastRun: ControlRunStats { stopLock.lock(); defer { stopLock.unlock() }; return lastStats }
    private var lastStats = ControlRunStats()

    private func run(_ initial: ControlSession, since: UInt64?) async -> ControlStatus {
        var session = initial
        var stats = ControlRunStats()
        let startEpoch = since ?? stopEpoch
        defer {
            sink.stop()                              // every exit path leaves the rover stopped
            stats.detours = session.detoursUsed
            stopLock.lock(); lastStats = stats; stopLock.unlock()
        }
        while true {
            if stopEpoch != startEpoch || Task.isCancelled { return .failed(.cancelled) }
            let s = poses.latest()
            let input = TickInput(pose: s.pose, tracking: s.tracking, guardState: guardState(), now: clock(),
                                  turnGuardState: turnGuard?())
            let out = session.tick(input)
            stats.record(input: input, command: out.command, goal: session.goal)
            if out.status != .running { return out.status }
            sink.drive(left: out.command.left, right: out.command.right)
            await sleep(1.0 / ControllerTuning.tickHz)
        }
    }
}

/// Tick counts of one control run. `summary` is a short human-readable line for traces.
struct ControlRunStats: Equatable {
    var ticks = 0
    var forwardGuardStop = 0
    var turnGuardStop = 0
    var trackingBad = 0
    var zeroCommand = 0
    var turning = 0
    var forward = 0
    var startDistM: Double?
    var closestDistM: Double?
    var lastDistM: Double?
    var detours = 0

    mutating func record(input: TickInput, command: WheelCommand, goal: ControlSession.Goal) {
        ticks += 1
        if input.guardState == .stop { forwardGuardStop += 1 }
        if input.turnGuardState == .stop { turnGuardStop += 1 }
        if input.tracking != .normal || input.pose == nil { trackingBad += 1 }
        if command == .zero { zeroCommand += 1 }
        else if (command.left < 0) != (command.right < 0) { turning += 1 }
        else if command.left > 0 && command.right > 0 { forward += 1 }
        if case .goTo(let x, let z, _) = goal, let p = input.pose {
            let d = ControllerMath.distance(pose: p, targetX: x, targetZ: z)
            if startDistM == nil { startDistM = d }
            closestDistM = min(closestDistM ?? d, d)
            lastDistM = d
        }
    }

    var summary: String {
        guard ticks > 0 else { return "no ticks" }
        func pct(_ n: Int) -> String { "\(Int((Double(n) / Double(ticks) * 100).rounded()))%" }
        var parts = ["\(ticks) ticks", "wheels zero \(pct(zeroCommand))", "turning \(pct(turning))", "forward \(pct(forward))",
                     "fwd guard stop \(pct(forwardGuardStop))"]
        if turnGuardStop > 0 { parts.append("turn guard stop \(pct(turnGuardStop))") }
        if trackingBad > 0 { parts.append("tracking bad \(pct(trackingBad))") }
        if detours > 0 { parts.append("detours \(detours)") }
        if let s = startDistM, let c = closestDistM, let l = lastDistM {
            parts.append(String(format: "dist %.2f→%.2f m (closest %.2f)", s, l, c))
        }
        return parts.joined(separator: ", ")
    }
}
