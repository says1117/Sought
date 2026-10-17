import Foundation
#if canImport(PoseCore)
import PoseCore
#endif

// Motion self-test: shared types. Foundation + PoseMath only, so everything here builds and unit tests without a device.
// Frame and conventions: docs/03_CONTRACTS.md sections 0 and 1 (meters, yaw CCW positive, angular > 0 turns left,
// L = linear - angular, R = linear + angular).
//
// EVERY NUMBER IN SelfTestConfig IS A PLACEHOLDER. Nothing here has been run on the rover. The program reports only what it
// measures; pass/fail limits are "to be calibrated by Steven, not measured".

enum SelfTestStepID: Int, CaseIterable, Comparable {
    case wheelsOff = 0, watchdog, forwardBack, square, spin, obstacle

    static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }

    /// Name used in the JSONL log and by tools/motion_report.py. Do not rename without updating the analyzer.
    var logName: String {
        switch self {
        case .wheelsOff: return "wheels_off"
        case .watchdog: return "watchdog"
        case .forwardBack: return "forward_back"
        case .square: return "square"
        case .spin: return "spin"
        case .obstacle: return "obstacle"
        }
    }

    var title: String {
        switch self {
        case .wheelsOff: return "0  Wheels-off drive check"
        case .watchdog: return "1  Watchdog"
        case .forwardBack: return "2  Forward 1 m and back"
        case .square: return "3  2 m square and return"
        case .spin: return "4  360 degree spin"
        case .obstacle: return "5  Front obstacle"
        }
    }

    /// Steps 0 and 1 run with the wheels off the ground and need no pose.
    var needsPose: Bool { self >= .forwardBack }
}

struct SelfTestConfig {
    // Safety. PLACEHOLDER speeds: low, but above the deadband only if Steven's bench test says so.
    var testPwm = 110                    // |L| and |R| used for straight legs and spins
    var maxPwm = 130                     // hard cap applied to every command the engine emits
    var slowPwm = 90                     // forward speed when ObstacleGuard says slow
    var motionSegmentTimeoutS = 30.0     // hard timeout per motion segment (a leg, a turn, an approach)
    var trackingAbortS = 1.0             // abort when tracking != normal for longer than this on a pose step
    var statusLossAbortS = 1.0           // abort when no status line for this long while running
    var firstStatusWaitS = 3.0           // how long to wait for the first status line before aborting

    // Step 0: wheels off
    var wheelPhaseS = 1.6
    var wheelSettleS = 0.8               // ramping: ignore statuses this soon after a command change
    var wheelRestS = 0.6
    var wheelToleranceUnits = 25.0       // |applied - commanded| allowed (firmware ramps and trims)
    var minStatusHz = 4.0                // contract says 5 Hz

    // Step 1: watchdog (contract: 300 ms)
    var watchdogLimitS = 0.3
    var statusPeriodS = 0.2              // measurement resolution: status is 5 Hz
    var watchdogMarginS = 0.1
    var watchdogObserveS = 1.5
    var watchdogResumeWaitS = 1.0

    // Step 2: forward and back
    var forwardTargetM = 1.0
    var settleS = 1.0
    var fwdDistanceErrLimitM = 0.10      // PLACEHOLDER
    var fwdLateralDriftLimitM = 0.10     // PLACEHOLDER
    var fwdReturnErrLimitM = 0.15        // PLACEHOLDER (plan: 15 cm decides mast vs low mount)

    // Step 3: square
    var squareSideM = 2.0
    var squareTurnDeg = 90.0
    var squareFinalErrLimitM = 0.15      // PLACEHOLDER (plan R0.5: above 15 cm -> mast)
    var squareOverallTimeoutS = 180.0

    // Step 4: spin
    var spinDeg = 360.0
    var spinYawErrLimitDeg = 15.0        // PLACEHOLDER

    // Step 5: obstacle
    var contactMarginCm = 10.0           // PLACEHOLDER: front sonar must stay above this
    var firmwareFrontStopCm = 20         // contract: front < 20 cm clamps forward
    var clampTolerance = 15.0            // applied linear above this while flag 2 is set = clamp failed
    var blockedPhaseS = 1.0
    var blockedSpinS = 0.8
    var blockedReverseS = 1.0
    var obstacleOverallTimeoutS = 90.0

    static let `default` = SelfTestConfig()

