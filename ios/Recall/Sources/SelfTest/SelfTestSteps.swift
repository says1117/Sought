import Foundation
#if canImport(PoseCore)
import PoseCore
#endif

// The six scripted steps as pure state machines. Each tick gets the latest inputs and returns a command, log records,
// an optional human prompt and, when finished, a result. No clocks, no BLE, no ARKit: tests feed fakes.
// Step 6 (tracking incidents and BLE disconnects) is counted by SelfTestEngine across the whole run.
// ALL LIMITS COME FROM SelfTestConfig AND ARE PLACEHOLDERS.

struct StepContext {
    var now: Double            // engine clock, seconds
    var runT: Double           // seconds since run start (the `t` written to the log)
    var pose: Pose2D?          // nil when tracking is not normal
    var tracking: TrackingKind
    var statuses: [TimedStatus]
    var guardLevel: SelfTestGuardLevel?
    var confirm: Bool
    var config: SelfTestConfig
}

struct StepTick {
    var command: SelfTestCommand = .stop
    var records: [LogRecord] = []
    var prompt: String?
    var done: StepResult?
}

protocol SelfTestStep: AnyObject {
    var id: SelfTestStepID { get }
    /// Short live reading for the screen.
    var live: String { get }
    func tick(_ c: StepContext) -> StepTick
}

class StepBase: SelfTestStep {
    let id: SelfTestStepID
    let cfg: SelfTestConfig
    private(set) var statuses: [TimedStatus] = []
    private(set) var latest: TimedStatus?
    var liveText = ""
    var live: String { liveText }

    init(id: SelfTestStepID, config: SelfTestConfig) { self.id = id; self.cfg = config }

    func tick(_ c: StepContext) -> StepTick { fatalError("override") }

    func ingest(_ c: StepContext) {
        statuses += c.statuses
        if let l = c.statuses.last { latest = l }
    }

    func drive(_ l: Int, _ r: Int) -> SelfTestCommand { .drive(left: cfg.cap(l), right: cfg.cap(r)) }

    func ev(_ c: StepContext, _ name: String, _ extra: LogRecord = [:]) -> LogRecord {
        SelfTestLog.event(t: c.runT, step: id, name: name, extra)
    }

    func finish(_ c: StepContext, pass: Bool, reason: String, metrics: [String: Double], records: [LogRecord] = []) -> StepTick {
        StepTick(command: .stop, records: records, prompt: nil,
                 done: StepResult(id: id, pass: pass, reason: reason, metrics: metrics))
    }

    func poseFields(_ p: Pose2D) -> LogRecord {
        ["x": SelfTestLog.round3(p.x), "z": SelfTestLog.round3(p.z), "yaw_deg": SelfTestLog.round3(p.yawDeg)]
    }

    func mean(_ v: [Double]) -> Double? { SelfTestMetrics.mean(v) }
}

// MARK: Step 0, wheels off

final class WheelsOffStep: StepBase {
    private struct Phase { var name: String; var left: Int; var right: Int }
    private var phases: [Phase] = []
    private var index = 0
    private var phaseStart: Double?
    private var stepStart: Double?
    private var failures: [String] = []
    private var metrics: [String: Double] = [:]
    private var resting = false

    init(config: SelfTestConfig) {
        super.init(id: .wheelsOff, config: config)
        let p = config.testPwm
        phases = [Phase(name: "forward", left: p, right: p), Phase(name: "back", left: -p, right: -p),
                  Phase(name: "spin_left", left: -p, right: p), Phase(name: "spin_right", left: p, right: -p)]
    }

    override func tick(_ c: StepContext) -> StepTick {
        ingest(c)
        var out = StepTick()
        if stepStart == nil { stepStart = c.now }
        if phaseStart == nil {
            phaseStart = c.now
            let ph = phases[index]
            out.records.append(ev(c, "phase_start", ["phase": ph.name, "left": cfg.cap(ph.left), "right": cfg.cap(ph.right)]))
        }
        let ph = phases[index]
        let t = c.now - phaseStart!
        if let s = latest { liveText = "\(ph.name): cmd \(cfg.cap(ph.left)),\(cfg.cap(ph.right))  applied L \(s.left) R \(s.right)" }

        if t < cfg.wheelPhaseS {
            out.command = drive(ph.left, ph.right)
            return out
        }
        if !resting {
            resting = true
            evaluate(ph, phaseStart: phaseStart!, c, &out)
            out.records.append(ev(c, "phase_end", ["phase": ph.name]))
        }
        out.command = .stop
        if t < cfg.wheelPhaseS + cfg.wheelRestS { return out }

        index += 1; phaseStart = nil; resting = false
        if index < phases.count { return out }
        return conclude(c, base: out)
    }

