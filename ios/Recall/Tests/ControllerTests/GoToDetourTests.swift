import XCTest
#if canImport(ControllerCore)
@testable import ControllerCore
#endif
#if canImport(PoseCore)
@testable import PoseCore
#endif

/// A go-to held by the forward guard used to freeze until the guard cleared or the run timed out (seen on the rover:
/// 19 s still, front sonar no echo). With the turn guard clear it now detours: turn, drive out a little, re-aim.
final class GoToDetourTests: XCTestCase {
    /// A round obstacle the forward guard sees when it is inside the corridor ahead (stop < 0.35 m), like LiDAR.
    private struct Obstacle {
        var x: Double, z: Double, r: Double
        func forwardStop(_ p: Pose2D) -> Bool {
            let yaw = p.yawDeg * .pi / 180
            let fx = -sin(yaw), fz = -cos(yaw)                    // heading unit vector (yaw 0 faces -z)
            let dx = x - p.x, dz = z - p.z
            let ahead = dx * fx + dz * fz                          // along the heading
            let side = abs(dx * fz - dz * fx)                      // across it
            return ahead > 0 && ahead - r < 0.35 && side < r + 0.18
        }
    }

    private func dist(_ p: Pose2D, _ x: Double, _ z: Double) -> Double { ((p.x - x) * (p.x - x) + (p.z - z) * (p.z - z)).squareRoot() }

    func testDetoursAroundAnObstacleTheForwardGuardSees() async {
        let box = Obstacle(x: 0, z: -1.2, r: 0.2)
        for start in [0.0, 5.0, -5.0] {
            let sim = SimRover(x: 0, z: 0, yawDeg: start)
            let c = Controller(poses: sim, sink: sim,
                               guardState: { box.forwardStop(sim.pose) ? .stop : .clear },
                               turnGuard: { .clear },
                               clock: { sim.time }, sleep: { sim.advance($0) })
            let status = await c.goTo(x: 0, z: -2.5, stopDistance: 0.3)
            XCTAssertEqual(status, .done, "start yaw \(start): \(c.lastRun.summary)")
            XCTAssertLessThan(dist(sim.pose, 0, -2.5), 0.3 + ControllerTuning.passedGoalSlackM + 0.05)
            XCTAssertTrue(c.lastRun.summary.contains("detours"), c.lastRun.summary)
        }
    }

    func testNoDetourWithoutAClearTurnGuard() {
        // Stale readings, missing sonar or a close-range flag hold the turn guard: stay still, exactly as before.
        var s = ControlSession(goal: .goTo(x: 0, z: -3, stopDistance: 0.3))
        let p = Pose2D(x: 0, z: 0, yawDeg: 0)
        for i in 0..<100 {
            let out = s.tick(TickInput(pose: p, tracking: .normal, guardState: .stop, now: Double(i) * 0.1, turnGuardState: .stop))
            XCTAssertEqual(out.command, .zero, "tick \(i)")
        }
        var noTurnGuard = ControlSession(goal: .goTo(x: 0, z: -3, stopDistance: 0.3))
        for i in 0..<100 {
            let out = noTurnGuard.tick(TickInput(pose: p, tracking: .normal, guardState: .stop, now: Double(i) * 0.1))
            XCTAssertEqual(out.command, .zero, "no turn guard wired, tick \(i)")
        }
    }

    func testDetourWaitsForTheHoldAndThenTurnsInPlace() {
        var s = ControlSession(goal: .goTo(x: 0, z: -3, stopDistance: 0.3))
        let p = Pose2D(x: 0, z: 0, yawDeg: 0)
        func tick(_ t: Double) -> TickOutput {
            s.tick(TickInput(pose: p, tracking: .normal, guardState: .stop, now: t, turnGuardState: .clear))
        }
        for i in 0..<19 { XCTAssertEqual(tick(Double(i) * 0.1).command, .zero, "still holding at \(Double(i) * 0.1) s") }
        var turned = false
        for i in 19..<30 {
            let c = tick(Double(i) * 0.1).command
            if c != .zero { turned = true; XCTAssertTrue((c.left < 0) != (c.right < 0), "detour is a turn in place, got \(c)") }
        }
        XCTAssertTrue(turned, "no detour after the hold")
    }

    func testAtMostThreeDetoursThenHold() async {
        // A wall the guard always sees ahead, whatever the heading: three detours, then hold until the deadline.
        let sim = SimRover(x: 0, z: 0, yawDeg: 0)
        let c = Controller(poses: sim, sink: sim, guardState: { .stop }, turnGuard: { .clear },
                           clock: { sim.time }, sleep: { sim.advance($0) })
        let status = await c.goTo(x: 0, z: -3, stopDistance: 0.3)
        XCTAssertEqual(status, .failed(.timeout))
        XCTAssertTrue(c.lastRun.summary.contains("detours "), c.lastRun.summary)
        XCTAssertLessThan(dist(sim.pose, 0, 0), 0.01, "never drove forward into the guard")
    }
}
