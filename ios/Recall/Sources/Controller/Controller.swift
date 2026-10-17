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
    private let clock: () -> Double
    private let sleep: (Double) async -> Void
    private var stopRequested = false

    /// `clock` returns seconds (monotonic); `sleep` waits that many seconds. Both are injectable for tests.
    init(poses: PoseSource, sink: DriveSink,
         guardState: @escaping () -> GuardState = { .clear },
         clock: @escaping () -> Double = { ProcessInfo.processInfo.systemUptime },
         sleep: @escaping (Double) async -> Void = { try? await Task.sleep(nanoseconds: UInt64($0 * 1_000_000_000)) }) {
        self.poses = poses; self.sink = sink; self.guardState = guardState; self.clock = clock; self.sleep = sleep
    }

    /// Ends the current goTo/rotateBy at the next tick (also on task cancellation). Sends STOP immediately.
    func stop() {
        stopRequested = true
        sink.stop()
    }

    func goTo(x: Double, z: Double, stopDistance: Double) async -> ControlStatus {
        await run(ControlSession(goal: .goTo(x: x, z: z, stopDistance: stopDistance)))
    }

    func rotateBy(_ deg: Double) async -> ControlStatus {
        await run(ControlSession(goal: .rotateBy(deg: deg)))
    }

    private func run(_ initial: ControlSession) async -> ControlStatus {
        var session = initial
        stopRequested = false
        defer { sink.stop() }                       // every exit path leaves the rover stopped
        while true {
            if stopRequested || Task.isCancelled { return .failed(.cancelled) }
            let s = poses.latest()
            let out = session.tick(TickInput(pose: s.pose, tracking: s.tracking, guardState: guardState(), now: clock()))
            if out.status != .running { return out.status }
            sink.drive(left: out.command.left, right: out.command.right)
            await sleep(1.0 / ControllerTuning.tickHz)
        }
    }
}
