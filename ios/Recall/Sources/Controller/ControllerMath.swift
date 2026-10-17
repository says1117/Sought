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
    static let turnInPlaceAboveDeg = 20.0       // plan: |err| > 20 deg turns in place
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
    static let timeout = 30.0                   // plan: fail on 30 s timeout
    static let trackingLossLimit = 1.0          // plan: stop if tracking != normal for > 1 s
    static let rotateToleranceDeg = 5.0         // PLACEHOLDER rotateBy is done inside this
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
    static func goToStep(errDeg: Double, dist: Double, stopDist: Double, guardState: GuardState)
        -> (linear: Double, angular: Double) {
        if guardState == .stop { return (0, 0) }
        if abs(errDeg) > ControllerTuning.turnInPlaceAboveDeg {
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
    private var trackingBadSince: Double?
    private var doneStreak = 0
    private var rotateTargetYaw: Double?
    private(set) var status: ControlStatus = .running

    init(goal: Goal) { self.goal = goal }

    private var timeout: Double {
        if case .rotateBy = goal { return ControllerTuning.rotateTimeout }
        return ControllerTuning.timeout
    }

    mutating func tick(_ input: TickInput) -> TickOutput {
        if status != .running { return TickOutput(command: .zero, status: status) }
        if startTime == nil { startTime = input.now }

        // Tracking loss: hold still immediately, fail after trackingLossLimit.
        guard input.tracking == .normal, let pose = input.pose else {
            if trackingBadSince == nil { trackingBadSince = input.now }
            if input.now - trackingBadSince! > ControllerTuning.trackingLossLimit {
                return finish(.failed(.trackingLost))
            }
            return TickOutput(command: .zero, status: .running)
        }
        trackingBadSince = nil

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
            let (lin, ang) = ControllerMath.goToStep(errDeg: err, dist: dist, stopDist: stopDist, guardState: input.guardState)
            return TickOutput(command: ControllerMath.wheels(linear: lin, angular: ang), status: .running)

        case .rotateBy(let deg):
            if rotateTargetYaw == nil { rotateTargetYaw = PoseMath.normalizeDegrees(pose.yawDeg + deg) }
            let err = PoseMath.shortestDelta(from: pose.yawDeg, to: rotateTargetYaw!)
            if abs(err) < ControllerTuning.rotateToleranceDeg {
                doneStreak += 1
                if doneStreak >= ControllerTuning.doneTicks { return finish(.done) }
                return TickOutput(command: .zero, status: .running)
            }
            doneStreak = 0
            return TickOutput(command: ControllerMath.wheels(linear: 0, angular: ControllerMath.turnCommand(errDeg: err)),
                              status: .running)
        }
    }

    private mutating func finish(_ s: ControlStatus) -> TickOutput {
        status = s
        return TickOutput(command: .zero, status: s)
    }
}
