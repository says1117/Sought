import XCTest
#if canImport(ObstacleGuardCore)
@testable import ObstacleGuardCore
#endif

/// Remote Teach "back <x> m": the reverse holds on the rear flag, a close rear echo, no sonar, and stale readings.
final class RearGuardTests: XCTestCase {
    func testRearGuard() {
        XCTAssertFalse(RearGuard.hold(sonar: SonarSample(frontCm: 50, rearCm: 999, flags: 0), stale: false), "no echo behind = clear")
        XCTAssertFalse(RearGuard.hold(sonar: SonarSample(frontCm: 10, rearCm: 100, flags: GuardConfig.flagFrontBlocked), stale: false),
                       "the front flag does not block reversing")
        XCTAssertTrue(RearGuard.hold(sonar: SonarSample(frontCm: 50, rearCm: 999, flags: GuardConfig.flagRearBlocked), stale: false))
        XCTAssertTrue(RearGuard.hold(sonar: SonarSample(frontCm: 50, rearCm: 20, flags: 0), stale: false))
        XCTAssertTrue(RearGuard.hold(sonar: nil, stale: false))
        XCTAssertTrue(RearGuard.hold(sonar: SonarSample(frontCm: 50, rearCm: 999, flags: 0), stale: true))
    }
}