    private func evaluate(_ ph: Phase, phaseStart: Double, _ c: StepContext, _ out: inout StepTick) {
        let win = statuses.filter { $0.t >= phaseStart + cfg.wheelSettleS && $0.t <= phaseStart + cfg.wheelPhaseS + 0.05 }
        guard win.count >= 2 else {
            failures.append("\(ph.name): only \(win.count) status lines in the settled window")
            out.records.append(ev(c, "phase_result", ["phase": ph.name, "ok": false, "n_status": win.count]))
            return
        }
        let mL = mean(win.map { Double($0.left) })!, mR = mean(win.map { Double($0.right) })!
        let eL = abs(mL - Double(cfg.cap(ph.left))), eR = abs(mR - Double(cfg.cap(ph.right)))
        var ok = eL <= cfg.wheelToleranceUnits && eR <= cfg.wheelToleranceUnits
        var why = ""
        if !ok {
            why = "\(ph.name): applied L \(Int(mL.rounded())) R \(Int(mR.rounded())) vs commanded \(cfg.cap(ph.left)),\(cfg.cap(ph.right))"
            let blocked = ph.name == "forward" ? win.contains { $0.frontBlocked } : (ph.name == "back" ? win.contains { $0.rearBlocked } : false)
            if blocked { why += " (sonar blocked flag was set: clear the area and retry)" }
        }
        if win.contains(where: { $0.watchdogStopped }) { ok = false; why += (why.isEmpty ? "" : "; ") + "\(ph.name): watchdog flag set while commands were flowing" }
        if !why.isEmpty { failures.append(why) }
        metrics["\(ph.name)_applied_left"] = mL
        metrics["\(ph.name)_applied_right"] = mR
        metrics["\(ph.name)_max_err_units"] = max(eL, eR)
        out.records.append(ev(c, "phase_result", ["phase": ph.name, "ok": ok, "n_status": win.count,
                                                   "mean_left": SelfTestLog.round3(mL), "mean_right": SelfTestLog.round3(mR)]))
    }

    private func conclude(_ c: StepContext, base: StepTick) -> StepTick {
        let win = statuses.filter { $0.t >= (stepStart ?? 0) }
        let hz = SelfTestMetrics.statusRateHz(times: win.map { $0.t })
        if let hz { metrics["status_hz"] = hz } else { failures.append("fewer than 2 status lines, cannot compute rate") }
        if let hz, hz < cfg.minStatusHz { failures.append("status rate \(String(format: "%.1f", hz)) Hz below \(cfg.minStatusHz) Hz") }
        let bleMissing = win.filter { !$0.bleConnected }.count
        metrics["ble_flag_missing_count"] = Double(bleMissing)
        if bleMissing > 0 { failures.append("BLE-connected flag (8) missing on \(bleMissing) status lines") }
        var t = finish(c, pass: failures.isEmpty, reason: failures.isEmpty ? "ok" : failures.joined(separator: "; "), metrics: metrics)
        t.records = base.records
        return t
    }
}

// MARK: Step 1, watchdog

final class WatchdogStep: StepBase {
    private enum Phase { case run, silent, resume }
    private var phase = Phase.run
    private var phaseStart: Double?
    private var suspendT = 0.0
    private var resumeT = 0.0
    private var metrics: [String: Double] = [:]

    init(config: SelfTestConfig) { super.init(id: .watchdog, config: config) }

