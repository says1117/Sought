import XCTest
import Foundation
#if canImport(SelfTestCore)
@testable import SelfTestCore
#endif
#if canImport(PoseCore)
@testable import PoseCore
#endif

// SIMULATED rover only. Every number here (speeds, latencies, box positions) is invented for the tests and says nothing
// about the real robot. Nothing in this file is a measurement.

/// Fake rover + ESP32 + ObstacleGuard. Follows the contract: angular > 0 turns left, watchdog 300 ms, front < 20 cm clamps forward.
final class SimWorld {
    var pose = Pose2D(x: 0, z: 0, yawDeg: 0)
    var time = 100.0                      // deliberately not 0: the engine must use differences
    var tracking: TrackingKind = .normal
    var connected = true
    var watchdogWorks = true
    var spinSign = 1.0                    // -1 simulates a swapped motor wire (spin direction wrong)
    var deadLeft = false                  // left motor does nothing (firmware reports 0 applied)
    var frozen = false                    // wheels do nothing
    var driftDegPerMeter = 0.0            // simulated sideways drift
    var guardFeed = true
    var statusEnabled = true
    var boxAhead: Double?                 // meters from the rover along its starting heading, nil = no box
    var boxX = 0.0, boxZ = 0.0
    var left = 0, right = 0
    var flagsExtra = 0
    private var lastCmdT = 0.0
    private var lastStatusT = 100.0
    var pending: [TimedStatus] = []
    let mPerSecPerUnit = 0.002, degPerSecPerUnit = 0.8

    var frontCm: Int {
        guard let b = boxAhead else { return 999 }
        let u = SelfTestMetrics.forwardUnit(yawDeg: pose.yawDeg)
        let dx = boxX - pose.x, dz = boxZ - pose.z
        let along = dx * u.x + dz * u.z, side = dx * u.z - dz * u.x
        _ = b
        if along <= 0 || abs(side) > 0.2 { return 999 }
        return max(1, Int((along * 100).rounded()))
    }

    func placeBox(metersAhead m: Double) {
        let u = SelfTestMetrics.forwardUnit(yawDeg: pose.yawDeg)
        boxAhead = m; boxX = pose.x + u.x * m; boxZ = pose.z + u.z * m
    }

    var guardLevel: SelfTestGuardLevel? {
        guard guardFeed else { return nil }
        let f = frontCm
        return f < 35 ? .stop : (f < 60 ? .slow : .clear)
    }

    func apply(_ c: SelfTestCommand) {
        switch c {
        case .drive(let l, let r): left = l; right = r; lastCmdT = time
        case .stop: left = 0; right = 0; lastCmdT = time
        case .silent: break
        }
    }

    func advance(_ dt: Double) {
        time += dt
        var l = Double(left), r = Double(right)
        var wd = false
        if watchdogWorks && time - lastCmdT > 0.3 { l = 0; r = 0; wd = true }
        var lin = (l + r) / 2, ang = (r - l) / 2
        if frontCm < 20 { lin = min(lin, 0) }
        l = lin - ang; r = lin + ang
        if deadLeft { l = 0 }
        appliedL = Int(l.rounded()); appliedR = Int(r.rounded()); watchdogFlag = wd
        if !frozen {
            let yawRate = ang * degPerSecPerUnit * spinSign
            pose.yawDeg = PoseMath.normalizeDegrees(pose.yawDeg + yawRate * dt)
            let v = lin * mPerSecPerUnit
            let yaw = (pose.yawDeg + driftDegPerMeter * 0) * .pi / 180
            pose.x += v * dt * -sin(yaw)
            pose.z += v * dt * -cos(yaw)
            if driftDegPerMeter != 0 { pose.x += abs(v) * dt * driftDegPerMeter * 0.0175 }
        }
        if statusEnabled && time - lastStatusT >= 0.2 - 1e-9 {
            lastStatusT = time
            var flags = (connected ? 8 : 0) | (wd ? 1 : 0) | flagsExtra
            if frontCm < 20 { flags |= 2 }
            pending.append(TimedStatus(t: time, uptimeMs: Int(time * 1000), left: appliedL, right: appliedR,
                                       frontCm: frontCm, rearCm: 999, flags: flags))
        }
    }
    var appliedL = 0, appliedR = 0, watchdogFlag = false
}

struct RunTrace {
    var records: [LogRecord] = []
    var commands: [SelfTestCommand] = []
    var prompts: [String] = []
    var finalState: SelfTestEngine.RunState = .idle
    var seconds = 0.0
}

