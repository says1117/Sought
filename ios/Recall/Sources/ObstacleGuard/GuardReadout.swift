import Foundation

// Plain-text view of what the forward obstacle guard sees right now, for the Scan here debug line.
// Pure (no ARKit, no BLE) so it is unit tested.

/// Guard for a turn in place (Scan here). The 35 cm forward stops (LiDAR corridor, sonar distance) do not apply:
/// a pure rotation has no forward motion. No swept-footprint clearance rule exists yet, so it still holds on the
/// ESP32's own close-range flags (front < 20 cm, rear < 15 cm), on missing sonar telemetry, and on stale readings.
public enum TurnGuard {
    public enum Hold: Equatable { case stale, noSonar, frontFlag, rearFlag }

    /// nil = the turn may proceed.
    public static func hold(sonar: SonarSample?, stale: Bool) -> Hold? {
        if stale { return .stale }
        guard let s = sonar else { return .noSonar }
        if s.flags & GuardConfig.flagFrontBlocked != 0 { return .frontFlag }
        if s.flags & GuardConfig.flagRearBlocked != 0 { return .rearFlag }
        return nil
    }

    static func name(_ h: Hold) -> String {
        switch h {
        case .stale: return "readings stale"
        case .noSonar: return "no sonar telemetry"
        case .frontFlag: return "front sonar < 20 cm"
        case .rearFlag: return "rear sonar < 15 cm"
        }
    }
}

public enum GuardReadout {
    /// - ageS: seconds since the sensor cache was last written; older than `staleAfterS` means the readings are stale.
    public static func text(corridor: CorridorResult?, sonar: SonarSample?, ageS: Double, staleAfterS: Double) -> String {
        let r = ObstacleLogic.evaluate(corridor: corridor, sonar: sonar, direction: .forward)
        let stale = ageS > staleAfterS
        var lines: [String] = []
        if stale {
            lines.append(String(format: "Forward guard: STALE (%.1f s old)", ageS))
        } else {
            lines.append("Forward guard: \(levelName(r.level))\(r.reason == .none ? "" : " (\(reasonName(r.reason)))")")
        }
        if let h = TurnGuard.hold(sonar: sonar, stale: stale) {
            lines.append("Scan turns: HELD (\(TurnGuard.name(h)))")
        } else {
            lines.append("Scan turns: allowed")
        }
        if let s = sonar {
            lines.append("Sonar front \(cmText(s.frontCm)) · rear \(cmText(s.rearCm)) · flags \(s.flags)")
        } else {
            lines.append("Sonar: no telemetry")
        }
        if let c = corridor {
            if c.isBlind() {
                lines.append("LiDAR: blind (\(c.validSamples)/\(c.totalSamples) valid)")
            } else if let m = c.minDistanceM {
                lines.append(String(format: "LiDAR nearest %.2f m (%d hits)", m, c.obstacleSamples))
            } else {
                lines.append("LiDAR: corridor clear")
            }
        } else {
            lines.append("LiDAR: no depth frame")
        }
        return lines.joined(separator: "\n")
    }

    static func levelName(_ l: ObstacleLevel) -> String {
        switch l { case .clear: return "clear"; case .slow: return "SLOW"; case .stop: return "STOP" }
    }

    static func reasonName(_ r: GuardReason) -> String {
        switch r {
        case .sonarFlag: return "ESP32 sonar flag"
        case .sonarDistance: return "front sonar"
        case .lidarDistance: return "LiDAR"
        case .lidarBlind: return "LiDAR blind"
        case .none: return ""
        }
    }

    static func cmText(_ cm: Int) -> String { SonarSample.meters(fromCm: cm) == nil ? "no echo" : "\(cm) cm" }
}
