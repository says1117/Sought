import Foundation

// Pure decision logic and detour state machine. No ARKit, no BLE.

public enum ObstacleLevel: Int, Comparable {
    case clear = 0, slow, stop
    public static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }
}

public enum TravelDirection { case forward, reverse }

/// ESP32 sonar telemetry (docs/03_CONTRACTS.md section 1). 999 cm means no echo, NOT a distance.
public struct SonarSample: Equatable {
    public var frontCm: Int
    public var rearCm: Int
    public var flags: Int
    public init(frontCm: Int, rearCm: Int, flags: Int) {
        self.frontCm = frontCm; self.rearCm = rearCm; self.flags = flags
    }

    /// Distance in meters for a raw cm value, or nil for no echo / invalid.
    public static func meters(fromCm cm: Int) -> Float? {
        (cm <= 0 || cm >= GuardConfig.sonarNoEcho) ? nil : Float(cm) / 100
    }
}

public enum GuardReason: Equatable {
    case sonarFlag, sonarDistance, lidarDistance, lidarBlind, none
}

public struct LevelResult: Equatable {
    public var level: ObstacleLevel
    public var reason: GuardReason
    /// True when the ESP32 flag forced the result. Detours must not be debounced then.
    public var sonarForced: Bool { reason == .sonarFlag || (reason == .sonarDistance && level == .stop) }
}

public enum ObstacleLogic {
    /// Combines LiDAR corridor and sonar. Sonar flags always win (a set flag means stop even if LiDAR is clear).
    /// - corridor: nil means no depth frame available; treated as blind (cautious: slow).
    /// - sonar: nil means no telemetry yet; no sonar contribution.
    public static func evaluate(corridor: CorridorResult?, sonar: SonarSample?,
                                direction: TravelDirection = .forward) -> LevelResult {
        if let s = sonar {
            let flag = direction == .forward ? GuardConfig.flagFrontBlocked : GuardConfig.flagRearBlocked
            if s.flags & flag != 0 { return LevelResult(level: .stop, reason: .sonarFlag) }
        }

        var best = LevelResult(level: .clear, reason: .none)
        func consider(_ m: Float?, _ reason: GuardReason) {
            guard let m else { return }
            let l: ObstacleLevel = m < GuardConfig.stopBelowM ? .stop : (m < GuardConfig.slowBelowM ? .slow : .clear)
            if l > best.level { best = LevelResult(level: l, reason: reason) }
        }
        if let s = sonar {
            consider(SonarSample.meters(fromCm: direction == .forward ? s.frontCm : s.rearCm), .sonarDistance)
        }
        // LiDAR only describes what is ahead of the camera; it says nothing when reversing.
        if direction == .forward {
            if let c = corridor, !c.isBlind() {
                consider(c.minDistanceM, .lidarDistance)
            } else if best.level == .clear {
                best = LevelResult(level: .slow, reason: .lidarBlind)
            }
        }
        return best
    }
}

public enum GuardState: Equatable {
    case driving
    case detouring(attempt: Int)   // rotation in progress, waiting for detourFinished()
    case retrying(attempt: Int)    // rotation done, re-checking the path
    case gaveUp
}

public enum GuardEvent: Equatable {
    case announceBlocked
    /// Rotate in place by this many degrees (positive = counter-clockwise, same sign as yaw in the contract).
    case startDetour(degrees: Double, attempt: Int)
    case gaveUp(attempts: Int)
}

public struct GuardOutput: Equatable {
    public var level: ObstacleLevel
    public var reason: GuardReason
    public var state: GuardState
    /// 1 = full speed, 0 = stop. Placeholder scale for `slow`.
    public var speedScale: Float
    /// Usually empty. A first blockage emits [.announceBlocked, .startDetour].
    public var events: [GuardEvent]
}

public struct ObstacleGuard {
    public private(set) var state: GuardState = .driving
    public private(set) var detoursUsed = 0
    private var stopStreak = 0
    private var clearTravelM = 0.0
    private let maxDetours: Int
    private let detourDegrees: Double
    private let confirmFrames: Int
    public static let slowSpeedScale: Float = 0.4   // PLACEHOLDER

    /// `detourDegrees` sign picks the turn side.
    public init(maxDetours: Int = GuardConfig.maxDetours,
                detourDegrees: Double = GuardConfig.detourDegrees,
                confirmFrames: Int = GuardConfig.stopConfirmFrames) {
        self.maxDetours = maxDetours; self.detourDegrees = detourDegrees; self.confirmFrames = confirmFrames
    }

    /// New goal or user override: refill the detour budget.
    public mutating func reset() {
        state = .driving; detoursUsed = 0; stopStreak = 0; clearTravelM = 0
    }

    /// The controller calls this when the commanded detour rotation has finished.
    public mutating func detourFinished() {
        if case .detouring(let a) = state { state = .retrying(attempt: a); stopStreak = 0 }
    }

    /// Clear travel since the last update; enough of it refills the detour budget.
    public mutating func noteTravel(meters: Double) {
        guard state == .driving, detoursUsed > 0 else { return }
        clearTravelM += meters
        if clearTravelM >= GuardConfig.progressResetM { detoursUsed = 0; clearTravelM = 0 }
    }

    public mutating func update(corridor: CorridorResult?, sonar: SonarSample?,
                                direction: TravelDirection = .forward) -> GuardOutput {
        let r = ObstacleLogic.evaluate(corridor: corridor, sonar: sonar, direction: direction)
        var events: [GuardEvent] = []

        switch state {
        case .gaveUp:
            break  // latched until reset()
        case .detouring:
            break  // rotating in place; keep outputting stop below
        case .driving, .retrying:
            if r.level == .stop {
                stopStreak += 1
                let confirmed = r.sonarForced || stopStreak >= confirmFrames
                if confirmed {
                    stopStreak = 0
                    if detoursUsed >= maxDetours {
                        state = .gaveUp
                        events = [.gaveUp(attempts: detoursUsed)]
                    } else {
                        let first = (state == .driving)
                        detoursUsed += 1
                        state = .detouring(attempt: detoursUsed)
                        // Announce once per blockage, not once per retry.
                        if first { events.append(.announceBlocked) }
                        events.append(.startDetour(degrees: detourDegrees, attempt: detoursUsed))
                    }
                }
            } else {
                stopStreak = 0
                if case .retrying = state { state = .driving; clearTravelM = 0 }
            }
        }

        let level: ObstacleLevel
        switch state {
        case .detouring, .gaveUp: level = .stop
        default: level = r.level
        }
        let scale: Float = level == .stop ? 0 : (level == .slow ? Self.slowSpeedScale : 1)
        return GuardOutput(level: level, reason: r.reason, state: state, speedScale: scale, events: events)
    }
}
