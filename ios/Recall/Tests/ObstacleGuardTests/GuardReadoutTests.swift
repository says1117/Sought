import XCTest
#if canImport(RecallShared)
import RecallShared
#endif
@testable import ObstacleGuardCore

final class GuardReadoutTests: XCTestCase {
    private func corridor(_ m: Float?) -> CorridorResult {
        CorridorResult(minDistanceM: m, obstacleSamples: m == nil ? 0 : 50, validSamples: 900, totalSamples: 1000)
    }

    func testStaleSaysTurnsHeld() {
        let t = GuardReadout.text(corridor: corridor(nil), sonar: nil, ageS: 0.9, staleAfterS: 0.5)
        XCTAssertTrue(t.hasPrefix("Forward guard: STALE (0.9 s old). Turns held."), t)
    }

    func testLidarStopNamesReasonAndDistance() {
        let t = GuardReadout.text(corridor: corridor(0.3), sonar: SonarSample(frontCm: 999, rearCm: 80, flags: 8),
                                  ageS: 0.1, staleAfterS: 0.5)
        XCTAssertTrue(t.contains("Forward guard: STOP (LiDAR). Turns allowed."), t)
        XCTAssertTrue(t.contains("Sonar front no echo · rear 80 cm · flags 8"), t)
        XCTAssertTrue(t.contains("LiDAR nearest 0.30 m (50 hits)"), t)
    }

    func testSonarFlagWins() {
        let t = GuardReadout.text(corridor: corridor(nil), sonar: SonarSample(frontCm: 12, rearCm: 999, flags: 10),
                                  ageS: 0, staleAfterS: 0.5)
        XCTAssertTrue(t.contains("STOP (ESP32 sonar flag)"), t)
        XCTAssertTrue(t.contains("LiDAR: corridor clear"), t)
    }

    func testClearAndMissingInputs() {
        let t = GuardReadout.text(corridor: nil, sonar: nil, ageS: 0, staleAfterS: 0.5)
        XCTAssertTrue(t.contains("Sonar: no telemetry"), t)
        XCTAssertTrue(t.contains("LiDAR: no depth frame"), t)
    }
}
