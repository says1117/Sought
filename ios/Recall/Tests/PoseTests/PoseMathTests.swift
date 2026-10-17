import XCTest
import simd
#if canImport(PoseCore)
@testable import PoseCore
#endif

final class PoseMathTests: XCTestCase {
    /// Camera transform at (x, y, z) rotated `deg` CCW about +y (viewed from above), then pitched by `pitchDeg` about local x.
    private func transform(x: Float = 0, y: Float = 0, z: Float = 0, yawDeg deg: Float = 0, pitchDeg: Float = 0) -> simd_float4x4 {
        let yaw = simd_quatf(angle: deg * .pi / 180, axis: [0, 1, 0])
        let pitch = simd_quatf(angle: pitchDeg * .pi / 180, axis: [1, 0, 0])
        var m = simd_float4x4(yaw * pitch)
        m.columns.3 = [x, y, z, 1]
        return m
    }

    func testIdentityFacesMinusZ() {
        let p = PoseMath.pose(from: transform())!
        XCTAssertEqual(p.yawDeg, 0, accuracy: 1e-4)
        XCTAssertEqual(p.x, 0); XCTAssertEqual(p.z, 0)
    }

    func testPositionIgnoresY() {
        let p = PoseMath.pose(from: transform(x: 1.2, y: 0.4, z: -3.4))!
        XCTAssertEqual(p.x, 1.2, accuracy: 1e-5)
        XCTAssertEqual(p.z, -3.4, accuracy: 1e-5)
    }

    func testCCWIsPositive() {
        // Rotating CCW about +y turns forward from -z toward -x (left).
        XCTAssertEqual(PoseMath.pose(from: transform(yawDeg: 90))!.yawDeg, 90, accuracy: 1e-3)
        XCTAssertEqual(PoseMath.pose(from: transform(yawDeg: -90))!.yawDeg, -90, accuracy: 1e-3)
        XCTAssertEqual(abs(PoseMath.pose(from: transform(yawDeg: 180))!.yawDeg), 180, accuracy: 1e-3)
        XCTAssertEqual(PoseMath.pose(from: transform(yawDeg: 45))!.yawDeg, 45, accuracy: 1e-3)
    }

    func testHeadingDirectionsFromWorldVectors() {
        XCTAssertEqual(PoseMath.yawDeg(headingX: 0, headingZ: -1), 0, accuracy: 1e-9)
        XCTAssertEqual(PoseMath.yawDeg(headingX: -1, headingZ: 0), 90, accuracy: 1e-9)   // left
        XCTAssertEqual(PoseMath.yawDeg(headingX: 1, headingZ: 0), -90, accuracy: 1e-9)   // right
        XCTAssertEqual(PoseMath.yawDeg(headingX: 0, headingZ: 1), 180, accuracy: 1e-9)
    }

    func testPitchDoesNotChangeYaw() {
        for pitch in [-60, -30, 30, 60] as [Float] {
            let p = PoseMath.pose(from: transform(yawDeg: 30, pitchDeg: pitch))!
            XCTAssertEqual(p.yawDeg, 30, accuracy: 1e-3, "pitch \(pitch)")
        }
    }

    func testLookingStraightDownUsesPhoneTop() {
        // Pitch -90 about local x: camera looks down; phone top (local +y) then points to -z.
        let down = PoseMath.pose(from: transform(yawDeg: 0, pitchDeg: -90))!
        XCTAssertEqual(down.yawDeg, 0, accuracy: 1e-2)
        let downTurned = PoseMath.pose(from: transform(yawDeg: 90, pitchDeg: -90))!
        XCTAssertEqual(downTurned.yawDeg, 90, accuracy: 1e-2)
        // Looking straight up: top of phone points behind.
        let up = PoseMath.pose(from: transform(yawDeg: 0, pitchDeg: 90))!
        XCTAssertEqual(abs(up.yawDeg), 0, accuracy: 1e-2)
    }

    func testNormalizeAndShortestDelta() {
        XCTAssertEqual(PoseMath.normalizeDegrees(190), -170, accuracy: 1e-9)
        XCTAssertEqual(PoseMath.normalizeDegrees(-190), 170, accuracy: 1e-9)
        XCTAssertEqual(PoseMath.normalizeDegrees(180), 180, accuracy: 1e-9)
        XCTAssertEqual(PoseMath.normalizeDegrees(-180), 180, accuracy: 1e-9)
        XCTAssertEqual(PoseMath.normalizeDegrees(720), 0, accuracy: 1e-9)
        XCTAssertEqual(PoseMath.shortestDelta(from: 170, to: -170), 20, accuracy: 1e-9)   // CCW through 180
        XCTAssertEqual(PoseMath.shortestDelta(from: -170, to: 170), -20, accuracy: 1e-9)
    }

    func testFloorYPicksLowestLargePlane() {
        XCTAssertEqual(PoseMath.floorY(planes: [(-1.4, 4.0), (-0.7, 1.2), (-1.5, 0.05)]), -1.4)
        XCTAssertNil(PoseMath.floorY(planes: [(-1.5, 0.05)]))
        XCTAssertNil(PoseMath.floorY(planes: []))
    }

    func testRateLimiter() {
        var r = RateLimiter(maxHz: 30)
        XCTAssertTrue(r.shouldPublish(at: 0))
        XCTAssertFalse(r.shouldPublish(at: 0.010))
        XCTAssertTrue(r.shouldPublish(at: 0.034))
        XCTAssertFalse(r.shouldPublish(at: 0.050))
        XCTAssertTrue(r.shouldPublish(at: 0.0675))
    }

    func testContractStrings() {
        XCTAssertEqual(TrackingKind.notAvailable.rawValue, "not_available")
        XCTAssertEqual(MappingKind.extending.rawValue, "extending")
    }
}
