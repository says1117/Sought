import simd

// Pure pose math. No ARKit imports so it can be built and tested without a device.
// Frame: ARKit world, meters, y up. Robot forward is -z of the camera transform.
// Yaw is degrees, counter-clockwise positive viewed from above, 0 deg points to -z (docs/03_CONTRACTS.md section 0).

public struct Pose2D: Equatable {
    public var x: Double
    public var z: Double
    public var yawDeg: Double
    public init(x: Double, z: Double, yawDeg: Double) {
        self.x = x; self.z = z; self.yawDeg = yawDeg
    }
}

/// Contract strings: `tracking` in docs/03_CONTRACTS.md section 2.1.
public enum TrackingKind: String {
    case normal, limited
    case notAvailable = "not_available"
}

/// Contract strings: `mapping_status`.
public enum MappingKind: String {
    case mapped, limited, extending
    case notAvailable = "not_available"
}

public enum PoseMath {
    /// Wraps to (-180, 180].
    public static func normalizeDegrees(_ d: Double) -> Double {
        var r = d.truncatingRemainder(dividingBy: 360)
        if r > 180 { r -= 360 }
        if r <= -180 { r += 360 }
        return r
    }

    /// Signed shortest rotation from `from` to `to`, in (-180, 180]. Positive = counter-clockwise (left).
    public static func shortestDelta(from: Double, to: Double) -> Double {
        normalizeDegrees(to - from)
    }

    /// Yaw of a horizontal heading vector given as world (x, z). Left of -z is positive.
    public static func yawDeg(headingX: Double, headingZ: Double) -> Double {
        // normalize so straight backward is +180 (atan2 of -0.0 gives -180) and zero is never -0.0
        normalizeDegrees(atan2(-headingX, -headingZ) * 180 / .pi) + 0
    }

    /// Horizontal heading (x, z), unit length, of the camera forward axis (-z of the transform)
    /// projected onto the horizontal plane. If the camera looks almost straight up or down the forward
    /// projection is unusable, so fall back to the phone's up axis (top of the phone points ahead when
    /// looking down, behind when looking up). Returns nil if both are degenerate.
    public static func horizontalHeading(_ t: simd_float4x4, minLength: Double = 1e-3) -> (x: Double, z: Double)? {
        let fwd = -t.columns.2
        let fx = Double(fwd.x), fz = Double(fwd.z)
        let len = (fx * fx + fz * fz).squareRoot()
        if len >= minLength { return (fx / len, fz / len) }
        let up = t.columns.1
        let sign: Double = fwd.y < 0 ? 1 : -1
        let ux = sign * Double(up.x), uz = sign * Double(up.z)
        let ulen = (ux * ux + uz * uz).squareRoot()
        if ulen >= minLength { return (ux / ulen, uz / ulen) }
        return nil
    }

    /// Camera transform to (x, z, yaw_deg). Nil only if the heading is degenerate.
    public static func pose(from t: simd_float4x4) -> Pose2D? {
        guard let h = horizontalHeading(t) else { return nil }
        return Pose2D(x: Double(t.columns.3.x), z: Double(t.columns.3.z),
                      yawDeg: yawDeg(headingX: h.x, headingZ: h.z))
    }

    /// Floor height from detected horizontal planes (world y, area m^2): the lowest plane with at
    /// least `minArea`. Tables and sofas are above the floor, so lowest wins.
    public static func floorY(planes: [(y: Double, area: Double)], minArea: Double = 0.25) -> Double? {
        planes.filter { $0.area >= minArea }.map { $0.y }.min()
    }
}

/// Limits publishing to at most `maxHz` by frame timestamp (seconds).
public struct RateLimiter {
    public let minInterval: Double
    private var last: Double?
    public init(maxHz: Double) { minInterval = 1.0 / maxHz }

    public mutating func shouldPublish(at t: Double) -> Bool {
        if let l = last, t - l < minInterval - 1e-9 { return false }
        last = t
        return true
    }
}
