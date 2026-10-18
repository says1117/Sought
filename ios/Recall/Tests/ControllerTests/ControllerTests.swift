import XCTest
#if canImport(ControllerCore)
@testable import ControllerCore
#endif
#if canImport(PoseCore)
@testable import PoseCore
#endif

/// Simulated differential-drive rover that follows the CONTRACT convention (R > L turns left / CCW).
/// Model constants are invented for the test, not measured.
final class SimRover: PoseSource, DriveSink {
    var pose: Pose2D
    var tracking: TrackingKind = .normal
    var frozen = false                 // wheels do nothing (stuck / dead motor)
    var left = 0, right = 0
    var time = 0.0
    var drives = 0, stops = 0
    var lastEventWasStop = false
    let metersPerSecPerUnit = 0.002    // 160 -> 0.32 m/s
    let degPerSecPerUnit = 0.8         // 90 -> 72 deg/s
    let deadband = 60                  // commands smaller than this do not move the rover

    init(x: Double, z: Double, yawDeg: Double) { pose = Pose2D(x: x, z: z, yawDeg: yawDeg) }

    func latest() -> (pose: Pose2D?, tracking: TrackingKind) { (tracking == .normal ? pose : nil, tracking) }
    func drive(left: Int, right: Int) { self.left = left; self.right = right; drives += 1; lastEventWasStop = false }
    func stop() { left = 0; right = 0; stops += 1; lastEventWasStop = true }

    func advance(_ dt: Double) {
        time += dt
        guard !frozen else { return }
        func db(_ v: Int) -> Double { abs(v) < deadband ? 0 : Double(v) }
        let l = db(left), r = db(right)
        let v = (l + r) / 2 * metersPerSecPerUnit
        let w = (r - l) / 2 * degPerSecPerUnit                 // deg/s, CCW positive
        pose.yawDeg = PoseMath.normalizeDegrees(pose.yawDeg + w * dt)
        let yaw = pose.yawDeg * .pi / 180
        pose.x += v * dt * -sin(yaw)                           // yaw 0 faces -z, +90 faces -x
        pose.z += v * dt * -cos(yaw)
    }

    func controller(guardState: @escaping () -> GuardState = { .clear }) -> Controller {
        Controller(poses: self, sink: self, guardState: guardState,
                   clock: { self.time }, sleep: { self.advance($0) })
    }
}

/// Turn-only rover with command lag: a command takes effect `lagTicks` sends later, and turns fast (90 -> 135 deg/s).
final class LaggedRover: PoseSource, DriveSink {
    var yawDeg: Double
    var time = 0.0
    var reversals = 0
    private var queue: [(Int, Int)] = []
    private var applied = (0, 0)
    private var lastDir = 0.0
    let lagTicks = 2
    let degPerSecPerUnit = 1.5
    let deadband = 60

    init(yawDeg: Double) { self.yawDeg = yawDeg }
    func latest() -> (pose: Pose2D?, tracking: TrackingKind) { (Pose2D(x: 0, z: 0, yawDeg: yawDeg), .normal) }
    func drive(left: Int, right: Int) { queue.append((left, right)) }
    func stop() { queue.removeAll(); applied = (0, 0) }
    func resetTurn() { reversals = 0; lastDir = 0 }

    func advance(_ dt: Double) {
        time += dt
        if queue.count > lagTicks { applied = queue.removeFirst() }
        func db(_ v: Int) -> Double { abs(v) < deadband ? 0 : Double(v) }
        let w = (db(applied.1) - db(applied.0)) / 2 * degPerSecPerUnit
        if w != 0 {
            let dir: Double = w > 0 ? 1 : -1
            if lastDir != 0 && dir != lastDir { reversals += 1 }
            lastDir = dir
        }
        yawDeg = PoseMath.normalizeDegrees(yawDeg + w * dt)
    }
}

final class ControllerTests: XCTestCase {
    private func dist(_ p: Pose2D, _ x: Double, _ z: Double) -> Double { ((p.x - x) * (p.x - x) + (p.z - z) * (p.z - z)).squareRoot() }

    // MARK: sign convention

