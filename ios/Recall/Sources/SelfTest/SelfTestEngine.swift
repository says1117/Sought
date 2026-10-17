import Foundation
#if canImport(PoseCore)
import PoseCore
#endif

// Sequences the steps, enforces the safety rules and produces the JSONL records.
// Pure: feed `tick` the latest inputs at about 10 Hz, apply the returned command, append the returned records to the log.
//
// Safety rules (all in this file, all tested with fakes):
//  - the run needs the human checklist confirmed before it starts
//  - every drive command is capped at config.maxPwm
//  - tracking != normal for longer than trackingAbortS on a pose step aborts the run
//  - BLE disconnect, or no status lines for statusLossAbortS, aborts the run
//  - any abort returns .stop; a hard whole-step cap aborts a step that is stuck
//  - wheels-off steps (0, 1) run first; if either fails the run halts before the rover is put on the floor
//  - floor steps each wait for the human to confirm the rover is back on its start mark

struct SelfTestOutput {
    var command: SelfTestCommand
    var records: [LogRecord]
    var prompt: String?
    var state: SelfTestEngine.RunState
}

final class SelfTestEngine {
    enum RunState: Equatable {
        case idle
        case running
        case awaitingHuman(String)
        case finished
        case halted(String)
        case aborted(SelfTestAbortReason)

        var isTerminal: Bool {
            switch self {
            case .finished, .halted, .aborted: return true
            default: return false
            }
        }
    }

    private(set) var state = RunState.idle
    private(set) var results: [StepResult] = []
    private(set) var trackingIncidents = 0
    private(set) var bleDisconnects = 0
    private(set) var currentStep: SelfTestStepID?
    var liveReading: String { step?.live ?? "" }

    private let config: SelfTestConfig
    private let order: [SelfTestStepID]
    private let makeStep: (SelfTestStepID, SelfTestConfig) -> SelfTestStep
    private var index = 0
    private var step: SelfTestStep?
    private var prePromptDone = false
    private var runStart = 0.0
    private var stepStartRun = 0.0
    private var lastTickNow: Double?
    private var activeT = 0.0
    private var lastStatusT: Double?
    private var seenStatus = false
    private var trackingBadSince: Double?
    private var trackingWasBad = false
    private var wasConnected = true
    private var pendingConfirm = false

    init(config: SelfTestConfig = .default,
         steps: [SelfTestStepID] = SelfTestStepID.allCases,
         makeStep: @escaping (SelfTestStepID, SelfTestConfig) -> SelfTestStep = SelfTestEngine.defaultStep) {
        self.config = config
        self.order = steps.sorted()
        self.makeStep = makeStep
    }

    static func defaultStep(_ id: SelfTestStepID, _ c: SelfTestConfig) -> SelfTestStep {
        switch id {
        case .wheelsOff: return WheelsOffStep(config: c)
        case .watchdog: return WatchdogStep(config: c)
        case .forwardBack: return ForwardBackStep(config: c)
        case .square: return SquareStep(config: c)
        case .spin: return SpinStep(config: c)
        case .obstacle: return ObstacleStep(config: c)
        }
    }

    // MARK: Control

    /// Refuses (aborts with checklist_not_confirmed) unless the human checklist was confirmed.
    func start(now: Double, runId: String, startedUTC: String, checklistConfirmed: Bool) -> SelfTestOutput {
        runStart = now; lastTickNow = now
        var meta: LogRecord = ["type": "meta", "t": 0.0, "schema": SelfTestLog.schema, "run_id": runId,
                               "started_utc": startedUTC, "config": config.logDictionary,
                               "steps": order.map { $0.logName}]
        meta["note"] = "Thresholds are placeholders, to be calibrated by Steven, not measured."
        guard checklistConfirmed else {
            state = .aborted(.checklistNotConfirmed)
            return SelfTestOutput(command: .stop, records: [meta, abortRecord(now, .checklistNotConfirmed)], prompt: nil, state: state)
        }
        guard !order.isEmpty else {
            state = .finished
            return SelfTestOutput(command: .stop, records: [meta, summary(now)], prompt: nil, state: state)
        }
        state = .running
        beginStep(now)
        return SelfTestOutput(command: .stop, records: [meta], prompt: nil, state: state)
    }

