import Foundation
#if canImport(PoseCore)
import PoseCore
#endif

// Pure go-to-pose math (docs/01_ROBOTICS_PLAN.md section 3.3). Foundation only, so it builds and tests without a device.
// Frame: ARKit world, meters, y up, yaw CCW-positive viewed from above, 0 deg points to -z (docs/03_CONTRACTS.md section 0).
// Wheel units are the BLE units, -255...255.
//
// ALL NUMBERS BELOW ARE PLACEHOLDERS. Nothing here has been run on the rover. Min/max speeds, gains and the
// turn threshold must be tuned on the robot (carpet vs floor changes the minimum command that moves it).
// No accuracy is claimed for any of this.

/// Sign between "err > 0 (target is to the left)" and the `angular` command. Contract: angular > 0 turns left,
/// and err > 0 means the target is counter-clockwise (left) of the heading, so +1 should be right.
/// First drive test: if a positive angular does not reduce err, flip this ONE value. It is the only place.
let TURN_SIGN: Double = 1

enum ControllerTuning {
    static let tickHz = 10.0                    // plan: run at 10 Hz
    static let turnInPlaceAboveDeg = 20.0       // plan: |err| > 20 deg turns in place (deciding from rest)
    // Go-to hysteresis, so the rover does not micro-adjust (turn, creep, turn back) around one threshold. On the
    // rover the minimum turn command plus BLE/ARKit lag overshoots, the same problem rotateBy solved below.
    static let keepDrivingBelowDeg = 40.0       // PLACEHOLDER once driving, steer while moving up to this error
    static let spinDoneBelowDeg = 8.0           // PLACEHOLDER a turn in place ends inside this (or once past the bearing)
    // Near the goal a few cm of offset or pose noise is a large bearing error. Inside this much travel left, steer
    // while moving instead of spinning, unless the target is behind (> 90 deg).
    static let nearGoalM = 0.4                  // PLACEHOLDER
    // Inside this much travel left with the target beside or behind (> 60 deg), the rover drove past it: arrived.
    static let passedGoalSlackM = 0.15          // PLACEHOLDER
    // Detours (plan 3.4; ObstacleGuard has the same numbers but nothing drove them). A go-to held still by the
    // forward guard for this long, with the turn guard clear (sonar present, fresh, no close-range flag), turns in
    // place and drives out a little instead of freezing until the deadline.
    static let detourAfterHoldS = 2.0           // PLACEHOLDER
    static let detourMarginDeg = 20.0           // PLACEHOLDER keep turning this far past the first clear heading
    static let detourMaxTurnDeg = 120.0         // PLACEHOLDER no clear heading within this: try the other side next
    static let detourDriveM = 0.6               // PLACEHOLDER straight run on the detour heading before re-aiming
    static let maxDetours = 3                   // PLACEHOLDER without progress; then hold as before
    static let detourProgressM = 0.3            // PLACEHOLDER this much closer to the goal refills the detour budget
    static let kpTurn = 2.0                     // PLACEHOLDER wheel units per deg while turning in place
    static let minTurn = 90.0                   // PLACEHOLDER smallest command that rotates the rover (find by test)
    static let maxTurn = 150.0                  // PLACEHOLDER
    static let kv = 200.0                       // PLACEHOLDER wheel units per meter of remaining distance
    static let minLinear = 90.0                 // PLACEHOLDER
    static let maxLinear = 160.0                // PLACEHOLDER (cap further during evals)
    static let slowLinear = 100.0               // PLACEHOLDER cap inside slowdownRadius and when the guard says slow
    static let slowdownRadius = 0.5             // plan: slow down inside 0.5 m of the goal
    static let kh = 2.0                         // PLACEHOLDER wheel units per deg of heading correction while driving
    static let doneMargin = 0.05                // plan: done when dist < stopDist + 0.05
    static let doneTicks = 3                    // plan: for 3 consecutive ticks
    static let timeout = 30.0                   // minimum goTo budget
    static let goToSetupSeconds = 15.0          // PLACEHOLDER allowance for turning/settling
    static let goToSecondsPerMeter = 12.0       // PLACEHOLDER, not measured travel speed
    static let goToMaximumTimeout = 75.0        // leaves 15 s before the app's 90 s poll deadline
    static let trackingLossLimit = 1.0          // plan: stop if tracking != normal for > 1 s
    static let rotateToleranceDeg = 10.0        // rotateBy is done inside this (or once past the target). 5 hunted on the rover
    static let rotateTimeout = 15.0             // PLACEHOLDER
}

/// Output of ObstacleGuard (another task). The controller only consumes it.
enum GuardState: Equatable { case clear, slow, stop }