    func testErrSignLeftIsPositive() {
        // Facing -z, a target at -x is on the left.
        let e = ControllerMath.headingError(pose: Pose2D(x: 0, z: 0, yawDeg: 0), targetX: -1, targetZ: -1)
        XCTAssertEqual(e, 45, accuracy: 1e-9)
        let r = ControllerMath.headingError(pose: Pose2D(x: 0, z: 0, yawDeg: 0), targetX: 1, targetZ: -1)
        XCTAssertEqual(r, -45, accuracy: 1e-9)
    }

    func testErrWrapsAcrossPlusMinus180() {
        // Heading 170 (just past straight-back, CCW), target straight back (yaw 180): +10, not -350.
        let e = ControllerMath.headingError(pose: Pose2D(x: 0, z: 0, yawDeg: 170), targetX: 0, targetZ: 1)
        XCTAssertEqual(e, 10, accuracy: 1e-9)
    }

    func testTurnLeftCommandHasLeftSlowerThanRight() {
        let (lin, ang) = ControllerMath.goToStep(errDeg: 45, dist: 2, stopDist: 0.3, guardState: .clear)
        XCTAssertEqual(lin, 0)
        let w = ControllerMath.wheels(linear: lin, angular: ang)
        XCTAssertLessThan(w.left, 0)
        XCTAssertGreaterThan(w.right, 0)
        XCTAssertEqual(w.left, -w.right)          // L = linear - angular, R = linear + angular
    }

    func testTurnRightCommandHasRightSlowerThanLeft() {
        let w = ControllerMath.wheels(linear: 0, angular: ControllerMath.turnCommand(errDeg: -45))
        XCTAssertGreaterThan(w.left, 0)
        XCTAssertLessThan(w.right, 0)
    }

    func testMixMatchesContractAndClamps() {
        XCTAssertEqual(ControllerMath.wheels(linear: 100, angular: 30), WheelCommand(left: 70, right: 130))
        XCTAssertEqual(ControllerMath.wheels(linear: 250, angular: 100), WheelCommand(left: 150, right: 255))
    }

    func testTurnInPlaceThresholdAndMinimumTurn() {
        XCTAssertEqual(ControllerMath.goToStep(errDeg: 21, dist: 2, stopDist: 0.3, guardState: .clear).linear, 0)
        XCTAssertGreaterThan(ControllerMath.goToStep(errDeg: 19, dist: 2, stopDist: 0.3, guardState: .clear).linear, 0)
        // Tiny error still commands at least minTurn so the rover can break away.
        XCTAssertEqual(abs(ControllerMath.turnCommand(errDeg: 21)), ControllerTuning.minTurn)
        XCTAssertEqual(abs(ControllerMath.turnCommand(errDeg: 179)), ControllerTuning.maxTurn)
    }

    func testSlowdownInsideHalfMeterAndGuardSlow() {
        let far = ControllerMath.goToStep(errDeg: 0, dist: 3, stopDist: 0.3, guardState: .clear).linear
        let near = ControllerMath.goToStep(errDeg: 0, dist: 0.45, stopDist: 0.3, guardState: .clear).linear
        let slowed = ControllerMath.goToStep(errDeg: 0, dist: 3, stopDist: 0.3, guardState: .slow).linear
        XCTAssertEqual(far, ControllerTuning.maxLinear)
        XCTAssertLessThanOrEqual(near, ControllerTuning.slowLinear)
        XCTAssertEqual(slowed, ControllerTuning.slowLinear)
        XCTAssertEqual(ControllerMath.goToStep(errDeg: 0, dist: 3, stopDist: 0.3, guardState: .stop).linear, 0)
    }

    // MARK: convergence on the simulated model

    func testConvergesFromSeveralStarts() async {
        let starts: [(x: Double, z: Double, yaw: Double)] = [
            (0, 0, 0), (0, 0, 90), (0, 0, -90), (0, 0, 180), (0.5, -0.5, 135), (-1, 1, 10),
        ]
        let targets: [(x: Double, z: Double)] = [(0, -2), (-1.5, -1), (2, 1), (-0.3, 0.8)]
        for s in starts {
            for t in targets {
                let sim = SimRover(x: s.x, z: s.z, yawDeg: s.yaw)
                let status = await sim.controller().goTo(x: t.x, z: t.z, stopDistance: 0.3)
                XCTAssertEqual(status, .done, "start \(s) target \(t)")
                // Stops at the stop distance: this checks the sim loop, not real-world accuracy.
                XCTAssertLessThan(dist(sim.pose, t.x, t.z), 0.3 + ControllerTuning.doneMargin + 0.05, "start \(s) target \(t)")
                XCTAssertTrue(sim.lastEventWasStop)
                XCTAssertLessThan(sim.time, ControllerTuning.timeout)
            }
        }
    }