    override func tick(_ c: StepContext) -> StepTick {
        ingest(c)
        var out = StepTick()
        let p = cfg.testPwm
        if phaseStart == nil {
            phaseStart = c.now
            if phase == .silent { suspendT = c.now; out.records.append(ev(c, "watchdog_suspend")) }
            if phase == .resume { resumeT = c.now; out.records.append(ev(c, "watchdog_resume")) }
        }
        let t = c.now - phaseStart!
        if let s = latest { liveText = "applied L \(s.left) R \(s.right) flags \(s.flags)" }

        switch phase {
        case .run:
            out.command = drive(p, p)
            if t < cfg.wheelPhaseS { return out }
            let win = statuses.filter { $0.t >= phaseStart! + cfg.wheelSettleS }
            guard let m = mean(win.map { abs(Double($0.left)) + abs(Double($0.right)) }), m > 0 else {
                return finish(c, pass: false, reason: "motors were not running before the watchdog test; cannot test it", metrics: metrics, records: out.records)
            }
            if win.contains(where: { $0.watchdogStopped }) {
                return finish(c, pass: false, reason: "watchdog flag already set while commands were flowing", metrics: metrics, records: out.records)
            }
            advance(.silent)
            return out
        case .silent:
            out.command = .silent
            if t < cfg.watchdogObserveS { return out }
            let after = statuses.filter { $0.t >= suspendT }
            if let l = SelfTestMetrics.watchdogStopLatency(suspendT: suspendT, statuses: after) { metrics["stop_latency_s"] = l }
            if let l = SelfTestMetrics.watchdogFlagLatency(suspendT: suspendT, statuses: after) { metrics["flag_latency_s"] = l }
            advance(.resume)
            return out
        case .resume:
            out.command = drive(p, p)
            let ok = statuses.first { $0.t >= resumeT && ($0.left != 0 || $0.right != 0) && !$0.watchdogStopped }
            if let ok { metrics["resume_latency_s"] = ok.t - resumeT }
            if ok == nil && t < cfg.watchdogResumeWaitS { return out }
            return conclude(c, records: out.records)
        }
    }

    private func advance(_ p: Phase) { phase = p; phaseStart = nil }

    private func conclude(_ c: StepContext, records: [LogRecord]) -> StepTick {
        var fails: [String] = []
        let limit = cfg.watchdogPassLimitS
        if let l = metrics["stop_latency_s"] {
            if l > limit { fails.append("motors read 0 after \(String(format: "%.2f", l)) s, limit \(String(format: "%.2f", limit)) s") }
        } else { fails.append("motors never read 0 after commands stopped") }
        if metrics["flag_latency_s"] == nil { fails.append("watchdog flag (1) never set") }
        if metrics["resume_latency_s"] == nil { fails.append("motors did not resume with flag 1 cleared after the next command") }
        return finish(c, pass: fails.isEmpty, reason: fails.isEmpty ? "ok" : fails.joined(separator: "; "), metrics: metrics, records: records)
    }
}

// MARK: Pose steps share a "wait for a pose" start and segment timeouts

class PoseStepBase: StepBase {
    func timedOut(_ c: StepContext, since: Double) -> Bool { c.now - since > cfg.motionSegmentTimeoutS }

    func timeoutResult(_ c: StepContext, _ what: String, metrics: [String: Double], records: [LogRecord]) -> StepTick {
        finish(c, pass: false, reason: "\(what) exceeded the \(Int(cfg.motionSegmentTimeoutS)) s segment timeout", metrics: metrics, records: records)
    }
}

// MARK: Step 2, forward 1.0 m and back

final class ForwardBackStep: PoseStepBase {
    private enum Phase { case waitPose, fwd, settleF, back, settleB }
    private var phase = Phase.waitPose
    private var phaseStart = 0.0
    private var p0 = Pose2D(x: 0, z: 0, yawDeg: 0)
    private var u: (x: Double, z: Double) = (0, -1)
    private var forwardM = 0.0
    private var maxLateral = 0.0
    private var lateralEnd = 0.0
    private var metrics: [String: Double] = [:]

    init(config: SelfTestConfig) { super.init(id: .forwardBack, config: config) }

