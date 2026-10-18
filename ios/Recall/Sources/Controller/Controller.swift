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

    private func run(_ initial: ControlSession, since: UInt64?) async -> ControlStatus {
        var session = initial
        let startEpoch = since ?? stopEpoch
        defer { sink.stop() }                       // every exit path leaves the rover stopped
        while true {
            if stopEpoch != startEpoch || Task.isCancelled { return .failed(.cancelled) }
            let s = poses.latest()
            let out = session.tick(TickInput(pose: s.pose, tracking: s.tracking, guardState: guardState(), now: clock(),
                                               turnGuardState: turnGuard?()))
            if out.status != .running { return out.status }
            sink.drive(left: out.command.left, right: out.command.right)
            await sleep(1.0 / ControllerTuning.tickHz)
        }
    }
}