func runEngine(_ engine: SelfTestEngine, _ w: SimWorld, maxSeconds: Double = 600,
               onPrompt: (String, SimWorld) -> Void = { _, _ in },
               beforeTick: (SimWorld, Double) -> Void = { _, _ in }) -> RunTrace {
    var tr = RunTrace()
    let t0 = w.time
    let start = engine.start(now: w.time, runId: "run_test", startedUTC: "2026-01-01T00:00:00Z", checklistConfirmed: true)
    tr.records += start.records
    var confirm = false
    var suspended = false
    while !engine.state.isTerminal && w.time - t0 < maxSeconds {
        beforeTick(w, w.time - t0)
        let input = SelfTestInput(now: w.time, pose: w.tracking == .normal ? w.pose : nil, tracking: w.tracking,
                                  statuses: w.pending, bleConnected: w.connected, guardLevel: w.guardLevel, confirm: confirm)
        w.pending = []
        confirm = false
        let out = engine.tick(input)
        tr.records += out.records
        tr.commands.append(out.command)
        if out.command == .silent { suspended = true } else { suspended = false }
        _ = suspended
        w.apply(out.command)
        if let p = out.prompt { tr.prompts.append(p); onPrompt(p, w); confirm = true }
        w.advance(0.1)
    }
    tr.finalState = engine.state
    tr.seconds = w.time - t0
    return tr
}

func events(_ tr: RunTrace, _ name: String) -> [LogRecord] {
    tr.records.filter { ($0["type"] as? String) == "event" && ($0["name"] as? String) == name }
}

func stepEnd(_ tr: RunTrace, _ step: String) -> LogRecord? {
    events(tr, "step_end").first { ($0["step"] as? String) == step }
}

final class SelfTestMetricsTests: XCTestCase {
    func testForwardUnitAndSigns() {
        let u0 = SelfTestMetrics.forwardUnit(yawDeg: 0)
        XCTAssertEqual(u0.x, 0, accuracy: 1e-9); XCTAssertEqual(u0.z, -1, accuracy: 1e-9)
        let u90 = SelfTestMetrics.forwardUnit(yawDeg: 90)          // CCW 90 faces -x
        XCTAssertEqual(u90.x, -1, accuracy: 1e-9); XCTAssertEqual(u90.z, 0, accuracy: 1e-9)
        let o = Pose2D(x: 0, z: 0, yawDeg: 0)
        XCTAssertEqual(SelfTestMetrics.alongTrack(origin: o, u: u0, p: Pose2D(x: 0, z: -1, yawDeg: 0)), 1, accuracy: 1e-9)
        // left of a -z heading is -x
        XCTAssertEqual(SelfTestMetrics.lateral(origin: o, u: u0, p: Pose2D(x: -0.2, z: -1, yawDeg: 0)), 0.2, accuracy: 1e-9)
        XCTAssertEqual(SelfTestMetrics.lateral(origin: o, u: u0, p: Pose2D(x: 0.2, z: -1, yawDeg: 0)), -0.2, accuracy: 1e-9)
    }

    func testYawAccumulatorUnwrapsAcrossPlusMinus180() {
        var a = YawAccumulator()
        for y in [170.0, 179, -179, -170, -160] { a.add(yawDeg: y) }
        XCTAssertEqual(a.total, 30, accuracy: 1e-9)
        var b = YawAccumulator()
        for y in stride(from: 0.0, through: 360, by: 30) { b.add(yawDeg: PoseMath.normalizeDegrees(y)) }
        XCTAssertEqual(b.total, 360, accuracy: 1e-9)
    }

    func testStatusRateAndWatchdogLatency() {
        XCTAssertNil(SelfTestMetrics.statusRateHz(times: [1.0]))
        XCTAssertEqual(SelfTestMetrics.statusRateHz(times: [0, 0.2, 0.4, 0.6, 0.8, 1.0])!, 5, accuracy: 1e-9)
        func s(_ t: Double, _ l: Int, _ r: Int, _ f: Int) -> TimedStatus {
            TimedStatus(t: t, uptimeMs: 0, left: l, right: r, frontCm: 999, rearCm: 999, flags: f)
        }
        let list = [s(9.9, 100, 100, 8), s(10.2, 100, 100, 8), s(10.4, 0, 0, 9), s(10.6, 0, 0, 9)]
        XCTAssertEqual(SelfTestMetrics.watchdogStopLatency(suspendT: 10.0, statuses: list)!, 0.4, accuracy: 1e-9)
        XCTAssertEqual(SelfTestMetrics.watchdogFlagLatency(suspendT: 10.0, statuses: list)!, 0.4, accuracy: 1e-9)
        XCTAssertNil(SelfTestMetrics.watchdogStopLatency(suspendT: 11.0, statuses: list))
    }

