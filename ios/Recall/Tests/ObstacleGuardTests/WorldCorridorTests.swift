import XCTest
import simd
#if canImport(RecallShared)
import RecallShared
#endif
@testable import ObstacleGuardCore

/// Reproduces the rover: phone upright in portrait, 0.20 m above a flat floor, looking forward (-z).
/// ARKit camera axes for that pose: x (sensor long side) = world down, y = world +x, looking along -z.
final class WorldCorridorTests: XCTestCase {
    private let w = 64, h = 48
    private let k = DepthIntrinsics(fx: 40, fy: 40, cx: 32, cy: 24)

    private func portraitPose(height: Float = 0.20) -> simd_float4x4 {
        simd_float4x4(columns: (SIMD4(0, -1, 0, 0), SIMD4(1, 0, 0, 0), SIMD4(0, 0, 1, 0), SIMD4(0, height, 0, 1)))
    }

    /// Ray-cast depth (along the camera's -z) for a floor at y = 0, plus an optional box face at z = -boxZ.
    private func render(_ m: simd_float4x4, boxZ: Float? = nil) -> [Float] {
        var out = [Float](repeating: 0, count: w * h)
        let cam = SIMD3<Float>(m.columns.3.x, m.columns.3.y, m.columns.3.z)
        for v in 0..<h {
            for u in 0..<w {
                let dc = SIMD4<Float>((Float(u) - k.cx) / k.fx, -(Float(v) - k.cy) / k.fy, -1, 0)
                let d4 = m * dc
                let dw = SIMD3<Float>(d4.x, d4.y, d4.z)
                var t = Float.infinity
                if dw.y < 0 { t = min(t, -cam.y / dw.y) }                 // floor
                if let bz = boxZ, dw.z < 0 {
                    let tb = (-bz - cam.z) / dw.z
                    let p = cam + tb * dw
                    if abs(p.x) < 0.15, p.y >= 0, p.y <= 0.30 { t = min(t, tb) }
                }
                out[v * w + u] = t.isFinite && t <= 5 ? t : 0          // t is depth along -z (dc.z = -1)
            }
        }
        return out
    }

    func testPortraitFloorIsNotAnObstacle() {
        let m = portraitPose()
        let r = CorridorSampler.sampleWorld(depth: render(m), width: w, height: h, intrinsics: k, cameraToWorld: m, floorY: 0)
        XCTAssertNil(r.minDistanceM, "floor counted as obstacle: \(r.obstacleSamples) hits")
        XCTAssertGreaterThan(r.validSamples, 100)
    }

    func testOldFixedMountSamplerMisreadsThePortraitFloor() {
        // Documents the rover bug: in portrait the fixed-mount sampler (roll 0) puts the floor's vertical offset on
        // its lateral axis; at 0.20 m it sits just outside the 0.175 m half-width, at 0.17 m the whole floor is
        // "in the corridor" and the nearest visible floor (~0.2-0.3 m) becomes the obstacle (seen: 0.27 m, ~4000 hits).
        let m = portraitPose(height: 0.17)
        let old = CorridorSampler.sample(depth: render(m), width: w, height: h, intrinsics: k)
        XCTAssertNotNil(old.minDistanceM)
        XCTAssertGreaterThan(old.obstacleSamples, 500)
        let fixed = CorridorSampler.sampleWorld(depth: render(m), width: w, height: h, intrinsics: k, cameraToWorld: m, floorY: 0)
        XCTAssertNil(fixed.minDistanceM, "world sampler counted \(fixed.obstacleSamples) floor hits")
    }

    func testPortraitBoxAheadIsFoundAtItsDistance() {
        let m = portraitPose()
        let r = CorridorSampler.sampleWorld(depth: render(m, boxZ: 1.0), width: w, height: h, intrinsics: k, cameraToWorld: m, floorY: 0)
        XCTAssertEqual(r.minDistanceM ?? -1, 1.0, accuracy: 0.02)
    }

    func testTiltedDownPhoneStillIgnoresFloor() {
        // Same pose pitched 10 degrees down (rotate about the world x axis).
        let a: Float = 10 * .pi / 180
        let pitch = simd_float4x4(simd_quatf(angle: -a, axis: SIMD3(1, 0, 0)))
        var m = pitch * portraitPose()
        m.columns.3 = SIMD4(0, 0.20, 0, 1)
        let r = CorridorSampler.sampleWorld(depth: render(m), width: w, height: h, intrinsics: k, cameraToWorld: m, floorY: 0)
        XCTAssertNil(r.minDistanceM, "tilted floor counted: \(r.obstacleSamples) hits")
    }
}