    /// STOP button, or any outside abort.
    func abort(_ reason: SelfTestAbortReason, now: Double) -> SelfTestOutput {
        guard !state.isTerminal, state != .idle else {
            return SelfTestOutput(command: .stop, records: [], prompt: nil, state: state)
        }
        return doAbort(reason, now: now, extra: [])
    }

    // MARK: Tick

    func tick(_ input: SelfTestInput) -> SelfTestOutput {
        if state.isTerminal || state == .idle {
            return SelfTestOutput(command: .stop, records: [], prompt: nil, state: state)
        }
        let now = input.now
        let runT = now - runStart
        var records: [LogRecord] = []
        let dt = max(0, now - (lastTickNow ?? now))
        lastTickNow = now
        if input.confirm { pendingConfirm = true }

        for s in input.statuses {
            seenStatus = true
            lastStatusT = s.t
            records.append(["type": "status", "t": SelfTestLog.round3(s.t - runStart), "uptime_ms": s.uptimeMs,
                            "left": s.left, "right": s.right, "front_cm": s.frontCm, "rear_cm": s.rearCm, "flags": s.flags])
        }
        var pr: LogRecord = ["type": "pose", "t": SelfTestLog.round3(runT), "tracking": input.tracking.rawValue]
        if let p = input.pose {
            pr["x"] = SelfTestLog.round3(p.x); pr["z"] = SelfTestLog.round3(p.z); pr["yaw_deg"] = SelfTestLog.round3(p.yawDeg)
        }
        records.append(pr)

        // Incident counters (step 6) run for the whole run.
        let trackingBad = input.tracking != .normal
        if trackingBad {
            if !trackingWasBad {
                trackingIncidents += 1
                records.append(SelfTestLog.event(t: runT, step: currentStep, name: "tracking_incident", ["tracking": input.tracking.rawValue]))
            }
            if trackingBadSince == nil { trackingBadSince = now }
        } else { trackingBadSince = nil }
        trackingWasBad = trackingBad

        if wasConnected && !input.bleConnected {
            bleDisconnects += 1
            wasConnected = false
            return doAbort(.bleDisconnected, now: now, extra: records + [SelfTestLog.event(t: runT, step: currentStep, name: "ble_disconnect")])
        }
        wasConnected = input.bleConnected

        let lossLimit = seenStatus ? config.statusLossAbortS : config.firstStatusWaitS
        if now - (lastStatusT.map { $0 } ?? runStart) > lossLimit {
            return doAbort(.noStatus, now: now, extra: records)
        }
        if let id = currentStep, id.needsPose, prePromptDone, let since = trackingBadSince, now - since > config.trackingAbortS {
            return doAbort(.trackingLost, now: now, extra: records)
        }

        // Pre-step human prompt for floor steps.
        if !prePromptDone, let id = currentStep {
            if id.needsPose {
                if pendingConfirm {
                    pendingConfirm = false; prePromptDone = true
                    records.append(SelfTestLog.event(t: runT, step: id, name: "human_confirmed"))
                } else {
                    let text = results.contains(where: { $0.id.needsPose })
                        ? "Put the rover back on its start mark, facing the same way, with the area clear. Press Continue for \(id.title)."
                        : "Wheels-off checks are done. Put the rover on the floor on its start mark with 3 m clear ahead and around, and stay next to it with a hand on STOP. Press Continue for \(id.title)."
                    state = .awaitingHuman(text)
                    return SelfTestOutput(command: .stop, records: records, prompt: text, state: state)
                }
            } else { prePromptDone = true }
        }
        state = .running

        guard let s = step, let id = currentStep else { return SelfTestOutput(command: .stop, records: records, prompt: nil, state: state) }
        let ctx = StepContext(now: now, runT: runT, pose: input.pose, tracking: input.tracking,
                              statuses: input.statuses, guardLevel: input.guardLevel, confirm: pendingConfirm, config: config)
        let out = s.tick(ctx)
        pendingConfirm = false
        records += out.records

        if let prompt = out.prompt {
            state = .awaitingHuman(prompt)
            records.append(cmdRecord(runT, id, .stop))
            return SelfTestOutput(command: .stop, records: records, prompt: prompt, state: state)
        }
        activeT += dt
        if let r = out.done {
            records.append(cmdRecord(runT, id, .stop))
            return completeStep(r, now: now, records: records)
        }
        if activeT > config.stepCapS(id) {
            return doAbort(.stepTimeout, now: now, extra: records)
        }
        let cmd = capped(out.command)
        records.append(cmdRecord(runT, id, cmd))
        return SelfTestOutput(command: cmd, records: records, prompt: nil, state: state)
    }

