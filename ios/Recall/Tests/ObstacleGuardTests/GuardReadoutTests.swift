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
        XCTAssertTrue(t.hasPrefix("Forward guard: STALE (0.9 s old)"), t)
        XCTAssertTrue(t.contains("Scan turns: HELD (readings stale)"), t)
    }

    func testLidarStopStillAllowsScanTurns() {
        let t = GuardReadout.text(corridor: corridor(0.3), sonar: SonarSample(frontCm: 999, rearCm: 80, flags: 8),
                                  ageS: 0.1, staleAfterS: 0.5)
        XCTAssertTrue(t.contains("Forward guard: STOP (LiDAR)"), t)
        XCTAssertTrue(t.contains("Scan turns: allowed"), t)
        XCTAssertTrue(t.contains("Sonar front no echo · rear 80 cm · flags 8"), t)
        XCTAssertTrue(t.contains("LiDAR nearest 0.30 m (50 hits)"), t)
    }

    func testSonarFlagWinsAndHoldsTurns() {
        let t = GuardReadout.text(corridor: corridor(nil), sonar: SonarSample(frontCm: 12, rearCm: 999, flags: 10),
                                  ageS: 0, staleAfterS: 0.5)
        XCTAssertTrue(t.contains("STOP (ESP32 sonar flag)"), t)
        XCTAssertTrue(t.contains("Scan turns: HELD (front sonar < 20 cm)"), t)
        XCTAssertTrue(t.contains("LiDAR: corridor clear"), t)
    }

    func testClearAndMissingInputs() {
        let t = GuardReadout.text(corridor: nil, sonar: nil, ageS: 0, staleAfterS: 0.5)
        XCTAssertTrue(t.contains("Scan turns: HELD (no sonar telemetry)"), t)
        XCTAssertTrue(t.contains("Sonar: no telemetry"), t)
        XCTAssertTrue(t.contains("LiDAR: no depth frame"), t)
    }

    // MARK: TurnGuard (the scan turn policy)

    func testTurnGuardHoldsOnCloseFlagsBothDirections() {
        XCTAssertEqual(TurnGuard.hold(sonar: SonarSample(frontCm: 10, rearCm: 999, flags: 2 | 8), stale: false), .frontFlag)
        XCTAssertEqual(TurnGuard.hold(sonar: SonarSample(frontCm: 999, rearCm: 10, flags: 4 | 8), stale: false), .rearFlag)
        XCTAssertNotNil(TurnGuard.hold(sonar: SonarSample(frontCm: 10, rearCm: 10, flags: 2 | 4 | 8), stale: false))
    }

    func testTurnGuardFailsClosedOnMissingOrStale() {
        XCTAssertEqual(TurnGuard.hold(sonar: nil, stale: false), .noSonar)
        XCTAssertEqual(TurnGuard.hold(sonar: SonarSample(frontCm: 100, rearCm: 100, flags: 8), stale: true), .stale)
    }

    func testTurnGuardIgnoresThirtyFiveCentimetreForwardStop() {
        // 30 cm front: the forward guard stops (< 0.35 m) but no ESP32 flag is set, so a scan turn may proceed.
        let s = SonarSample(frontCm: 30, rearCm: 999, flags: 8)
        XCTAssertEqual(ObstacleLogic.evaluate(corridor: nil, sonar: s).level, .stop)
        XCTAssertNil(TurnGuard.hold(sonar: s, stale: false))
    }
}