    func cap(_ v: Int) -> Int { max(-maxPwm, min(maxPwm, v)) }
    var watchdogPassLimitS: Double { watchdogLimitS + statusPeriodS + watchdogMarginS }

    /// Whole-step cap, excluding time spent waiting for a human.
    func stepCapS(_ id: SelfTestStepID) -> Double {
        switch id {
        case .square: return squareOverallTimeoutS
        case .obstacle: return obstacleOverallTimeoutS
        default: return motionSegmentTimeoutS * 2   // 0, 1, 2, 4 are made of short segments, each separately limited
        }
    }

    /// Echoed into the log meta record so a report can show which limits the app used.
    var logDictionary: [String: Any] {
        ["test_pwm": testPwm, "max_pwm": maxPwm, "motion_segment_timeout_s": motionSegmentTimeoutS,
         "tracking_abort_s": trackingAbortS, "min_status_hz": minStatusHz,
         "watchdog_pass_limit_s": watchdogPassLimitS, "forward_target_m": forwardTargetM,
         "square_side_m": squareSideM, "spin_deg": spinDeg, "contact_margin_cm": contactMarginCm,
         "thresholds_status": "placeholder, to be calibrated by Steven, not measured"]
    }
}

/// One status line from the ESP32 with the phone's receive time (seconds, same clock as the engine).
struct TimedStatus: Equatable {
    var t: Double
    var uptimeMs: Int
    var left: Int
    var right: Int
    var frontCm: Int
    var rearCm: Int
    var flags: Int

    static let flagWatchdog = 1, flagFront = 2, flagRear = 4, flagBle = 8
    static let noEcho = 999

    var watchdogStopped: Bool { flags & Self.flagWatchdog != 0 }
    var frontBlocked: Bool { flags & Self.flagFront != 0 }
    var rearBlocked: Bool { flags & Self.flagRear != 0 }
    var bleConnected: Bool { flags & Self.flagBle != 0 }
    /// Applied linear and angular, contract definition.
    var linear: Double { Double(left + right) / 2 }
    var angular: Double { Double(right - left) / 2 }
    var frontDistanceCm: Int? { frontCm >= Self.noEcho || frontCm <= 0 ? nil : frontCm }
}

/// ObstacleGuard output reduced to what the self-test needs (the guard's own enum names collide with the controller's).
enum SelfTestGuardLevel: Equatable { case clear, slow, stop }

enum SelfTestAbortReason: String, Equatable {
    case userStop = "user_stop"
    case trackingLost = "tracking_lost"
    case bleDisconnected = "ble_disconnected"
    case noStatus = "no_status"
    case stepTimeout = "step_timeout"
    case checklistNotConfirmed = "checklist_not_confirmed"
}

/// What the engine wants the drive link to do this tick.
enum SelfTestCommand: Equatable {
    case drive(left: Int, right: Int)
    case stop
    /// Send nothing at all (watchdog step): the glue suspends the 10 Hz heartbeat.
    case silent
}

struct SelfTestInput {
    var now: Double
    var pose: Pose2D?
    var tracking: TrackingKind
    /// Status lines received since the previous tick, oldest first.
    var statuses: [TimedStatus] = []
    var bleConnected: Bool
    /// nil = no guard feed available.
    var guardLevel: SelfTestGuardLevel?
    /// True on the tick the human pressed Continue.
    var confirm = false
}

struct StepResult: Equatable {
    var id: SelfTestStepID
    var pass: Bool
    var reason: String
    var metrics: [String: Double]
}

/// JSONL record helpers. One JSON object per line, sorted keys, every record has `type` and `t` (seconds since run start).
typealias LogRecord = [String: Any]

enum SelfTestLog {
    static let schema = "selftest.v1"

    /// Returns nil when the record cannot be serialized (e.g. contains NaN).
    static func line(_ record: LogRecord) -> String? {
        guard JSONSerialization.isValidJSONObject(record),
              let d = try? JSONSerialization.data(withJSONObject: record, options: [.sortedKeys]),
              let s = String(data: d, encoding: .utf8) else { return nil }
        return s
    }

    static func event(t: Double, step: SelfTestStepID?, name: String, _ extra: LogRecord = [:]) -> LogRecord {
        var r = extra
        r["type"] = "event"; r["t"] = round3(t); r["name"] = name
        if let step { r["step"] = step.logName }
        return r
    }

    static func round3(_ v: Double) -> Double { (v * 1000).rounded() / 1000 }
}