    override func tick(_ c: StepContext) -> StepTick {
        ingest(c)
        var out = StepTick()
        let p = cfg.testPwm
        guard let pose = c.pose else { out.command = .stop; return out }

        switch phase {
        case .waitPose:
            p0 = pose; u = SelfTestMetrics.forwardUnit(yawDeg: pose.yawDeg)
            out.records.append(ev(c, "leg_start", poseFields(pose)))
            enter(.fwd, c)
            out.command = drive(p, p)
        case .fwd:
            let d = SelfTestMetrics.alongTrack(origin: p0, u: u, p: pose)
            let lat = SelfTestMetrics.lateral(origin: p0, u: u, p: pose)
            maxLateral = max(maxLateral, abs(lat))
            liveText = String(format: "forward %.2f m  lateral %+.3f m", d, lat)
            if d >= cfg.forwardTargetM { enter(.settleF, c); out.command = .stop }
            else if timedOut(c, since: phaseStart) { return timeoutResult(c, "forward leg", metrics: metrics, records: out.records) }
            else { out.command = drive(p, p) }
        case .settleF:
            if c.now - phaseStart >= cfg.settleS {
                forwardM = SelfTestMetrics.alongTrack(origin: p0, u: u, p: pose)
                lateralEnd = SelfTestMetrics.lateral(origin: p0, u: u, p: pose)
                maxLateral = max(maxLateral, abs(lateralEnd))
                out.records.append(ev(c, "fwd_end", poseFields(pose)))
                enter(.back, c)
                out.command = drive(-p, -p)
            }
        case .back:
            let d = SelfTestMetrics.alongTrack(origin: p0, u: u, p: pose)
            liveText = String(format: "back, %.2f m from start along track", d)
            if d <= 0 { enter(.settleB, c); out.command = .stop }
            else if timedOut(c, since: phaseStart) { return timeoutResult(c, "back leg", metrics: metrics, records: out.records) }
            else { out.command = drive(-p, -p) }
        case .settleB:
            if c.now - phaseStart >= cfg.settleS {
                out.records.append(ev(c, "back_end", poseFields(pose)))
                return conclude(c, end: pose, records: out.records)
            }
        }
        return out
    }

    private func enter(_ p: Phase, _ c: StepContext) { phase = p; phaseStart = c.now }

    private func conclude(_ c: StepContext, end: Pose2D, records: [LogRecord]) -> StepTick {
        let distErr = forwardM - cfg.forwardTargetM
        let ret = SelfTestMetrics.distance(end, p0)
        let retYaw = abs(PoseMath.shortestDelta(from: p0.yawDeg, to: end.yawDeg))
        metrics = ["forward_distance_m": forwardM, "distance_error_m": distErr, "max_lateral_m": maxLateral,
                   "lateral_end_m": lateralEnd, "return_error_m": ret, "return_yaw_error_deg": retYaw]
        var fails: [String] = []
        if abs(distErr) > cfg.fwdDistanceErrLimitM { fails.append(String(format: "distance error %.3f m", distErr)) }
        if maxLateral > cfg.fwdLateralDriftLimitM { fails.append(String(format: "lateral drift %.3f m", maxLateral)) }
        if ret > cfg.fwdReturnErrLimitM { fails.append(String(format: "return error %.3f m", ret)) }
        return finish(c, pass: fails.isEmpty, reason: fails.isEmpty ? "ok" : fails.joined(separator: "; "), metrics: metrics, records: records)
    }
}

// MARK: Step 3, 2 m square and return (plan task R0.5 at the current phone height)

final class SquareStep: PoseStepBase {
    private enum Phase { case waitPose, leg, settleLeg, turn, settleTurn }
    private var phase = Phase.waitPose
    private var phaseStart = 0.0
    private var leg = 0
    private var p0 = Pose2D(x: 0, z: 0, yawDeg: 0)
    private var legOrigin = Pose2D(x: 0, z: 0, yawDeg: 0)
    private var yaw = YawAccumulator()
    private var metrics: [String: Double] = [:]

    init(config: SelfTestConfig) { super.init(id: .square, config: config) }

