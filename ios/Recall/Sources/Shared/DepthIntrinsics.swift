import Foundation

/// Pinhole intrinsics in depth-image pixels (u right, v down).
/// Shared by ObstacleGuard (corridor sampling) and OccupancyGrid (depth integration).
public struct DepthIntrinsics: Equatable {
    public var fx: Float, fy: Float, cx: Float, cy: Float
    public init(fx: Float, fy: Float, cx: Float, cy: Float) {
        self.fx = fx; self.fy = fy; self.cx = cx; self.cy = cy
    }

    /// Scale intrinsics captured at `from` resolution to the depth buffer resolution.
    public func scaled(fromWidth: Int, fromHeight: Int, toWidth: Int, toHeight: Int) -> DepthIntrinsics {
        let sx = Float(toWidth) / Float(fromWidth), sy = Float(toHeight) / Float(fromHeight)
        return DepthIntrinsics(fx: fx * sx, fy: fy * sy, cx: cx * sx, cy: cy * sy)
    }
}
