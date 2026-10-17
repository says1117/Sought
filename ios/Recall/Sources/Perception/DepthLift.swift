import Foundation
import simd
#if canImport(RecallShared)
import RecallShared
#endif

public struct LiftedPoint: Equatable {
    public var world: SIMD3<Float>
    public var depth: Float
    public var heightAboveFloor: Float
}

/// Depth to 3D (docs/01_ROBOTICS_PLAN.md 4.3). Camera frame is ARKit's: x right, y up, forward = -z.
public enum DepthLift {
    public static let maxDepth: Float = 5.0
    public static let centralFraction: Float = 0.3

    /// Median valid depth over the central 30% (by area) of `box`. nil if no valid sample or the median is > 5 m.
    public static func medianDepth(_ depth: DepthMap, box: NormBox) -> Float? {
        let c = box.clamped().central(areaFraction: centralFraction)
        guard c.area > 0 else { return nil }
        let u0 = max(0, Int((c.x * Float(depth.width)).rounded(.down)))
        let v0 = max(0, Int((c.y * Float(depth.height)).rounded(.down)))
        let u1 = min(depth.width, max(u0 + 1, Int(((c.x + c.w) * Float(depth.width)).rounded(.up))))
        let v1 = min(depth.height, max(v0 + 1, Int(((c.y + c.h) * Float(depth.height)).rounded(.up))))
        guard u0 < u1, v0 < v1 else { return nil }
        var samples: [Float] = []
        for v in v0..<v1 { for u in u0..<u1 {
            let d = depth.values[v * depth.width + u]
            if d.isFinite, d > 0 { samples.append(d) }
        } }
        guard !samples.isEmpty else { return nil }
        samples.sort()
        let n = samples.count
        let median = n % 2 == 1 ? samples[n / 2] : (samples[n / 2 - 1] + samples[n / 2]) / 2
        return median <= maxDepth ? median : nil
    }

    /// Unproject pixel (u, v) at `depth` metres to the world frame.
    public static func unproject(u: Float, v: Float, depth: Float, intrinsics k: DepthIntrinsics,
                                 cameraToWorld: simd_float4x4) -> SIMD3<Float> {
        let cam = SIMD4<Float>((u - k.cx) / k.fx * depth, -(v - k.cy) / k.fy * depth, -depth, 1)
        let w = cameraToWorld * cam
        return SIMD3(w.x, w.y, w.z)
    }

    /// Full lift for one box. Intrinsics are scaled from colour-image to depth-map resolution.
    public static func lift(box: NormBox, depth: DepthMap, geometry g: KeyframeGeometry) -> LiftedPoint? {
        guard let d = medianDepth(depth, box: box) else { return nil }
        let k = DepthIntrinsics(fx: g.fx, fy: g.fy, cx: g.cx, cy: g.cy)
            .scaled(fromWidth: g.imageWidth, fromHeight: g.imageHeight, toWidth: depth.width, toHeight: depth.height)
        let c = box.clamped().center
        let p = unproject(u: c.x * Float(depth.width), v: c.y * Float(depth.height), depth: d,
                          intrinsics: k, cameraToWorld: g.cameraToWorld)
        return LiftedPoint(world: p, depth: d, heightAboveFloor: p.y - g.floorY)
    }
}