    func testLogLineIsValidSortedJSONAndRejectsNaN() {
        let line = SelfTestLog.line(["type": "pose", "t": 1.5, "x": 0.25])!
        XCTAssertEqual(line, "{\"t\":1.5,\"type\":\"pose\",\"x\":0.25}")
        XCTAssertNil(SelfTestLog.line(["x": Double.nan]))
    }

    func testTimedStatusDerivedValues() {
        let s = TimedStatus(t: 0, uptimeMs: 0, left: -100, right: 100, frontCm: 999, rearCm: 12, flags: 9)
        XCTAssertEqual(s.linear, 0); XCTAssertEqual(s.angular, 100)
        XCTAssertNil(s.frontDistanceCm)
        XCTAssertTrue(s.watchdogStopped); XCTAssertTrue(s.bleConnected); XCTAssertFalse(s.frontBlocked)
    }
}

final class SelfTestEngineTests: XCTestCase {
    private func engine(_ steps: [SelfTestStepID] = SelfTestStepID.allCases, config: SelfTestConfig = .default) -> SelfTestEngine {
        SelfTestEngine(config: config, steps: steps)
    }

    func testRefusesToStartWithoutChecklist() {
        let e = engine()
        let out = e.start(now: 0, runId: "r", startedUTC: "x", checklistConfirmed: false)
        XCTAssertEqual(out.state, .aborted(.checklistNotConfirmed))
        XCTAssertEqual(out.command, .stop)
        XCTAssertEqual(e.tick(SelfTestInput(now: 1, pose: nil, tracking: .normal, bleConnected: true, guardLevel: nil)).command, .stop)
    }

    func testFullRunOnHealthySimulatedRover() {
        let w = SimWorld()
        // The simulated rover overshoots each 10 Hz turn tick, so the square closes within about 0.25 m, not 0.15 m.
        // This test checks the sequencing and logging plumbing, not accuracy, so the square limit is loosened here only.
        var cfg = SelfTestConfig.default
        cfg.squareFinalErrLimitM = 0.5
        let e = engine(config: cfg)
        let tr = runEngine(e, w, onPrompt: { p, world in
            if p.contains("15 cm") { world.placeBox(metersAhead: 0.15) }
            else if p.contains("1 m in front") { world.placeBox(metersAhead: 1.0) }
            else if p.contains("start mark") { world.boxAhead = nil }
        })
        XCTAssertEqual(tr.finalState, .finished, "\(tr.records.suffix(6))")
        XCTAssertEqual(e.results.count, 6)
        for r in e.results { XCTAssertTrue(r.pass, "\(r.id.logName): \(r.reason)") }
        XCTAssertEqual(events(tr, "run_summary").count, 1)
        XCTAssertEqual(e.trackingIncidents, 0); XCTAssertEqual(e.bleDisconnects, 0)
        // the log has every record type and every line serializes
        for t in ["meta", "pose", "cmd", "status", "event"] { XCTAssertTrue(tr.records.contains { ($0["type"] as? String) == t }, t) }
        for r in tr.records { XCTAssertNotNil(SelfTestLog.line(r), "\(r)") }
        // commands are capped
        for c in tr.commands { if case .drive(let l, let r) = c { XCTAssertLessThanOrEqual(max(abs(l), abs(r)), SelfTestConfig.default.maxPwm) } }
        // metrics exist
        let fb = stepEnd(tr, "forward_back")!["metrics"] as! [String: Double]
        XCTAssertEqual(fb["forward_distance_m"]!, 1.0, accuracy: 0.1)
        XCTAssertLessThan(fb["return_error_m"]!, 0.15)
        let sp = stepEnd(tr, "spin")!["metrics"] as! [String: Double]
        XCTAssertEqual(sp["spin_total_deg"]!, 360, accuracy: 20)
        XCTAssertGreaterThan(sp["spin_time_s"]!, 0)
        let ob = stepEnd(tr, "obstacle")!["metrics"] as! [String: Double]
        XCTAssertGreaterThanOrEqual(ob["min_front_cm"]!, SelfTestConfig.default.contactMarginCm)
    }

