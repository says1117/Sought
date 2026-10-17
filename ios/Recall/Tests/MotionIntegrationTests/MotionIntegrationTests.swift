import XCTest
#if canImport(ControllerCore)
@testable import ControllerCore
#endif
#if canImport(ObstacleGuardCore)
@testable import ObstacleGuardCore
#endif
#if canImport(PoseCore)
@testable import PoseCore
#endif

final class MotionIntegrationTests: XCTestCase {
    func testSonarStopIsHonoredByGoTo() {
        let obstacle = ObstacleLogic.evaluate(corridor: nil,
            sonar: SonarSample(frontCm: 10, rearCm: 999, flags: 2))
        var session = ControlSession(goal: .goTo(x: 0, z: -2, stopDistance: 0.2))
        let output = session.tick(TickInput(pose: Pose2D(x: 0, z: 0, yawDeg: 0),
            tracking: .normal, guardState: obstacle.level == .stop ? .stop : .clear, now: 0))
        XCTAssertEqual(output.command, .zero)
        XCTAssertEqual(output.status, .running)
    }

    func testPoseAndControllerShareCounterClockwiseConvention() {
        let error = ControllerMath.headingError(pose: Pose2D(x: 0, z: 0, yawDeg: 0), targetX: -1, targetZ: 0)
        XCTAssertEqual(error, 90, accuracy: 1e-9)
        let wheels = ControllerMath.wheels(linear: 0, angular: ControllerMath.turnCommand(errDeg: error))
        XCTAssertLessThan(wheels.left, wheels.right)
    }

    func testUnusableNearDepthCannotBecomeClearInput() {
        let depth = CorridorSampler.sample(depth: Array(repeating: 0.1, count: 16), width: 4, height: 4,
            intrinsics: DepthIntrinsics(fx: 3, fy: 3, cx: 2, cy: 2))
        let result = ObstacleLogic.evaluate(corridor: depth,
            sonar: SonarSample(frontCm: 999, rearCm: 999, flags: 0))
        XCTAssertTrue(depth.isBlind())
        XCTAssertEqual(result.level, .slow)
    }
}