enum FailureReason: Equatable { case timeout, trackingLost, cancelled }

enum ControlStatus: Equatable {
    case running
    case done
    case failed(FailureReason)
}

struct WheelCommand: Equatable {
    var left: Int
    var right: Int
    static let zero = WheelCommand(left: 0, right: 0)
}

enum ControllerMath {
    static func clamp(_ v: Double, _ lo: Double, _ hi: Double) -> Double { max(lo, min(hi, v)) }

    /// Fixed run budget from the first valid pose; remaining travel excludes the arrival stop distance.
    static func goToTimeout(distance: Double, stopDistance: Double) -> Double {
        guard distance.isFinite, stopDistance.isFinite else { return ControllerTuning.timeout }
        let remaining = max(0, distance - max(0, stopDistance))
        return clamp(ControllerTuning.goToSetupSeconds + ControllerTuning.goToSecondsPerMeter * remaining,
                     ControllerTuning.timeout, ControllerTuning.goToMaximumTimeout)
    }

    /// Contract convention: L = linear - angular, R = linear + angular, clamped to -255...255.
    /// (Same mapping as DriveProtocol.mix; kept local so this module has no dependency on the BLE module.)
    static func wheels(linear: Double, angular: Double) -> WheelCommand {
        func c(_ v: Double) -> Int { Int(clamp(v.rounded(), -255, 255)) }
        return WheelCommand(left: c(linear - angular), right: c(linear + angular))
    }

    /// Signed heading error in degrees, (-180, 180]. Positive = the target is counter-clockwise (left) of the heading.
    static func headingError(pose: Pose2D, targetX: Double, targetZ: Double) -> Double {
        let bearing = PoseMath.yawDeg(headingX: targetX - pose.x, headingZ: targetZ - pose.z)
        return PoseMath.shortestDelta(from: pose.yawDeg, to: bearing)
    }

    static func distance(pose: Pose2D, targetX: Double, targetZ: Double) -> Double {
        let dx = targetX - pose.x, dz = targetZ - pose.z
        return (dx * dx + dz * dz).squareRoot()
    }

    /// Turn-in-place angular command: proportional, magnitude held in minTurn...maxTurn so the rover actually rotates.
    static func turnCommand(errDeg: Double) -> Double {
        let mag = clamp(abs(ControllerTuning.kpTurn * errDeg), ControllerTuning.minTurn, ControllerTuning.maxTurn)
        return TURN_SIGN * (errDeg < 0 ? -mag : mag)
    }

    /// One go-to step: (linear, angular) in wheel units. Does not decide "done"; the session counts ticks.
    /// `spin`: the session's turn-in-place decision (with hysteresis); nil = the plain 20 deg threshold.
    static func goToStep(errDeg: Double, dist: Double, stopDist: Double, guardState: GuardState, spin: Bool? = nil)
        -> (linear: Double, angular: Double) {
        if guardState == .stop { return (0, 0) }
        if spin ?? (abs(errDeg) > ControllerTuning.turnInPlaceAboveDeg) {
            return (0, turnCommand(errDeg: errDeg))
        }
        var maxLin = ControllerTuning.maxLinear
        if dist < ControllerTuning.slowdownRadius || guardState == .slow {
            maxLin = min(maxLin, ControllerTuning.slowLinear)
        }
        let linear = clamp(ControllerTuning.kv * (dist - stopDist), ControllerTuning.minLinear, maxLin)
        return (linear, TURN_SIGN * ControllerTuning.kh * errDeg)
    }
}

struct TickInput {
    var pose: Pose2D?
    var tracking: TrackingKind
    var guardState: GuardState
    var now: Double            // seconds, any monotonic clock
    /// Guard used by rotateBy instead of `guardState` when set. A turn in place has no forward motion, so a caller
    /// can pass a guard that only stops on stale sensors (Scan here). nil = rotateBy obeys `guardState`.
    var turnGuardState: GuardState? = nil
}

struct TickOutput: Equatable {
    var command: WheelCommand
    var status: ControlStatus
}

/// One go-to or rotate attempt as a pure state machine: feed it a tick, get a wheel command and a status.
struct ControlSession {
    enum Goal {
        case goTo(x: Double, z: Double, stopDistance: Double)
        case rotateBy(deg: Double)
    }