    func testCommandsAreCappedEvenIfConfiguredHigher() {
        var cfg = SelfTestConfig.default
        cfg.testPwm = 250
        let w = SimWorld()
        let e = engine([.wheelsOff], config: cfg)
        let tr = runEngine(e, w)
        for c in tr.commands { if case .drive(let l, let r) = c { XCTAssertLessThanOrEqual(max(abs(l), abs(r)), cfg.maxPwm) } }
    }

    func testWatchdogStepFailsWhenMotorsKeepRunningWithoutCommands() {
        let w = SimWorld(); w.watchdogWorks = false
        let e = engine([.watchdog])
        let tr = runEngine(e, w)
        let r = e.results.first!
        XCTAssertFalse(r.pass)
        XCTAssertTrue(r.reason.contains("never read 0"), r.reason)
        XCTAssertTrue(tr.commands.contains(.silent))
        XCTAssertEqual(tr.commands.last, .stop)
        XCTAssertEqual(tr.finalState, .halted("1  Watchdog failed: \(r.reason). Fix this before putting the rover on the floor."))
    }

    func testWatchdogStepPassesAndMeasuresLatency() {
        let w = SimWorld()
        let e = engine([.watchdog])
        _ = runEngine(e, w)
        let r = e.results.first!
        XCTAssertTrue(r.pass, r.reason)
        XCTAssertLessThanOrEqual(r.metrics["stop_latency_s"]!, SelfTestConfig.default.watchdogPassLimitS)
        XCTAssertNotNil(r.metrics["flag_latency_s"]); XCTAssertNotNil(r.metrics["resume_latency_s"])
    }

    func testLowStatusRateFailsStepZero() {
        let w = SimWorld()
        let e = engine([.wheelsOff])
        let tr = runEngine(e, w, beforeTick: { world, _ in world.statusEnabled = Int(world.time * 10) % 4 == 0 })   // about 2.5 Hz
        _ = tr
        let r = e.results.first!
        XCTAssertFalse(r.pass)
        XCTAssertTrue(r.reason.contains("Hz") || r.reason.contains("status"), r.reason)
    }

    func testDeadLeftMotorFailsStepZeroAndHaltsBeforeFloor() {
        let w = SimWorld(); w.deadLeft = true
        let e = engine()
        let tr = runEngine(e, w)
        XCTAssertFalse(e.results.first!.pass)
        XCTAssertTrue(e.results.first!.reason.contains("applied L"), e.results.first!.reason)
        if case .halted = tr.finalState {} else { XCTFail("expected halted, got \(tr.finalState)") }
        XCTAssertEqual(e.results.count, 1)
        XCTAssertTrue(tr.prompts.isEmpty)       // never asked the human to put the rover on the floor
        XCTAssertEqual(events(tr, "run_halted").count, 1)
    }

    func testTrackingLossAbortsAfterOneSecondAndStops() {
        let w = SimWorld()
        let e = engine([.forwardBack])
        let tr = runEngine(e, w, beforeTick: { world, t in world.tracking = (t > 4 && t < 20) ? .limited : .normal })
        XCTAssertEqual(tr.finalState, .aborted(.trackingLost))
        XCTAssertEqual(tr.commands.last, .stop)
        XCTAssertEqual(e.trackingIncidents, 1)
        XCTAssertFalse(e.results.last!.pass)
        XCTAssertEqual(events(tr, "abort").count, 1)
    }

    func testShortTrackingBlipIsCountedButDoesNotAbort() {
        let w = SimWorld()
        let e = engine([.forwardBack])
        let tr = runEngine(e, w, beforeTick: { world, t in world.tracking = (t > 4 && t < 4.5) ? .limited : .normal })
        XCTAssertEqual(tr.finalState, .finished)
        XCTAssertEqual(e.trackingIncidents, 1)
    }

    func testBleDisconnectAbortsAndIsCounted() {
        let w = SimWorld()
        let e = engine([.forwardBack])
        let tr = runEngine(e, w, beforeTick: { world, t in world.connected = t < 5 })
        XCTAssertEqual(tr.finalState, .aborted(.bleDisconnected))
        XCTAssertEqual(e.bleDisconnects, 1)
        XCTAssertEqual(tr.commands.last, .stop)
    }

    func testStatusLossAbortsWhileDriving() {
        let w = SimWorld()
        let e = engine([.forwardBack])
        let tr = runEngine(e, w, beforeTick: { world, t in world.statusEnabled = t < 5 })
        XCTAssertEqual(tr.finalState, .aborted(.noStatus))
    }