    func testGoToLeftTargetFirstTurnsLeft() async {
        let sim = SimRover(x: 0, z: 0, yawDeg: 0)
        var firstCommand: (Int, Int)?
        let c = Controller(poses: sim, sink: sim, clock: { sim.time }, sleep: {
            if firstCommand == nil { firstCommand = (sim.left, sim.right) }
            sim.advance($0)
        })
        _ = await c.goTo(x: -2, z: -2, stopDistance: 0.3)
        XCTAssertLessThan(firstCommand!.0, firstCommand!.1)       // L < R means turning left (CCW)
        XCTAssertGreaterThan(sim.pose.yawDeg, 0)                  // ended facing roughly toward -x/-z, i.e. CCW from 0
    }

    func testRotateByBothDirectionsAndWrap() async {
        for (start, delta) in [(0.0, 90.0), (0.0, -90.0), (170.0, 30.0), (-170.0, -30.0), (0.0, 180.0)] {
            let sim = SimRover(x: 0, z: 0, yawDeg: start)
            let status = await sim.controller().rotateBy(delta)
            XCTAssertEqual(status, .done, "\(start) by \(delta)")
            let err = PoseMath.shortestDelta(from: sim.pose.yawDeg, to: start + delta)
            XCTAssertLessThan(abs(err), ControllerTuning.rotateToleranceDeg + 3, "\(start) by \(delta)")
            XCTAssertEqual(sim.pose.x, 0, accuracy: 1e-9)          // rotates in place
        }
    }

    func testRotateWithLagFinishesInsteadOfHunting() async {
        // Fast turn plus two ticks of command lag, as on the rover: the old 5 deg window overshot and chased.
        let sim = LaggedRover(yawDeg: 0)
        let c = Controller(poses: sim, sink: sim, clock: { sim.time }, sleep: { sim.advance($0) })
        for delta in [90.0, -90.0, 90.0, 90.0] {
            sim.resetTurn()
            let start = sim.yawDeg
            let status = await c.rotateBy(delta)
            XCTAssertEqual(status, .done, "by \(delta)")
            let err = PoseMath.shortestDelta(from: sim.yawDeg, to: start + delta)
            XCTAssertLessThan(abs(err), 35, "by \(delta): overshoot bounded")
            XCTAssertEqual(sim.reversals, 0, "by \(delta): never reversed direction")
        }
    }

    func testRotateFinishesWhenHeadingPassesTarget() {
        var s = ControlSession(goal: .rotateBy(deg: 90))
        func tick(_ t: Double, _ yaw: Double) -> TickOutput {
            s.tick(TickInput(pose: Pose2D(x: 0, z: 0, yawDeg: yaw), tracking: .normal, guardState: .clear, now: t))
        }
        XCTAssertEqual(tick(0, 0).status, .running)
        XCTAssertEqual(tick(0.1, 60).status, .running)
        let o = tick(0.2, 104)                       // jumped 14 deg past the target, outside the 10 deg window
        XCTAssertEqual(o.status, .done)
        XCTAssertEqual(o.command, .zero)
    }

    func testRotateWrapIsNotMistakenForCrossing() {
        // rotate +170: at the start err is +170; a brief -175 reading (wrong way, far from target) is not "passed".
        var s = ControlSession(goal: .rotateBy(deg: 170))
        func tick(_ t: Double, _ yaw: Double) -> TickOutput {
            s.tick(TickInput(pose: Pose2D(x: 0, z: 0, yawDeg: yaw), tracking: .normal, guardState: .clear, now: t))
        }
        XCTAssertEqual(tick(0, 0).status, .running)
        XCTAssertEqual(tick(0.1, -15).status, .running)   // err = 185 -> -175, far from target
    }

    // MARK: done criterion

