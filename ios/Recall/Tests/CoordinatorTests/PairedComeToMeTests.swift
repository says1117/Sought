import XCTest
#if canImport(CoordinatorCore)
@testable import CoordinatorCore
#endif
#if canImport(ComeToMeCore)
@testable import ComeToMeCore
#endif
#if canImport(ControllerCore)
@testable import ControllerCore
#endif
#if canImport(PoseCore)
import PoseCore
#endif

private final class PairedCoordTestRange: RangingSource {
    var value = RangeSample(distanceM: 0.9, bearingDeg: 0, updatedAt: 10)
    func latest() -> RangeSample { value }
}

private final class PairedCoordTestMotion: ApproachMotion {
    var drives = 0, stops = 0
    func drive(meters: Double, bearingDeg: Double, speedCap: Int) async -> ControlStatus { drives += 1; return .done }
    func rotate(deg: Double, speedCap: Int) async -> ControlStatus { drives += 1; return .done }
    func stop() { stops += 1 }
}

final class PairedComeToMeTests: XCTestCase {
    func testUnverifiedPairCannotConstructMotion() async throws {
        let motion = PairedCoordTestMotion()
        let adapter = PairedComeToMeAdapter(ranging: PairedCoordTestRange(), makeMotion: {
            XCTFail("unpaired request must not construct motion"); return motion
        })
        let result = try await adapter.comeToMe()
        guard case .refused = result else { return XCTFail("expected refusal") }
        XCTAssertEqual(motion.drives, 0)
    }

    func testCancelBeforeAdmissionStaysCancelled() async throws {
        let request = PairedComeRequest(id: "request-a")
        let motion = PairedCoordTestMotion()
        let adapter = PairedComeToMeAdapter(ranging: PairedCoordTestRange(), isReady: { true }, makeMotion: { motion })
        adapter.cancel(request: request)
        let result = try await PairedComeContext.$request.withValue(request) { try await adapter.comeToMe() }
        XCTAssertEqual(result, .cancelled)
        XCTAssertEqual(motion.drives, 0)
    }

    func testCancellationDuringReadinessCheckPreventsRun() async throws {
        let request = PairedComeRequest(id: "request-a")
        let motion = PairedCoordTestMotion()
        let adapter = PairedComeToMeAdapter(ranging: PairedCoordTestRange(), isReady: { request.cancel(); return true },
                                           makeMotion: { motion }, clock: { 10 })
        let result = try await PairedComeContext.$request.withValue(request) { try await adapter.comeToMe() }
        XCTAssertEqual(result, .cancelled)
        XCTAssertEqual(motion.drives, 0)
    }

    func testFreshNearbyPairedPhoneArrivesWithoutMovement() async throws {
        let motion = PairedCoordTestMotion()
        let adapter = PairedComeToMeAdapter(ranging: PairedCoordTestRange(), isReady: { true }, makeMotion: { motion }, clock: { 10 })
        let result = try await adapter.comeToMe()
        guard case .completed = result else { return XCTFail("expected arrival") }
        XCTAssertEqual(motion.drives, 0)
        XCTAssertGreaterThan(motion.stops, 0)
    }

    func testDisablingGuidanceRemovesCoordinates() {
        let range = PairedCoordTestRange()
        let gate = PairedGuidanceSource(source: range)
        XCTAssertNil(gate.latest().distanceM)
        gate.setEnabled(true)
        XCTAssertEqual(gate.latest().distanceM, 0.9)
        gate.setEnabled(false)
        XCTAssertNil(gate.latest().bearingDeg)
    }

    func testCancelledControllerEpochPreventsLaterSegment() async {
        let robot = CoordSimRobot()
        let motion = PairedControllerMotion(poses: robot, sink: robot, guardState: { .clear })
        motion.stop()
        let result = await motion.drive(meters: 0.25, bearingDeg: 0, speedCap: 100)
        XCTAssertEqual(result, .failed(.cancelled))
        XCTAssertEqual(robot.movingCommands, 0)
    }

    func testFinalShortSegmentDoesNotFallInsideExtraControllerStandOff() async {
        let robot = CoordSimRobot()
        let motion = PairedControllerMotion(poses: robot, sink: robot, guardState: { .clear })
        let result = await motion.drive(meters: 0.06, bearingDeg: 0, speedCap: 100)
        XCTAssertEqual(result, .done)
        XCTAssertGreaterThan(robot.movingCommands, 0, "an extra 5 cm stand-off would silently skip this segment")
    }
}
