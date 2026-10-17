import Foundation

// Come-to-me approach logic (docs/01_ROBOTICS_PLAN.md section 3.6). Pure state machine, Foundation only, no Controller
// or UWB types, so it builds and tests without a device. The runner (ComeToMeRunner.swift) feeds it UWB samples and
// executes the actions it returns with the Controller.
//
// Contract with the runner:
//  - call `start(now:)`, then `step(_:)` repeatedly (about 10 Hz while idle/waiting).
//  - when a rotate/drive action's motion ends, call `motionFinished(at:)`. The planner then returns `.wait` until a
//    UWB sample newer than that time arrives, so it never decides on a reading taken while the rover was moving.
//
// ALL NUMBERS BELOW ARE PLACEHOLDERS. Nothing here has been run on the rover or with a real UWB peer.

/// What the Vision person-confirm phase reports. `bearingDeg` is the person's angle from the camera axis in the
/// Controller convention (positive = left); `distanceM` is LiDAR depth at the person box if available.
struct PersonObservation: Equatable {
    var bearingDeg: Double
    var distanceM: Double?
}

/// Real implementation: VisionPersonDetector.swift (VNDetectHumanRectanglesRequest + sceneDepth). Tests use fakes.
protocol PersonDetector {
    func detect() async -> PersonObservation?
}

struct ApproachConfig {
    var stopDistance = 1.0            // plan: stop at 1.0 m
    var arriveMargin = 0.05
    var staleTimeout = 2.0            // plan: abort when no UWB update for more than 2 s
    var startupGrace = 5.0            // time allowed for the first ranging sample
    var overallTimeout = 120.0
    var turnThresholdDeg = 15.0       // bigger bearing errors are turned out in place before driving
    var segmentMax = 0.4              // meters per drive segment (the planner re-reads UWB between segments)
    var segmentMin = 0.05
    var farSpeedCap = 120             // wheel units; Controller.maxLinear is 160, so this is the lower cap
    var nearSpeedCap = 100            // inside visionRange (Controller.slowLinear)
    var visionRange = 2.5             // meters: Vision confirm phase starts inside this
    var visionConfirmTimeout = 8.0    // seconds at the stop distance waiting to see a person before arriving unconfirmed
    var probeMeters = 0.4             // search: drive this far, compare the range, estimate the bearing from the change
    var probeAlignedDeg = 35.0        // estimated angle under this and range dropping = keep driving straight
    var gradientMinImprovement = 0.05 // meters of range drop that count as downhill (above UWB noise; tune on the rover)
    var maxProbes = 15                // give up with `no_direction` after this many probes
}

enum ApproachAction: Equatable {
    case wait
    case rotate(deg: Double, speedCap: Int)                 // positive = left (counter-clockwise)
    case drive(meters: Double, bearingDeg: Double, speedCap: Int)   // drive toward a bearing relative to the heading
    case stop
}

struct ApproachInput {
    var now: Double
    var distanceM: Double?            // latest UWB range
    var bearingDeg: Double?           // UWB direction relative to heading, positive = left; nil when no direction
    var lastUpdateAt: Double?         // time of the latest UWB range sample
    var person: PersonObservation?    // from the Vision phase, nil if none seen this tick
    var visionAvailable: Bool
}

enum ApproachPhase: Equatable {
    case idle
    case approaching
    case searching
    case confirming
    case arrived(confirmed: Bool)
    case failed(String)
    case cancelled
}

struct ApproachPlanner {
    private(set) var phase: ApproachPhase = .idle
    private(set) var lastDistance: Double?
    let config: ApproachConfig

    private var startedAt = 0.0
    private var awaitSampleAfter: Double?
    private var confirmStartedAt: Double?

    // search state (probe-based: turning in place does not change the UWB range, only moving does)
    private var probeD0: Double?          // range before the pending probe drive; nil = no probe pending
    private var turnPending = false       // a corrective rotate was issued; take a fresh range before the next probe
    private var probeCount = 0
    private var turnSign = 1.0            // which way the last correction turned (+1 left); flipped when it did not help
    private var prevTheta: Double?

    init(config: ApproachConfig = ApproachConfig()) { self.config = config }

    var isFinished: Bool {
        switch phase { case .arrived, .failed, .cancelled: return true; default: return false }
    }

    mutating func start(now: Double) {
        phase = .approaching; startedAt = now; awaitSampleAfter = nil; confirmStartedAt = nil
        resetSearch(); probeCount = 0
    }

    mutating func failExternally(_ why: String) { if !isFinished { phase = .failed(why) } }
    mutating func cancel() { if !isFinished { phase = .cancelled } }
    mutating func motionFinished(at t: Double) { awaitSampleAfter = t }