    func testDoneNeedsThreeConsecutiveTicks() {
        var s = ControlSession(goal: .goTo(x: 0, z: -1, stopDistance: 0.3))
        let at = Pose2D(x: 0, z: -0.72, yawDeg: 0)                 // dist 0.28 < 0.35
        func tick(_ t: Double, _ p: Pose2D) -> TickOutput { s.tick(TickInput(pose: p, tracking: .normal, guardState: .clear, now: t)) }
        XCTAssertEqual(tick(0.0, at).status, .running)
        XCTAssertEqual(tick(0.1, at).status, .running)
        // Drifting back out resets the streak.
        XCTAssertEqual(tick(0.2, Pose2D(x: 0, z: -0.3, yawDeg: 0)).status, .running)
        XCTAssertEqual(tick(0.3, at).status, .running)
        XCTAssertEqual(tick(0.4, at).status, .running)
        XCTAssertEqual(tick(0.5, at).status, .done)
    }

    func testGuardStopHoldsWheelsAtZero() {
        var s = ControlSession(goal: .goTo(x: 0, z: -3, stopDistance: 0.3))
        let o = s.tick(TickInput(pose: Pose2D(x: 0, z: 0, yawDeg: 0), tracking: .normal, guardState: .stop, now: 0))
        XCTAssertEqual(o.command, .zero)
        XCTAssertEqual(o.status, .running)
    }

    func testRunStatsExplainAGuardHeldTimeout() async {
        let sim = SimRover(x: 0, z: 0, yawDeg: 0)
        let c = sim.controller(guardState: { .stop })          // forward guard always stops: goTo can't move
        let status = await c.goTo(x: 0, z: -3, stopDistance: 0.3)
        XCTAssertEqual(status, .failed(.timeout))
        let s = c.lastRun
        XCTAssertEqual(s.forwardGuardStop, s.ticks)
        XCTAssertEqual(s.zeroCommand, s.ticks)
        XCTAssertEqual(s.startDistM ?? 0, 3, accuracy: 1e-6)
        XCTAssertTrue(s.summary.contains("fwd guard stop 100%"), s.summary)
        XCTAssertTrue(s.summary.contains("dist 3.00→3.00 m"), s.summary)
    }

    func testGoToTurnInPlaceUsesTurnGuard() {
        // Target 90 deg to the left: goTo turns in place first. Forward guard stop, turn guard clear -> it turns.
        var s = ControlSession(goal: .goTo(x: -3, z: 0, stopDistance: 0.3))
        let o = s.tick(TickInput(pose: Pose2D(x: 0, z: 0, yawDeg: 0), tracking: .normal, guardState: .stop, now: 0,
                                 turnGuardState: .clear))
        XCTAssertLessThan(o.command.left, 0)
        XCTAssertGreaterThan(o.command.right, 0)
    }

    func testGoToTurnInPlaceHeldByTurnGuard() {
        var s = ControlSession(goal: .goTo(x: -3, z: 0, stopDistance: 0.3))
        let o = s.tick(TickInput(pose: Pose2D(x: 0, z: 0, yawDeg: 0), tracking: .normal, guardState: .clear, now: 0,
                                 turnGuardState: .stop))
        XCTAssertEqual(o.command, .zero)
    }

    func testGoToForwardStillObeysForwardGuard() {
        // Target straight ahead (err 0): driving forward ignores a clear turn guard and stops on the forward guard.
        var s = ControlSession(goal: .goTo(x: 0, z: -3, stopDistance: 0.3))
        let o = s.tick(TickInput(pose: Pose2D(x: 0, z: 0, yawDeg: 0), tracking: .normal, guardState: .stop, now: 0,
                                 turnGuardState: .clear))
        XCTAssertEqual(o.command, .zero)
    }

    func testGoToTurnWithoutTurnGuardObeysForwardGuard() {
        var s = ControlSession(goal: .goTo(x: -3, z: 0, stopDistance: 0.3))
        let o = s.tick(TickInput(pose: Pose2D(x: 0, z: 0, yawDeg: 0), tracking: .normal, guardState: .stop, now: 0))
        XCTAssertEqual(o.command, .zero)
    }