    let goal: Goal
    private var startTime: Double?
    private var goToBudget: Double?
    private var trackingBadSince: Double?
    private var doneStreak = 0
    private var spinning = false            // go-to: currently turning in place
    private var spinStartSign: Double?
    private var hasDriven = false           // go-to: has driven forward this run (raises the spin threshold)
    private var guardStopSince: Double?     // go-to: forward guard has held the wheels since
    private(set) var detoursUsed = 0           // total this run (diagnostics)
    private var detoursWithoutProgress = 0
    private var detourSide: Double?           // +1 left / -1 right; kept while it works
    private var distAtLastDetour: Double?
    private var detour: Detour?
    private struct Detour {
        var sign: Double
        var startYaw: Double
        var clearAtTurnedDeg: Double?         // how far it had turned when the forward guard first cleared
        var driving = false
        var startX = 0.0, startZ = 0.0
    }
    private var rotateTargetYaw: Double?
    private var rotateStartSign: Double?
    private(set) var status: ControlStatus = .running

    init(goal: Goal) { self.goal = goal }

    private var timeout: Double {
        if case .rotateBy = goal { return ControllerTuning.rotateTimeout }
        return goToBudget ?? ControllerTuning.timeout
    }

    mutating func tick(_ input: TickInput) -> TickOutput {
        if status != .running { return TickOutput(command: .zero, status: status) }
        if startTime == nil { startTime = input.now }

        // Tracking loss: hold still immediately, fail after trackingLossLimit.
        guard input.tracking == .normal, let pose = input.pose,
              pose.x.isFinite, pose.z.isFinite, pose.yawDeg.isFinite else {
            doneStreak = 0
            if trackingBadSince == nil { trackingBadSince = input.now }
            if input.now - trackingBadSince! > ControllerTuning.trackingLossLimit {
                return finish(.failed(.trackingLost))
            }
            return TickOutput(command: .zero, status: .running)
        }
        trackingBadSince = nil

        if goToBudget == nil, case .goTo(let x, let z, let stopDist) = goal {
            goToBudget = ControllerMath.goToTimeout(
                distance: ControllerMath.distance(pose: pose, targetX: x, targetZ: z), stopDistance: stopDist)
        }

        if input.now - startTime! > timeout { return finish(.failed(.timeout)) }

        switch goal {
        case .goTo(let x, let z, let stopDist):
            let dist = ControllerMath.distance(pose: pose, targetX: x, targetZ: z)
            if dist < stopDist + ControllerTuning.doneMargin {
                doneStreak += 1
                if doneStreak >= ControllerTuning.doneTicks { return finish(.done) }
                return TickOutput(command: .zero, status: .running)   // in the done zone: hold still
            }
            doneStreak = 0
            let err = ControllerMath.headingError(pose: pose, targetX: x, targetZ: z)
            let remaining = dist - stopDist
            // Drove past it: close, with the target beside or behind. Turning around to chase a few cm is the
            // micro-adjusting seen on the rover; this is arrived.
            if remaining < ControllerTuning.passedGoalSlackM && abs(err) > 60 { return finish(.done) }
            if let d0 = distAtLastDetour, d0 - dist >= ControllerTuning.detourProgressM {
                detoursWithoutProgress = 0; distAtLastDetour = nil      // real progress: refill the budget
            }
            if let out = detourStep(pose: pose, input: input) { return out }
            let turning = decideSpin(err: err, remaining: remaining)
            if !turning, input.guardState == .stop, let out = maybeStartDetour(pose: pose, err: err, dist: dist, input: input) {
                return out
            }
            if turning || input.guardState != .stop { guardStopSince = nil }
            // Above the turn-in-place threshold goToStep sends no forward motion, so obey the turn guard (when set),
            // as rotateBy does. Otherwise an obstacle ahead held the wheels at zero and the find timed out without
            // ever facing the target (seen on the rover). Driving forward still obeys the full forward guard.
            let g = turning ? (input.turnGuardState ?? input.guardState) : input.guardState
            let (lin, ang) = ControllerMath.goToStep(errDeg: err, dist: dist, stopDist: stopDist, guardState: g,
                                                     spin: turning)
            if !turning && lin > 0 { hasDriven = true }
            return TickOutput(command: ControllerMath.wheels(linear: lin, angular: ang), status: .running)

        case .rotateBy(let deg):
            if (input.turnGuardState ?? input.guardState) == .stop {
                doneStreak = 0
                return TickOutput(command: .zero, status: .running)
            }
            if rotateTargetYaw == nil { rotateTargetYaw = PoseMath.normalizeDegrees(pose.yawDeg + deg) }
            let err = PoseMath.shortestDelta(from: pose.yawDeg, to: rotateTargetYaw!)
            if rotateStartSign == nil { rotateStartSign = err < 0 ? -1 : 1 }
            // Done inside the tolerance, or as soon as the heading has passed the target. On the rover the minimum
            // turn command plus BLE/ARKit lag overshoots a few degrees per tick, and reversing to chase a tight
            // window made it swing left-right until the timeout. A small overshoot is fine for a turn in place.
            // |err| < 90 keeps a ±180 wrap (far from the target) from looking like a crossing.
            let crossed = (err < 0 ? -1.0 : 1.0) != rotateStartSign! && abs(err) < 90
            if abs(err) < ControllerTuning.rotateToleranceDeg || crossed { return finish(.done) }
            return TickOutput(command: ControllerMath.wheels(linear: 0, angular: ControllerMath.turnCommand(errDeg: err)),
                              status: .running)
        }
    }

