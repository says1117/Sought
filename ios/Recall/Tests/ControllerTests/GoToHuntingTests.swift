import XCTest
#if canImport(ControllerCore)
@testable import ControllerCore
#endif
#if canImport(PoseCore)
@testable import PoseCore
#endif

/// Differential-drive rover with command lag and a fast turn, as seen on the robot: a command takes effect `lagTicks`
/// sends later. Counts the micro-adjustments a go-to makes: switches between driving and turning in place, and
/// reversals of the turn direction. Model constants are invented for the test, not measured.
final class LaggedDriveRover: PoseSource, DriveSink {
    var pose: Pose2D
    var time = 0.0
    private var queue: [(Int, Int)] = []
    private var applied = (0, 0)
    let lagTicks = 2
    let metersPerSecPerUnit = 0.002
    let degPerSecPerUnit = 1.5
    let deadband = 60

    /// Turn-in-place episodes (opposite wheel signs) and drive episodes, as commanded.
    private(set) var spinEpisodes = 0
    private(set) var turnReversals = 0
    private var lastMode = ""
    private var lastSpinDir = 0

    init(x: Double, z: Double, yawDeg: Double) { pose = Pose2D(x: x, z: z, yawDeg: yawDeg) }

    func latest() -> (pose: Pose2D?, tracking: TrackingKind) { (pose, .normal) }
    func drive(left: Int, right: Int) {
        queue.append((left, right))
        let spin = (left < 0) != (right < 0) && left != 0 && right != 0
        let mode = spin ? "spin" : (left > 0 && right > 0 ? "drive" : "other")
        if spin {
            if lastMode != "spin" { spinEpisodes += 1 }
            let dir = right > left ? 1 : -1
            if lastSpinDir != 0 && dir != lastSpinDir { turnReversals += 1 }
            lastSpinDir = dir
        }
        lastMode = mode
    }
    func stop() { queue.removeAll(); applied = (0, 0) }

    func advance(_ dt: Double) {
        time += dt
        if queue.count > lagTicks { applied = queue.removeFirst() } else if queue.isEmpty { applied = (0, 0) }
        func db(_ v: Int) -> Double { abs(v) < deadband ? 0 : Double(v) }
        let l = db(applied.0), r = db(applied.1)
        let v = (l + r) / 2 * metersPerSecPerUnit
        let w = (r - l) / 2 * degPerSecPerUnit
        pose.yawDeg = PoseMath.normalizeDegrees(pose.yawDeg + w * dt)
        let yaw = pose.yawDeg * .pi / 180
        pose.x += v * dt * -sin(yaw)
        pose.z += v * dt * -cos(yaw)
    }

    func controller() -> Controller { Controller(poses: self, sink: self, clock: { self.time }, sleep: { self.advance($0) }) }
}

final class GoToHuntingTests: XCTestCase {
    private func dist(_ p: Pose2D, _ x: Double, _ z: Double) -> Double { ((p.x - x) * (p.x - x) + (p.z - z) * (p.z - z)).squareRoot() }

    /// Heading just past the 20 deg turn-in-place line: one turn, then drive. Never chases left-right.
    func testHeadingNearTurnThresholdDoesNotStopAndGo() async {
        for yaw in [22.0, -22.0, 30.0, -30.0, 45.0] {
            let sim = LaggedDriveRover(x: 0, z: 0, yawDeg: yaw)
            let status = await sim.controller().goTo(x: 0, z: -3, stopDistance: 0.3)
            XCTAssertEqual(status, .done, "yaw \(yaw)")
            XCTAssertLessThan(dist(sim.pose, 0, -3), 0.3 + ControllerTuning.passedGoalSlackM + 0.05, "yaw \(yaw)")
            XCTAssertLessThanOrEqual(sim.spinEpisodes, 1, "yaw \(yaw): turned in place more than once")
            XCTAssertEqual(sim.turnReversals, 0, "yaw \(yaw): reversed turn direction")
        }
    }

    /// Close to the goal with the target off to the side: arrive without spinning back and forth.
    func testNearGoalSideOffsetArrivesWithoutHunting() async {
        let cases: [(x: Double, z: Double, yaw: Double)] = [(0.12, 0, 0), (-0.15, 0, 0), (0.2, 0, 10), (0.1, -0.2, -15)]
        for c in cases {
            let sim = LaggedDriveRover(x: c.x, z: c.z, yawDeg: c.yaw)
            let status = await sim.controller().goTo(x: 0, z: -0.6, stopDistance: 0.3)
            XCTAssertEqual(status, .done, "\(c)")
            XCTAssertLessThan(dist(sim.pose, 0, -0.6), 0.3 + ControllerTuning.passedGoalSlackM + 0.05, "\(c)")
            XCTAssertLessThanOrEqual(sim.spinEpisodes, 1, "\(c): turned in place more than once")
            XCTAssertEqual(sim.turnReversals, 0, "\(c): reversed turn direction")
        }
    }

    /// Many starts and targets: always arrives, never reverses a turn, at most one turn-in-place per trip.
    func testNoHuntingFromManyStarts() async {
        var worst = 0, reversals = 0
        for yaw in stride(from: -180.0, to: 180.0, by: 15) {
            for t in [(0.0, -2.0), (1.5, -1.0), (-0.4, -0.7), (2.0, 1.0)] {
                let sim = LaggedDriveRover(x: 0, z: 0, yawDeg: yaw)
                let status = await sim.controller().goTo(x: t.0, z: t.1, stopDistance: 0.3)
                XCTAssertEqual(status, .done, "yaw \(yaw) target \(t)")
                XCTAssertLessThan(dist(sim.pose, t.0, t.1), 0.3 + ControllerTuning.passedGoalSlackM + 0.05, "yaw \(yaw) target \(t)")
                worst = max(worst, sim.spinEpisodes); reversals += sim.turnReversals
            }
        }
        XCTAssertLessThanOrEqual(worst, 1, "some trip turned in place more than once")
        XCTAssertEqual(reversals, 0, "turn direction reversed")
    }
}