    func testRotateObeysGuardStopWithoutTurnGuard() {
        var s = ControlSession(goal: .rotateBy(deg: 90))
        let o = s.tick(TickInput(pose: Pose2D(x: 0, z: 0, yawDeg: 0), tracking: .normal, guardState: .stop, now: 0))
        XCTAssertEqual(o.command, .zero)
    }

    func testTurnGuardClearLetsRotateTurnPastForwardStop() {
        var s = ControlSession(goal: .rotateBy(deg: 90))
        let o = s.tick(TickInput(pose: Pose2D(x: 0, z: 0, yawDeg: 0), tracking: .normal, guardState: .stop, now: 0,
                                 turnGuardState: .clear))
        XCTAssertLessThan(o.command.left, 0)       // left turn: left wheel back, right forward
        XCTAssertGreaterThan(o.command.right, 0)
    }

    func testTurnGuardStopHoldsRotateEvenWhenForwardClear() {
        var s = ControlSession(goal: .rotateBy(deg: 90))
        let o = s.tick(TickInput(pose: Pose2D(x: 0, z: 0, yawDeg: 0), tracking: .normal, guardState: .clear, now: 0,
                                 turnGuardState: .stop))
        XCTAssertEqual(o.command, .zero)
    }

    func testTurnGuardDoesNotAffectGoTo() {
        var s = ControlSession(goal: .goTo(x: 0, z: -3, stopDistance: 0.3))
        let o = s.tick(TickInput(pose: Pose2D(x: 0, z: 0, yawDeg: 0), tracking: .normal, guardState: .stop, now: 0,
                                 turnGuardState: .clear))
        XCTAssertEqual(o.command, .zero)
    }

    func testControllerRotateCompletesWithForwardStopWhenTurnGuardClear() async {
        let sim = SimRover(x: 0, z: 0, yawDeg: 0)
        let c = Controller(poses: sim, sink: sim, guardState: { .stop }, turnGuard: { .clear },
                           clock: { sim.time }, sleep: { sim.advance($0) })
        let status = await c.rotateBy(90)
        XCTAssertEqual(status, .done)
    }

    // MARK: failure paths

    func testDistanceBudgetIsBoundedAndFinite() {
        XCTAssertEqual(ControllerMath.goToTimeout(distance: 0.5, stopDistance: 0.3), 30)
        XCTAssertEqual(ControllerMath.goToTimeout(distance: 4, stopDistance: 0.3), 59.4, accuracy: 1e-9)
        for distance in [100.0, Double.greatestFiniteMagnitude, .infinity, .nan] {
            let budget = ControllerMath.goToTimeout(distance: distance, stopDistance: 0.3)
            XCTAssertTrue(budget.isFinite)
            XCTAssertGreaterThanOrEqual(budget, 30)
            XCTAssertLessThanOrEqual(budget, 75)
        }
    }

    func testSlowSyntheticTraversalCompletesAfterThirtySeconds() {
        // Invented 0.1 m/s trajectory: this checks the deadline, not rover performance.
        var session = ControlSession(goal: .goTo(x: 0, z: -4, stopDistance: 0.3))
        for tick in 0...364 {
            let t = Double(tick) / 10
            let output = session.tick(TickInput(pose: Pose2D(x: 0, z: -t * 0.1, yawDeg: 0),
                                                tracking: .normal, guardState: .clear, now: t))
            XCTAssertEqual(output.status, .running)
        }
        for t in [36.6, 36.7] {
            XCTAssertEqual(session.tick(TickInput(pose: Pose2D(x: 0, z: -3.7, yawDeg: 0),
                                                 tracking: .normal, guardState: .clear, now: t)).status, .running)
        }
        let done = session.tick(TickInput(pose: Pose2D(x: 0, z: -3.7, yawDeg: 0),
                                         tracking: .normal, guardState: .clear, now: 36.8))
        XCTAssertEqual(done.status, .done)
        XCTAssertEqual(done.command, .zero)
    }