    /// Runs an active detour: turn in place (obeying the turn guard) toward one side until the forward guard reads
    /// clear, plus a margin; then drive straight out on that heading (obeying the forward guard) for detourDriveM.
    /// nil = no detour active (any more); continue the normal go-to, which re-aims at the goal.
    private mutating func detourStep(pose: Pose2D, input: TickInput) -> TickOutput? {
        guard var d = detour else { return nil }
        if !d.driving {
            if (input.turnGuardState ?? input.guardState) == .stop { return TickOutput(command: .zero, status: .running) }
            let turned = abs(PoseMath.shortestDelta(from: d.startYaw, to: pose.yawDeg))
            if d.clearAtTurnedDeg == nil, input.guardState != .stop { d.clearAtTurnedDeg = turned }
            if d.clearAtTurnedDeg != nil, input.guardState == .stop { d.clearAtTurnedDeg = nil }   // only a gap; keep turning
            if let c = d.clearAtTurnedDeg, turned >= c + ControllerTuning.detourMarginDeg {
                d.driving = true; d.startX = pose.x; d.startZ = pose.z; detour = d
                detourSide = d.sign                                                // this side worked: keep it
            } else if turned >= ControllerTuning.detourMaxTurnDeg {
                detour = nil; detourSide = -d.sign; guardStopSince = nil           // nothing clear this way
                return TickOutput(command: .zero, status: .running)
            } else {
                detour = d
                return TickOutput(command: ControllerMath.wheels(linear: 0, angular: TURN_SIGN * d.sign * ControllerTuning.minTurn),
                                  status: .running)
            }
        }
        let moved = ((pose.x - d.startX) * (pose.x - d.startX) + (pose.z - d.startZ) * (pose.z - d.startZ)).squareRoot()
        // Done driving out, or blocked again: back to the normal go-to (which may start the next detour).
        if moved >= ControllerTuning.detourDriveM || input.guardState == .stop {
            detour = nil; spinning = false; spinStartSign = nil; guardStopSince = nil
            if moved > 0.05 { hasDriven = true }
            return nil
        }
        return TickOutput(command: ControllerMath.wheels(linear: ControllerTuning.slowLinear, angular: 0), status: .running)
    }

    /// Forward guard holding a go-to: after detourAfterHoldS start a detour if the turn guard is wired and clear
    /// and fewer than maxDetours ran without progress. First side: toward the goal. nil = keep holding.
    private mutating func maybeStartDetour(pose: Pose2D, err: Double, dist: Double, input: TickInput) -> TickOutput? {
        if guardStopSince == nil { guardStopSince = input.now }
        guard input.now - guardStopSince! >= ControllerTuning.detourAfterHoldS,
              detoursWithoutProgress < ControllerTuning.maxDetours,
              let turnGuard = input.turnGuardState, turnGuard == .clear else { return nil }
        let sign = detourSide ?? (err < 0 ? -1 : 1)
        detoursUsed += 1; detoursWithoutProgress += 1
        if distAtLastDetour == nil { distAtLastDetour = dist }
        detour = Detour(sign: sign, startYaw: pose.yawDeg)
        guardStopSince = nil
        return TickOutput(command: .zero, status: .running)
    }

    /// Turn-in-place decision with hysteresis. Start above 20 deg from rest (40 once driving; 90 near the goal);
    /// stop inside 8 deg or as soon as the heading passes the bearing, like rotateBy, instead of chasing it back.
    private mutating func decideSpin(err: Double, remaining: Double) -> Bool {
        let sign: Double = err < 0 ? -1 : 1
        if spinning {
            let crossed = sign != spinStartSign && abs(err) < 90
            if abs(err) < ControllerTuning.spinDoneBelowDeg || crossed { spinning = false; spinStartSign = nil }
        } else {
            var start = hasDriven ? ControllerTuning.keepDrivingBelowDeg : ControllerTuning.turnInPlaceAboveDeg
            if remaining < ControllerTuning.nearGoalM { start = max(start, 90) }
            if abs(err) > start { spinning = true; spinStartSign = sign }
        }
        return spinning
    }

    private mutating func finish(_ s: ControlStatus) -> TickOutput {
        status = s
        return TickOutput(command: .zero, status: s)
    }
}