    func testUserStopAbortsImmediately() {
        let w = SimWorld()
        let e = engine([.forwardBack])
        _ = e.start(now: w.time, runId: "r", startedUTC: "x", checklistConfirmed: true)
        let out = e.abort(.userStop, now: w.time + 1)
        XCTAssertEqual(out.command, .stop)
        XCTAssertEqual(out.state, .aborted(.userStop))
        XCTAssertTrue(out.records.contains { ($0["name"] as? String) == "abort" })
        XCTAssertEqual(e.abort(.userStop, now: w.time + 2).records.count, 0)   // idempotent
    }

    func testFrozenRoverTimesOutOnForwardSegment() {
        let w = SimWorld(); w.frozen = true
        var cfg = SelfTestConfig.default; cfg.motionSegmentTimeoutS = 5
        let e = engine([.forwardBack], config: cfg)
        let tr = runEngine(e, w)
        let r = e.results.first!
        XCTAssertFalse(r.pass)
        XCTAssertTrue(r.reason.contains("timeout"), r.reason)
        XCTAssertEqual(tr.commands.last, .stop)
        XCTAssertLessThan(tr.seconds, 30)
    }

    func testSidewaysDriftFailsForwardBack() {
        let w = SimWorld(); w.driftDegPerMeter = 30
        let e = engine([.forwardBack])
        _ = runEngine(e, w)
        let r = e.results.first!
        XCTAssertFalse(r.pass)
        XCTAssertGreaterThan(r.metrics["max_lateral_m"]!, SelfTestConfig.default.fwdLateralDriftLimitM)
    }

    func testObstacleStepRefusesWithoutGuardFeed() {
        let w = SimWorld(); w.guardFeed = false
        let e = engine([.obstacle])
        let tr = runEngine(e, w, onPrompt: { _, world in world.placeBox(metersAhead: 1) })
        XCTAssertFalse(e.results.first!.pass)
        XCTAssertTrue(e.results.first!.reason.contains("ObstacleGuard"))
        XCTAssertFalse(tr.commands.contains { if case .drive = $0 { return true } else { return false } })
    }

    func testObstacleStepFailsWhenNoBoxInPath() {
        let w = SimWorld()
        var cfg = SelfTestConfig.default; cfg.motionSegmentTimeoutS = 6
        let e = engine([.obstacle], config: cfg)
        _ = runEngine(e, w)
        XCTAssertFalse(e.results.first!.pass)
        XCTAssertTrue(e.results.first!.reason.contains("never stopped"), e.results.first!.reason)
    }

    func testObstacleStepStopsBeforeContact() {
        let w = SimWorld()
        let e = engine([.obstacle])
        _ = runEngine(e, w, onPrompt: { p, world in
            if p.contains("15 cm") { world.placeBox(metersAhead: 0.15) } else { world.placeBox(metersAhead: 1.0) }
        })
        let r = e.results.first!
        XCTAssertTrue(r.pass, r.reason)
        XCTAssertNotNil(r.metrics["slow_front_cm"])
        XCTAssertGreaterThanOrEqual(r.metrics["min_front_cm"]!, 10)
        XCTAssertEqual(r.metrics["flag2_seen"], 1)
    }

    func testObstacleStepFailsIfBoxNotCloseEnoughForClampCheck() {
        let w = SimWorld()
        let e = engine([.obstacle])
        _ = runEngine(e, w, onPrompt: { p, world in
            if p.contains("15 cm") { world.placeBox(metersAhead: 0.5) } else { world.placeBox(metersAhead: 1.0) }
        })
        let r = e.results.first!
        XCTAssertFalse(r.pass)
        XCTAssertTrue(r.reason.contains("not close enough"), r.reason)
    }

    func testPromptsRequiredBeforeFloorSteps() {
        let w = SimWorld()
        let e = engine([.forwardBack, .spin])
        let tr = runEngine(e, w)
        XCTAssertEqual(tr.prompts.count, 2)
        XCTAssertTrue(tr.prompts[0].contains("on the floor"))
        XCTAssertTrue(tr.prompts[1].contains("back on its start mark"))
        XCTAssertFalse(tr.commands.isEmpty)
    }

    func testStepRunOrderIsSortedWheelsOffFirst() {
        let e = SelfTestEngine(steps: [.spin, .wheelsOff, .square])
        let w = SimWorld()
        let tr = runEngine(e, w, maxSeconds: 20)
        let firstStart = tr.records.first { ($0["name"] as? String) == "phase_start" }
        XCTAssertEqual(firstStart?["step"] as? String, "wheels_off")
    }
}