    func testBudgetUsesFirstValidPoseAndNeverRenews() {
        var session = ControlSession(goal: .goTo(x: 0, z: -4, stopDistance: 0.3))
        func tick(_ time: Double, _ z: Double?, _ tracking: TrackingKind = .normal) -> TickOutput {
            session.tick(TickInput(pose: z.map { Pose2D(x: 0, z: $0, yawDeg: 0) },
                                   tracking: tracking, guardState: .stop, now: time))
        }
        XCTAssertEqual(tick(0, nil, .limited).command, .zero)
        XCTAssertEqual(tick(0.5, 0).status, .running) // budget 59.4 s, clock still starts at 0
        XCTAssertEqual(tick(30, -3).status, .running) // progress cannot shrink the budget
        XCTAssertEqual(tick(58.8, nil, .limited).command, .zero)
        XCTAssertEqual(tick(59.3, 10).status, .running) // recovery / greater distance cannot renew it
        let failed = tick(59.5, 10)
        XCTAssertEqual(failed.status, .failed(.timeout))
        XCTAssertEqual(failed.command, .zero)
    }

    func testNonfinitePoseWaitsForValidPoseWithoutDriving() {
        var session = ControlSession(goal: .goTo(x: 0, z: -4, stopDistance: 0.3))
        let invalid = session.tick(TickInput(pose: Pose2D(x: .nan, z: 0, yawDeg: 0),
                                            tracking: .normal, guardState: .clear, now: 0))
        XCTAssertEqual(invalid.command, .zero)
        XCTAssertEqual(invalid.status, .running)
        XCTAssertEqual(session.tick(TickInput(pose: Pose2D(x: 0, z: 0, yawDeg: 0),
                                              tracking: .normal, guardState: .stop, now: 0.5)).status, .running)
        XCTAssertEqual(session.tick(TickInput(pose: Pose2D(x: 0, z: 0, yawDeg: 0),
                                              tracking: .normal, guardState: .stop, now: 40)).status, .running)
    }

    func testGuardHeldLongJourneyStillTimesOutAtHardCap() {
        var session = ControlSession(goal: .goTo(x: 0, z: -100, stopDistance: 0.3))
        for t in [0.0, 30, 74.9] {
            let output = session.tick(TickInput(pose: Pose2D(x: 0, z: 0, yawDeg: 0),
                                                tracking: .normal, guardState: .stop, now: t))
            XCTAssertEqual(output.status, .running)
            XCTAssertEqual(output.command, .zero)
        }
        XCTAssertEqual(session.tick(TickInput(pose: Pose2D(x: 0, z: 0, yawDeg: 0),
                                              tracking: .normal, guardState: .stop, now: 75.1)).status, .failed(.timeout))
    }

    func testRotationRetainsFifteenSecondTimeout() async {
        let sim = SimRover(x: 0, z: 0, yawDeg: 0)
        sim.frozen = true
        let status = await sim.controller().rotateBy(90)
        XCTAssertEqual(status, .failed(.timeout))
        XCTAssertGreaterThan(sim.time, ControllerTuning.rotateTimeout)
        XCTAssertLessThan(sim.time, ControllerTuning.rotateTimeout + 0.5)
        XCTAssertTrue(sim.lastEventWasStop)
    }

    func testStuckJourneyTimesOutAtFixedDistanceBudget() async {
        let sim = SimRover(x: 0, z: 0, yawDeg: 0)
        sim.frozen = true
        let status = await sim.controller().goTo(x: 0, z: -3, stopDistance: 0.3)
        XCTAssertEqual(status, .failed(.timeout))
        let budget = ControllerMath.goToTimeout(distance: 3, stopDistance: 0.3)
        XCTAssertGreaterThan(sim.time, budget)
        XCTAssertLessThan(sim.time, budget + 0.5)
        XCTAssertTrue(sim.lastEventWasStop)
    }

    func testTrackingLossLongerThanOneSecondStops() async {
        let sim = SimRover(x: 0, z: 0, yawDeg: 0)
        let c = Controller(poses: sim, sink: sim, clock: { sim.time }, sleep: {
            sim.advance($0)
            if sim.time > 1.0 { sim.tracking = .limited }
        })
        let status = await c.goTo(x: 0, z: -5, stopDistance: 0.3)
        XCTAssertEqual(status, .failed(.trackingLost))
        XCTAssertGreaterThan(sim.time, 2.0)
        XCTAssertLessThan(sim.time, 2.4)
        XCTAssertTrue(sim.lastEventWasStop)
    }