    override func tick(_ c: StepContext) -> StepTick {
        ingest(c)
        var out = StepTick()
        let p = cfg.testPwm
        guard let pose = c.pose else { out.command = .stop; return out }
        yaw.add(yawDeg: pose.yawDeg)

        switch phase {
        case .waitPose:
            p0 = pose
            out.records.append(ev(c, "leg_start", poseFields(pose).merging(["leg": 0]) { a, _ in a }))
            startLeg(pose, c)
            out.command = drive(p, p)
        case .leg:
            let d = SelfTestMetrics.distance(pose, legOrigin)
            liveText = String(format: "leg %d/4  %.2f of %.1f m", leg + 1, d, cfg.squareSideM)
            if d >= cfg.squareSideM { metrics["leg\(leg)_m"] = d; enter(.settleLeg, c); out.command = .stop }
            else if timedOut(c, since: phaseStart) { return timeoutResult(c, "leg \(leg + 1)", metrics: metrics, records: out.records) }
            else { out.command = drive(p, p) }
        case .settleLeg:
            if c.now - phaseStart >= cfg.settleS {
                out.records.append(ev(c, "leg_end", poseFields(pose).merging(["leg": leg]) { a, _ in a }))
                enter(.turn, c)
                out.command = drive(-p, p)
            }
        case .turn:
            // Cumulative target, so one turn's overshoot is taken out of the next turn instead of compounding.
            let target = cfg.squareTurnDeg * Double(leg + 1)
            liveText = String(format: "turn %d/4  %.0f of %.0f deg", leg + 1, yaw.total, target)
            if yaw.total >= target { metrics["turn\(leg)_cumulative_deg"] = yaw.total; enter(.settleTurn, c); out.command = .stop }
            else if timedOut(c, since: phaseStart) { return timeoutResult(c, "turn \(leg + 1)", metrics: metrics, records: out.records) }
            else { out.command = drive(-p, p) }
        case .settleTurn:
            if c.now - phaseStart >= cfg.settleS {
                out.records.append(ev(c, "turn_end", poseFields(pose).merging(["leg": leg]) { a, _ in a }))
                leg += 1
                if leg >= 4 { return conclude(c, end: pose, records: out.records) }
                startLeg(pose, c)
                out.command = drive(p, p)
            }
        }
        return out
    }

    private func startLeg(_ pose: Pose2D, _ c: StepContext) { legOrigin = pose; enter(.leg, c) }
    private func enter(_ p: Phase, _ c: StepContext) { phase = p; phaseStart = c.now }

    private func conclude(_ c: StepContext, end: Pose2D, records: [LogRecord]) -> StepTick {
        let err = SelfTestMetrics.distance(end, p0)
        metrics["final_error_m"] = err
        metrics["final_yaw_error_deg"] = abs(PoseMath.shortestDelta(from: p0.yawDeg, to: end.yawDeg))
        let pass = err <= cfg.squareFinalErrLimitM
        return finish(c, pass: pass, reason: pass ? "ok" : String(format: "final pose error %.3f m above %.2f m", err, cfg.squareFinalErrLimitM),
                      metrics: metrics, records: records)
    }
}

// MARK: Step 4, 360 degree spin

final class SpinStep: PoseStepBase {
    private enum Phase { case waitPose, spin, settle }
    private var phase = Phase.waitPose
    private var phaseStart = 0.0
    private var spinStart = 0.0
    private var spinTime = 0.0
    private var p0 = Pose2D(x: 0, z: 0, yawDeg: 0)
    private var yaw = YawAccumulator()

    init(config: SelfTestConfig) { super.init(id: .spin, config: config) }

    override func tick(_ c: StepContext) -> StepTick {
        ingest(c)
        var out = StepTick()
        let p = cfg.testPwm
        guard let pose = c.pose else { out.command = .stop; return out }
        yaw.add(yawDeg: pose.yawDeg)

        switch phase {
        case .waitPose:
            p0 = pose; spinStart = c.now; phaseStart = c.now; phase = .spin
            out.records.append(ev(c, "spin_start", poseFields(pose)))
            out.command = drive(-p, p)
        case .spin:
            liveText = String(format: "spin %.0f of %.0f deg", yaw.total, cfg.spinDeg)
            if yaw.total >= cfg.spinDeg { spinTime = c.now - spinStart; phase = .settle; phaseStart = c.now; out.command = .stop }
            else if timedOut(c, since: phaseStart) { return timeoutResult(c, "spin", metrics: ["spin_total_deg": yaw.total], records: out.records) }
            else { out.command = drive(-p, p) }
        case .settle:
            if c.now - phaseStart >= cfg.settleS {
                out.records.append(ev(c, "spin_end", poseFields(pose)))
                let err = yaw.total - cfg.spinDeg
                let metrics = ["spin_total_deg": yaw.total, "yaw_error_deg": err, "spin_time_s": spinTime,
                               "position_drift_m": SelfTestMetrics.distance(pose, p0)]
                let pass = abs(err) <= cfg.spinYawErrLimitDeg
                return finish(c, pass: pass, reason: pass ? "ok" : String(format: "yaw error %+.1f deg above %.0f deg", err, cfg.spinYawErrLimitDeg),
                              metrics: metrics, records: out.records)
            }
        }
        return out
    }
}