    static func normalize(_ d: Double) -> Double {
        var r = d.truncatingRemainder(dividingBy: 360)
        if r > 180 { r -= 360 }
        if r <= -180 { r += 360 }
        return r
    }

    private mutating func fail(_ why: String) -> ApproachAction { phase = .failed(why); return .stop }

    private mutating func resetSearch() { probeD0 = nil; turnPending = false; prevTheta = nil; turnSign = 1 }

    mutating func step(_ i: ApproachInput) -> ApproachAction {
        if isFinished || phase == .idle { return .stop }
        if i.now - startedAt > config.overallTimeout { return fail("timeout") }

        // Lost-session rule: no UWB range for more than staleTimeout means stop and fail (contract 1.1).
        if let last = i.lastUpdateAt {
            if i.now - last > config.staleTimeout { return fail("uwb_lost") }
        } else if i.now - startedAt > config.startupGrace {
            return fail("no_uwb")
        } else {
            return .wait
        }
        guard let d = i.distanceM else { return .wait }
        lastDistance = d

        // Never decide on a sample taken before the last motion ended.
        if let after = awaitSampleAfter {
            if let last = i.lastUpdateAt, last > after { awaitSampleAfter = nil } else { return .wait }
        }

        // Arrival and the Vision person-confirm phase at the stop distance.
        let atStop = d <= config.stopDistance + config.arriveMargin
        let personClose = (i.person?.distanceM).map { $0 <= config.stopDistance } ?? false
        if atStop || personClose {
            guard i.visionAvailable else { phase = .arrived(confirmed: false); return .stop }
            if i.person != nil { phase = .arrived(confirmed: true); return .stop }
            if confirmStartedAt == nil { confirmStartedAt = i.now }
            phase = .confirming
            if i.now - confirmStartedAt! > config.visionConfirmTimeout { phase = .arrived(confirmed: false); return .stop }
            return .stop   // hold still while looking; the runner keeps calling step()
        }

        confirmStartedAt = nil
        let inVision = i.visionAvailable && d <= config.visionRange
        let cap = inVision ? config.nearSpeedCap : config.farSpeedCap
        // Inside vision range a seen person is the tighter bearing; otherwise use UWB direction.
        let bearing: Double? = (inVision ? i.person?.bearingDeg : nil) ?? i.bearingDeg

        if let b = bearing {
            if phase == .searching || phase == .confirming { phase = .approaching }
            resetSearch()
            if abs(b) > config.turnThresholdDeg { return .rotate(deg: b, speedCap: cap) }
            let seg = min(config.segmentMax, max(config.segmentMin, d - config.stopDistance))
            return .drive(meters: seg, bearingDeg: b, speedCap: cap)
        }
        return searchStep(distance: d, cap: cap)
    }

    /// Gradient search used when UWB gives distance but no direction. Drive a short probe, then use the range change
    /// and the law of cosines to estimate the angle between the travel direction and the user:
    ///   cos(theta) = (d0^2 + L^2 - d1^2) / (2 d0 L). The sign is unknown from one probe, so the first correction turns
    /// left and flips whenever the estimated angle did not shrink. Downhill (range falling, small angle) keeps driving.
    private mutating func searchStep(distance d: Double, cap: Int) -> ApproachAction {
        phase = .searching
        let L = config.probeMeters
        guard let d0 = probeD0 else {                    // no probe pending: start one from here
            probeD0 = d; turnPending = false
            return .drive(meters: L, bearingDeg: 0, speedCap: cap)
        }
        probeCount += 1
        if probeCount > config.maxProbes { return fail("no_direction") }
        let c = max(-1, min(1, (d0 * d0 + L * L - d * d) / (2 * d0 * L)))
        let theta = acos(c) * 180 / .pi
        if theta <= config.probeAlignedDeg && d < d0 - config.gradientMinImprovement {
            probeD0 = d; prevTheta = nil
            return .drive(meters: L, bearingDeg: 0, speedCap: cap)    // downhill: keep going
        }
        if let prev = prevTheta, theta >= prev - 5 { turnSign = -turnSign }
        prevTheta = theta
        probeD0 = nil
        return .rotate(deg: turnSign * max(theta, 20), speedCap: cap)   // next step probes again from the fresh range
    }

    /// Companion link status for the current phase (contract 1.1 `status.state` and `reason`).
    var companionStatus: (state: CompanionState, reason: String?) {
        switch phase {
        case .idle, .approaching, .searching, .confirming: return (.approaching, nil)
        case let .arrived(confirmed): return (.arrived, confirmed ? nil : "vision_unconfirmed")
        case let .failed(r): return (.failed, r)
        case .cancelled: return (.failed, "cancelled")
        }
    }
}