    func testBriefTrackingLossStillCompletes() async {
        let sim = SimRover(x: 0, z: 0, yawDeg: 0)
        let c = Controller(poses: sim, sink: sim, clock: { sim.time }, sleep: {
            sim.advance($0)
            sim.tracking = (sim.time > 1.0 && sim.time < 1.55) ? .limited : .normal   // 0.5 s dropout, under the 1 s limit
        })
        let status = await c.goTo(x: 0, z: -2, stopDistance: 0.3)
        XCTAssertEqual(status, .done)
    }

    func testTrackingLossTickCommandsZeroImmediately() {
        var s = ControlSession(goal: .goTo(x: 0, z: -3, stopDistance: 0.3))
        _ = s.tick(TickInput(pose: Pose2D(x: 0, z: 0, yawDeg: 0), tracking: .normal, guardState: .clear, now: 0))
        let o = s.tick(TickInput(pose: nil, tracking: .notAvailable, guardState: .clear, now: 0.1))
        XCTAssertEqual(o.command, .zero)
        XCTAssertEqual(o.status, .running)
        XCTAssertEqual(s.tick(TickInput(pose: nil, tracking: .limited, guardState: .clear, now: 1.1)).status, .running)   // exactly 1.0 s: not yet
        XCTAssertEqual(s.tick(TickInput(pose: nil, tracking: .limited, guardState: .clear, now: 1.2)).status, .failed(.trackingLost))
    }

    func testStopRequestEndsRunWithStop() async {
        let sim = SimRover(x: 0, z: 0, yawDeg: 0)
        var ctl: Controller!
        ctl = Controller(poses: sim, sink: sim, clock: { sim.time }, sleep: { sim.advance($0); if sim.time > 0.5 { ctl.stop() } })
        let status = await ctl.goTo(x: 0, z: -5, stopDistance: 0.3)
        XCTAssertEqual(status, .failed(.cancelled))
        XCTAssertTrue(sim.lastEventWasStop)
    }

    // PR 33 re-review finding 2: the stop flag was a plain Bool, written by stop() on one thread while run()
    // reset and read it on another, and run() cleared a stop that arrived just before it began.
    func testStopRequestedAfterEpochReadButBeforeRunBeginsWins() async {
        let rover = SimRover(x: 0, z: 0, yawDeg: 0)
        let c = rover.controller()
        let epoch = c.stopEpoch
        c.stop()                                              // lands before run() starts
        let status = await c.goTo(x: 0, z: -3, stopDistance: 0.1, since: epoch)
        XCTAssertEqual(status, .failed(.cancelled))
        XCTAssertEqual(rover.drives, 0, "never drove")
    }

    func testStopEpochIsMonotonicAndLaterRunsStillWork() async {
        let rover = SimRover(x: 0, z: 0, yawDeg: 0)
        let c = rover.controller()
        let e0 = c.stopEpoch
        c.stop(); c.stop()
        XCTAssertEqual(c.stopEpoch, e0 + 2)
        let status = await c.goTo(x: 0, z: -0.5, stopDistance: 0.1)   // fresh run after an old stop is not poisoned
        XCTAssertEqual(status, .done)
    }

    /// Run under `swift test --sanitize=thread`: stop() from many threads while runs start and finish.
    func testConcurrentStopAndRunHaveNoDataRace() async {
        let ticks = ControllerRaceClock()
        let c = Controller(poses: ControllerRaceBox(), sink: ControllerRaceBox(),
                           clock: { ticks.next() }, sleep: { _ in await Task.yield() })
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<4 {
                group.addTask { for _ in 0..<200 { c.stop(); _ = c.stopEpoch } }
                group.addTask { for _ in 0..<50 { _ = await c.rotateBy(10) } }
            }
        }
    }
}

/// Pose that never moves and a sink that discards commands: only the stop flag is exercised.
final class ControllerRaceBox: PoseSource, DriveSink {
    func latest() -> (pose: Pose2D?, tracking: TrackingKind) { (Pose2D(x: 0, z: 0, yawDeg: 0), .normal) }
    func drive(left: Int, right: Int) {}
    func stop() {}
}

/// Monotonic fake clock that moves on every read so runs always time out.
final class ControllerRaceClock {
    private let lock = NSLock()
    private var t = 0.0
    func next() -> Double { lock.lock(); defer { lock.unlock() }; t += 0.1; return t }
}
