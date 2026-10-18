import Foundation
import simd
#if canImport(RecallShared)
import RecallShared
#endif

// Pure corridor sampling over a depth buffer. No ARKit, so it can be unit tested without a device.
//
// Camera frame: x right, y down, z forward (optical axis), as in ARKit's depth image.
// The buffer holds depth in meters along z, row-major, `width * height` floats.
// 0, NaN, infinite or negative depth means "no measurement".

public struct CameraMount: Equatable {
    public var heightM: Float
    /// Tilt of the optical axis below horizontal, degrees.
    public var pitchDownDeg: Float
    /// Rotation of the image about the optical axis, degrees. Use this if the phone is mounted rotated.
    public var rollDeg: Float
    public init(heightM: Float = GuardConfig.cameraHeightM,
                pitchDownDeg: Float = GuardConfig.cameraPitchDownDeg,
                rollDeg: Float = 0) {
        self.heightM = heightM; self.pitchDownDeg = pitchDownDeg; self.rollDeg = rollDeg
    }
}

public struct Corridor: Equatable {
    /// Full width of the corridor (rover width plus margin).
    public var widthM: Float
    public var floorClearanceM: Float
    public var topM: Float
    public var maxRangeM: Float
    public var lidarMinRangeM: Float
    public init(widthM: Float = GuardConfig.roverWidthM + GuardConfig.corridorMarginM,
                floorClearanceM: Float = GuardConfig.floorClearanceM,
                topM: Float = GuardConfig.corridorTopM,
                maxRangeM: Float = GuardConfig.maxRangeM,
                lidarMinRangeM: Float = GuardConfig.lidarMinRangeM) {
        self.widthM = widthM; self.floorClearanceM = floorClearanceM; self.topM = topM
        self.maxRangeM = maxRangeM; self.lidarMinRangeM = lidarMinRangeM
    }
}

public struct CorridorResult: Equatable {
    /// Nearest horizontal distance to a corridor point, or nil if no obstacle was seen.
    public var minDistanceM: Float?
    public var obstacleSamples: Int
    public var validSamples: Int
    public var totalSamples: Int

    /// True when too few pixels carried a measurement to say anything. "Blind" is NOT "clear".
    public func isBlind(minValidFraction: Float = GuardConfig.minValidFraction) -> Bool {
        totalSamples == 0 || Float(validSamples) / Float(totalSamples) < minValidFraction
    }
}

public enum CorridorSampler {
    /// - Parameter stride: sample every `stride`th pixel in each direction (1 = every pixel).
    public static func sample(depth: [Float], width: Int, height: Int,
                              intrinsics k: DepthIntrinsics,
                              mount: CameraMount = CameraMount(),
                              corridor: Corridor = Corridor(),
                              minObstacleSamples: Int = GuardConfig.minObstacleSamples,
                              stride step: Int = 1) -> CorridorResult {
        guard width > 0, height > 0, height <= depth.count / width,
              k.fx.isFinite, k.fy.isFinite, k.cx.isFinite, k.cy.isFinite,
              k.fx > 0, k.fy > 0, step > 0 else {
            return CorridorResult(minDistanceM: nil, obstacleSamples: 0, validSamples: 0, totalSamples: 0)
        }
        let pitch = mount.pitchDownDeg * .pi / 180
        let roll = mount.rollDeg * .pi / 180
        let (sp, cp) = (sin(pitch), cos(pitch))
        let (sr, cr) = (sin(roll), cos(roll))
        let half = corridor.widthM / 2

        var minD: Float = .infinity
        var hits = 0, valid = 0, total = 0
        var v = 0
        while v < height {
            var u = 0
            while u < width {
                total += 1
                let d = depth[v * width + u]
                if d.isFinite && d >= corridor.lidarMinRangeM && d > 0 {
                    valid += 1
                    if d >= corridor.lidarMinRangeM {
                        // Back-project, then undo mount roll and pitch to get a level frame.
                        let px = (Float(u) - k.cx) / k.fx * d
                        let py = (Float(v) - k.cy) / k.fy * d
                        let x = px * cr - py * sr
                        let y = px * sr + py * cr
                        let forward = d * cp - y * sp
                        let down = y * cp + d * sp
                        let heightAboveFloor = mount.heightM - down
                        if forward > 0, forward <= corridor.maxRangeM,
                           abs(x) <= half,
                           heightAboveFloor >= corridor.floorClearanceM,
                           heightAboveFloor <= corridor.topM {
                            hits += 1
                            minD = min(minD, forward)
                        }
                    }
                }
                u += step
            }
            v += step
        }
        let enough = hits >= minObstacleSamples
        return CorridorResult(minDistanceM: enough ? minD : nil,
                              obstacleSamples: hits, validSamples: valid, totalSamples: total)
    }