// MARK: Step 5, front obstacle (a human places a box)

final class ObstacleStep: PoseStepBase {
    private enum Phase { case promptBox, approach, settleApproach, promptClose, verifyClose, clampForward, blockedSpin, reverse }
    private var phase = Phase.promptBox
    private var phaseStart = 0.0
    private var metrics: [String: Double] = [:]
    private var fails: [String] = []
    private var minFront: Int?
    private var firstSlowFront: Int?
    private var stopReason: String?
    private var flag2Seen = false
    private var closeConfirmT = 0.0

    init(config: SelfTestConfig) { super.init(id: .obstacle, config: config) }

    override func tick(_ c: StepContext) -> StepTick {
        ingest(c)
        if phase == .approach || phase == .settleApproach {
            for s in c.statuses { if let f = s.frontDistanceCm { minFront = min(minFront ?? f, f) } }
        }
        var out = StepTick()
        let p = cfg.testPwm
        if let s = latest { liveText = "front \(s.frontDistanceCm.map(String.init) ?? "-") cm  applied L \(s.left) R \(s.right)  flags \(s.flags)" }

        switch phase {
        case .promptBox:
            if c.guardLevel == nil {
                return finish(c, pass: false, reason: "no ObstacleGuard feed (needs LiDAR depth); refusing to drive toward a box", metrics: metrics)
            }
            if !c.confirm {
                out.prompt = "Place a box about 1 m in front of the rover, centered. Keep a hand ready on STOP. Press Continue."
                return out
            }
            enter(.approach, c)
            out.records.append(ev(c, "approach_start"))
            out.command = approachCommand(c, &out)
        case .approach:
            out.command = approachCommand(c, &out)
            if stopReason == nil, c.now - phaseStart > cfg.motionSegmentTimeoutS {
                return finish(c, pass: false, reason: "never stopped for the box within the \(Int(cfg.motionSegmentTimeoutS)) s segment timeout (was a box in the path?)",
                              metrics: collect(), records: out.records)
            }
        case .settleApproach:
            if c.now - phaseStart >= cfg.settleS {
                metrics = collect()
                guard let mf = minFront else {
                    return finish(c, pass: false, reason: "front sonar never returned a reading; contact distance cannot be verified", metrics: metrics, records: out.records)
                }
                if Double(mf) < cfg.contactMarginCm {
                    return finish(c, pass: false, reason: "closest front sonar reading \(mf) cm is below the \(Int(cfg.contactMarginCm)) cm contact margin", metrics: metrics, records: out.records)
                }
                out.records.append(ev(c, "approach_end", ["stop_reason": stopReason ?? "", "min_front_cm": mf]))
                enter(.promptClose, c)
            }
        case .promptClose:
            if !c.confirm {
                out.prompt = "Slide the box to about 15 cm in front of the rover (sonar must read under 20 cm). It will test forward, turn and reverse. Press Continue."
                return out
            }
            closeConfirmT = c.now
            enter(.verifyClose, c)
        case .verifyClose:
            // Judge the sonar reading taken AFTER the human moved the box, not a stale line from before.
            let fresh = statuses.last { $0.t >= closeConfirmT }
            if fresh == nil && c.now - closeConfirmT < 1.0 { return out }
            guard let f = fresh?.frontDistanceCm, f < cfg.firmwareFrontStopCm else {
                return finish(c, pass: false, reason: "front sonar does not read under \(cfg.firmwareFrontStopCm) cm (reads \(fresh?.frontDistanceCm.map(String.init) ?? "no echo")); box not close enough, forward clamp not tested", metrics: collect(), records: out.records)
            }
            enter(.clampForward, c)
            out.records.append(ev(c, "blocked_start", ["front_cm": f]))
            out.command = drive(p, p)
        case .clampForward:
            let t = c.now - phaseStart
            for s in c.statuses where s.frontBlocked { flag2Seen = true }
            if let s = latest, t > 0.3, s.linear > cfg.clampTolerance {
                metrics = collect()
                metrics["clamp_max_linear"] = s.linear
                return finish(c, pass: false, reason: "firmware did not clamp forward: applied linear \(Int(s.linear)) with front \(s.frontDistanceCm.map(String.init) ?? "-") cm",
                              metrics: metrics, records: out.records)
            }
            if t < cfg.blockedPhaseS { out.command = drive(p, p); return out }
            let win = statuses.filter { $0.t >= phaseStart + 0.4 }
            let maxLin = win.map { $0.linear }.max()
            metrics["clamp_max_linear"] = maxLin ?? .nan
            if maxLin == nil { fails.append("no status lines during the forward clamp check") }
            if !flag2Seen { fails.append("front blocked flag (2) never set with the box under \(cfg.firmwareFrontStopCm) cm") }
            out.records.append(ev(c, "clamp_forward_result", ["flag2_seen": flag2Seen, "max_linear": maxLin ?? 0]))
            enter(.blockedSpin, c)
            out.command = drive(-p, p)
        case .blockedSpin:
            let t = c.now - phaseStart
            if t < cfg.blockedSpinS { out.command = drive(-p, p); return out }
            let win = statuses.filter { $0.t >= phaseStart + 0.4 }
            if let a = mean(win.map { $0.angular }) {
                metrics["blocked_spin_angular"] = a
                if a < 0.5 * Double(cfg.testPwm) { fails.append("turning was not allowed while blocked (applied angular \(Int(a)))") }
            } else { fails.append("no status lines during the blocked turn check") }
            out.records.append(ev(c, "blocked_spin_result"))
            if latest?.rearBlocked == true {
                fails.append("rear blocked flag set, reverse not tested")
                return conclude(c, records: out.records)
            }
            enter(.reverse, c)
            out.command = drive(-p, -p)
        case .reverse:
            let t = c.now - phaseStart
            if t < cfg.blockedReverseS { out.command = drive(-p, -p); return out }
            let win = statuses.filter { $0.t >= phaseStart + 0.4 }
            if let l = mean(win.map { $0.linear }) {
                metrics["blocked_reverse_linear"] = l
                if l > -0.5 * Double(cfg.testPwm) { fails.append("reverse was not allowed while blocked (applied linear \(Int(l)))") }
            } else { fails.append("no status lines during the reverse check") }
            out.records.append(ev(c, "reverse_result"))
            return conclude(c, records: out.records)
        }
        return out
    }

