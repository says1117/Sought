import Foundation

// Pure corridor sampling over a depth buffer. No ARKit, so it can be unit tested without a device.
//
// Camera frame: x right, y down, z forward (optical axis), as in ARKit's depth image.
// The buffer holds depth in meters along z, row-major, `width * height` floats.
// 0, NaN, infinite or negative depth means "no measurement".

public struct DepthIntrinsics: Equatable {
    public var fx: Float, fy: Float, cx: Float, cy: Float
    public init(fx: Float, fy: Float, cx: Float, cy: Float) {
        self.fx = fx; self.fy = fy; self.cx = cx; self.cy = cy
    }
}

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
        guard width > 0, height > 0, depth.count >= width * height, k.fx > 0, k.fy > 0, step > 0 else {
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
                if d.isFinite && d > 0 {
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
}