    /// World-frame corridor sampling. Each depth pixel is placed in the world with the camera's own ARKit pose
    /// (`cameraToWorld` = ARCamera.transform), so the phone's real tilt and rotation are used instead of a fixed mount.
    /// The fixed-mount `sample` assumes the depth image's "down" is world down, which is false for an upright
    /// (portrait) phone: ARKit's depth map is in landscape sensor orientation, so on the rover the floor was counted
    /// as an obstacle ~0.27 m ahead (thousands of hits). Height is world y above `floorY` (the detected floor; callers
    /// fall back to camera height minus GuardConfig.cameraHeightM). Forward and lateral are along the camera's
    /// horizontal heading, the same heading the pose (and so the controller) uses.
    public static func sampleWorld(depth: [Float], width: Int, height: Int,
                                   intrinsics k: DepthIntrinsics,
                                   cameraToWorld m: simd_float4x4,
                                   floorY: Float,
                                   corridor: Corridor = Corridor(),
                                   minObstacleSamples: Int = GuardConfig.minObstacleSamples,
                                   stride step: Int = 1) -> CorridorResult {
        let empty = CorridorResult(minDistanceM: nil, obstacleSamples: 0, validSamples: 0, totalSamples: 0)
        guard width > 0, height > 0, height <= depth.count / width,
              k.fx.isFinite, k.fy.isFinite, k.cx.isFinite, k.cy.isFinite,
              k.fx > 0, k.fy > 0, step > 0, floorY.isFinite else { return empty }
        // Horizontal heading: camera forward is -z; looking straight down/up falls back to the phone's up axis.
        var fx = -m.columns.2.x, fz = -m.columns.2.z
        var len = (fx * fx + fz * fz).squareRoot()
        if len < 1e-3 { fx = m.columns.1.x; fz = m.columns.1.z; len = (fx * fx + fz * fz).squareRoot() }
        guard len >= 1e-3 else { return empty }
        fx /= len; fz /= len
        let rx = -fz, rz = fx                       // horizontal right of the heading
        let cam = SIMD3<Float>(m.columns.3.x, m.columns.3.y, m.columns.3.z)
        let half = corridor.widthM / 2

        var minD: Float = .infinity
        var hits = 0, valid = 0, total = 0
        var v = 0
        while v < height {
            var u = 0
            while u < width {
                total += 1
                let d = depth[v * width + u]
                if d.isFinite && d > 0 && d >= corridor.lidarMinRangeM {
                    valid += 1
                    // Image (u right, v down, depth forward) -> ARKit camera coords (x right, y up, z backward).
                    let pc = SIMD4<Float>((Float(u) - k.cx) / k.fx * d, -(Float(v) - k.cy) / k.fy * d, -d, 1)
                    let pw = m * pc
                    let dx = pw.x - cam.x, dz = pw.z - cam.z
                    let forward = dx * fx + dz * fz
                    let lateral = dx * rx + dz * rz
                    let above = pw.y - floorY
                    if forward > 0, forward <= corridor.maxRangeM, abs(lateral) <= half,
                       above >= corridor.floorClearanceM, above <= corridor.topM {
                        hits += 1
                        minD = min(minD, forward)
                    }
                }
                u += step
            }
            v += step
        }
        let enough = hits >= minObstacleSamples
        return CorridorResult(minDistanceM: enough ? minD : nil, obstacleSamples: hits, validSamples: valid, totalSamples: total)
    }
}