    // MARK: Internals

    private func capped(_ c: SelfTestCommand) -> SelfTestCommand {
        if case .drive(let l, let r) = c { return .drive(left: config.cap(l), right: config.cap(r)) }
        return c
    }

    private func cmdRecord(_ runT: Double, _ id: SelfTestStepID, _ c: SelfTestCommand) -> LogRecord {
        var r: LogRecord = ["type": "cmd", "t": SelfTestLog.round3(runT), "step": id.logName]
        switch c {
        case .drive(let l, let rr): r["mode"] = "drive"; r["left"] = l; r["right"] = rr
        case .stop: r["mode"] = "stop"; r["left"] = 0; r["right"] = 0
        case .silent: r["mode"] = "silent"
        }
        return r
    }

    private func beginStep(_ now: Double) {
        guard index < order.count else { step = nil; currentStep = nil; return }
        let id = order[index]
        currentStep = id
        step = makeStep(id, config)
        prePromptDone = false
        activeT = 0
        stepStartRun = now - runStart
    }

    private func completeStep(_ r: StepResult, now: Double, records: [LogRecord]) -> SelfTestOutput {
        var recs = records
        let runT = now - runStart
        results.append(r)
        recs.append(SelfTestLog.event(t: runT, step: r.id, name: "step_end",
                                      ["pass": r.pass, "reason": r.reason, "metrics": cleanMetrics(r.metrics)]))
        if !r.pass && r.id < .forwardBack {
            let why = "\(r.id.title) failed: \(r.reason). Fix this before putting the rover on the floor."
            state = .halted(why)
            recs.append(SelfTestLog.event(t: runT, step: r.id, name: "run_halted", ["reason": why]))
            recs.append(summary(now))
            return SelfTestOutput(command: .stop, records: recs, prompt: nil, state: state)
        }
        index += 1
        beginStep(now)
        if step == nil {
            state = .finished
            recs.append(summary(now))
        } else { state = .running }
        return SelfTestOutput(command: .stop, records: recs, prompt: nil, state: state)
    }

    private func doAbort(_ reason: SelfTestAbortReason, now: Double, extra: [LogRecord]) -> SelfTestOutput {
        var recs = extra
        let runT = now - runStart
        recs.append(abortRecord(now, reason))
        if let id = currentStep, !results.contains(where: { $0.id == id }) {
            let r = StepResult(id: id, pass: false, reason: "aborted: \(reason.rawValue)", metrics: [:])
            results.append(r)
            recs.append(SelfTestLog.event(t: runT, step: id, name: "step_end", ["pass": false, "reason": r.reason, "metrics": [String: Double]()]))
        }
        state = .aborted(reason)
        recs.append(summary(now))
        return SelfTestOutput(command: .stop, records: recs, prompt: nil, state: state)
    }

    private func abortRecord(_ now: Double, _ reason: SelfTestAbortReason) -> LogRecord {
        SelfTestLog.event(t: now - runStart, step: currentStep, name: "abort", ["reason": reason.rawValue])
    }

    /// Step 6: incidents counted across the run.
    private func summary(_ now: Double) -> LogRecord {
        var steps: [String: Bool] = [:]
        for r in results { steps[r.id.logName] = r.pass }
        return SelfTestLog.event(t: now - runStart, step: nil, name: "run_summary",
                                 ["tracking_incidents": trackingIncidents, "ble_disconnects": bleDisconnects, "steps": steps,
                                  "state": "\(state)"])
    }

    private func cleanMetrics(_ m: [String: Double]) -> [String: Double] {
        m.filter { $0.value.isFinite }.mapValues { SelfTestLog.round3($0) }
    }
}
