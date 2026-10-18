import XCTest
#if canImport(CoordinatorCore)
@testable import CoordinatorCore
#endif
#if canImport(ControllerCore)
@testable import ControllerCore
#endif
#if canImport(PoseCore)
import PoseCore
#endif
#if canImport(Memory)
import Memory
#endif
#if canImport(FindExecutor)
import FindExecutor
#endif
#if canImport(TeachCore)
import TeachCore
#endif

// The coordinator's turns in place obey CoordinatorWiring.turnGuard (the app passes Scan here's turn guard);
// goTo keeps the full forward guard.
final class CoordinatorTurnGuardTests: XCTestCase {
    private func wiring(robot: CoordSimRobot, guardState: @escaping () -> GuardState,
                        turnGuard: (() -> GuardState)?) throws -> CoordinatorWiring {
        let ticks = CoordTickClock()
        var w = CoordinatorWiring(
            poses: robot, drive: robot, guardState: guardState, waypointStore: try WaypointStore(path: ":memory:"),
            trackStore: try TrackStore(path: ":memory:"), encoders: ModelsMissingEncoderProvider(),
            speaker: CoordTestSpeaker(), clock: CoordTestClock())
        w.turnGuard = turnGuard
        w.controllerClock = { ticks.tick() }
        w.controllerSleep = { _ in await Task.yield() }
        return w
    }

    /// Runs under a current lease token, as a coordinator task does, so LeasedDriveSink passes drive commands.
    private func leased<T>(_ w: CoordinatorWiring, _ body: () async -> T) async -> T {
        let token = w.lease.grant()
        XCTAssertNotNil(token)
        return await DriveLease.$token.withValue(token) { await body() }
    }

    func testRotateCompletesWhenForwardGuardStopsButTurnGuardIsClear() async throws {
        let robot = CoordSimRobot()
        let w = try wiring(robot: robot, guardState: { .stop }, turnGuard: { .clear })
        let controller = w.makeController()
        let status = await leased(w) { await controller.rotateBy(90) }
        XCTAssertEqual(status, .done)
        XCTAssertGreaterThan(robot.movingCommands, 0)
        XCTAssertLessThan(abs(PoseMath.shortestDelta(from: robot.latest().pose!.yawDeg, to: 90)),
                          ControllerTuning.rotateToleranceDeg + 5)
    }

    func testTurnGuardStopHoldsTheTurnWithZeroWheels() async throws {
        let robot = CoordSimRobot()
        let w = try wiring(robot: robot, guardState: { .clear }, turnGuard: { .stop })
        let controller = w.makeController()
        let status = await leased(w) { await controller.rotateBy(90) }
        XCTAssertEqual(status, .failed(.timeout))
        XCTAssertEqual(robot.movingCommands, 0)
        XCTAssertEqual(robot.latest().pose!.yawDeg, 0)
    }

    func testGoToStillStopsOnTheForwardGuard() async throws {
        let robot = CoordSimRobot()
        let w = try wiring(robot: robot, guardState: { .stop }, turnGuard: { .clear })
        let controller = w.makeController()
        let status = await leased(w) { await controller.goTo(x: 0, z: -2, stopDistance: 0.3) }
        XCTAssertEqual(status, .failed(.timeout))
        // Detours (controller, 2026-10-18): with the turn guard clear, a held goTo may turn in place to look for a
        // way around, but it must never translate into what the forward guard sees.
        XCTAssertEqual(robot.position.x, 0, accuracy: 1e-9, "a .clear turn guard must not let goTo drive")
        XCTAssertEqual(robot.position.z, 0, accuracy: 1e-9, "a .clear turn guard must not let goTo drive")
    }

    func testNoTurnGuardKeepsTheForwardGuardForTurns() async throws {
        let robot = CoordSimRobot()
        let w = try wiring(robot: robot, guardState: { .stop }, turnGuard: nil)
        let controller = w.makeController()
        let status = await leased(w) { await controller.rotateBy(90) }
        XCTAssertEqual(status, .failed(.timeout))
        XCTAssertEqual(robot.movingCommands, 0)
    }

    // Find's final facing turn: already within stop distance of an object 90° to the side, with something
    // close ahead (forward guard .stop). With the turn guard the rover turns to face it and arrives.
    func testFindFinalFacingTurnUsesTheTurnGuard() async throws {
        let robot = CoordSimRobot()
        let w = try wiring(robot: robot, guardState: { .stop }, turnGuard: { .clear })
        let driver = ControllerApproachDriver(controller: w.makeController(), poses: robot)
        let report = await leased(w) { await driver.approach(x: 1, z: 0, stopDistance: 2) }
        XCTAssertEqual(report.outcome, .arrived)
        XCTAssertLessThan(abs(PoseMath.shortestDelta(from: robot.latest().pose!.yawDeg, to: -90)),
                          ControllerTuning.rotateToleranceDeg + 5)
        XCTAssertEqual(robot.position.x, 0, accuracy: 1e-9, "turned in place, never drove")
        XCTAssertEqual(robot.position.z, 0, accuracy: 1e-9)
    }

    func testFindFinalFacingTurnHoldsWithoutTheTurnGuard() async throws {
        let robot = CoordSimRobot()
        let w = try wiring(robot: robot, guardState: { .stop }, turnGuard: nil)
        let driver = ControllerApproachDriver(controller: w.makeController(), poses: robot)
        let report = await leased(w) { await driver.approach(x: 1, z: 0, stopDistance: 2) }
        guard case .failed(let why) = report.outcome else { return XCTFail("expected failed") }
        XCTAssertTrue(why.hasPrefix("final turn timeout"), why)
        XCTAssertTrue(why.contains("fwd guard stop 100%"), why)
        XCTAssertEqual(robot.movingCommands, 0)
    }
}