    /// Forward while the guard says clear or slow; stop on guard stop, sonar flag 2, or front under the firmware limit.
    private func approachCommand(_ c: StepContext, _ out: inout StepTick) -> SelfTestCommand {
        let p = cfg.testPwm
        let front = latest?.frontDistanceCm
        let sonarStop = latest?.frontBlocked == true || (front.map { $0 <= cfg.firmwareFrontStopCm } ?? false)
        if c.guardLevel == .stop || sonarStop {
            stopReason = c.guardLevel == .stop ? "guard_stop" : "sonar_stop"
            metrics["stop_front_cm"] = Double(front ?? -1)
            out.records.append(ev(c, "approach_stopped", ["reason": stopReason!, "front_cm": front ?? -1]))
            enter(.settleApproach, c)
            return .stop
        }
        if c.guardLevel == .slow {
            if firstSlowFront == nil, let f = front { firstSlowFront = f }
            return drive(cfg.slowPwm, cfg.slowPwm)
        }
        return drive(p, p)
    }

    private func collect() -> [String: Double] {
        var m = metrics
        if let mf = minFront { m["min_front_cm"] = Double(mf) }
        if let f = firstSlowFront { m["slow_front_cm"] = Double(f) }
        m["flag2_seen"] = flag2Seen ? 1 : 0
        return m
    }

    private func enter(_ p: Phase, _ c: StepContext) { phase = p; phaseStart = c.now }

    private func conclude(_ c: StepContext, records: [LogRecord]) -> StepTick {
        finish(c, pass: fails.isEmpty, reason: fails.isEmpty ? "ok" : fails.joined(separator: "; "), metrics: collect(), records: records)
    }
}
