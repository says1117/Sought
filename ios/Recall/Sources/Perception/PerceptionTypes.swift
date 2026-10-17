import Foundation
import simd
#if canImport(Memory)
import Memory
#endif

/// Box in normalised image coordinates: origin top-left, x right, y down, all in 0...1.
public struct NormBox: Equatable {
    public var x: Float, y: Float, w: Float, h: Float
    public init(x: Float, y: Float, w: Float, h: Float) { self.x = x; self.y = y; self.w = w; self.h = h }

    public var area: Float { max(0, w) * max(0, h) }
    public var center: SIMD2<Float> { SIMD2(x + w / 2, y + h / 2) }

    /// Same box clamped into the unit square (may become empty).
    public func clamped() -> NormBox {
        let x0 = min(1, max(0, x)), y0 = min(1, max(0, y))
        let x1 = min(1, max(0, x + w)), y1 = min(1, max(0, y + h))
        return NormBox(x: x0, y: y0, w: x1 - x0, h: y1 - y0)
    }

    public func iou(_ o: NormBox) -> Float {
        let ix = max(0, min(x + w, o.x + o.w) - max(x, o.x))
        let iy = max(0, min(y + h, o.y + o.h) - max(y, o.y))
        let inter = ix * iy
        let union = area + o.area - inter
        return union > 0 ? inter / union : 0
    }

    /// Central region with `fraction` of the area (e.g. 0.3 keeps the middle 30%): each side scaled by sqrt(fraction).
    public func central(areaFraction fraction: Float) -> NormBox {
        let s = fraction.squareRoot()
        let nw = w * s, nh = h * s
        return NormBox(x: x + (w - nw) / 2, y: y + (h - nh) / 2, w: nw, h: nh)
    }
}

public enum ProposalOrigin: String, Equatable {
    case yolo, saliency, grid
}

public struct Proposal: Equatable {
    public var box: NormBox
    public var score: Float
    public var origin: ProposalOrigin
    public init(box: NormBox, score: Float, origin: ProposalOrigin) {
        self.box = box; self.score = score; self.origin = origin
    }
}

/// Plain-value summary of what the sensors gave us for one keyframe (no ARKit types).
public struct KeyframeGeometry {
    /// Camera-to-world transform (ARKit `camera.transform`), world frame is y up.
    public var cameraToWorld: simd_float4x4
    /// Pinhole intrinsics in colour-image pixels (u right, v down).
    public var fx: Float, fy: Float, cx: Float, cy: Float
    public var imageWidth: Int, imageHeight: Int
    /// World y of the floor plane.
    public var floorY: Float
    public var time: Double
    public init(cameraToWorld: simd_float4x4, fx: Float, fy: Float, cx: Float, cy: Float,
                imageWidth: Int, imageHeight: Int, floorY: Float, time: Double) {
        self.cameraToWorld = cameraToWorld
        self.fx = fx; self.fy = fy; self.cx = cx; self.cy = cy
        self.imageWidth = imageWidth; self.imageHeight = imageHeight
        self.floorY = floorY; self.time = time
    }
}

/// Row-major metric depth image (metres along the camera forward axis). 0, NaN or negative = invalid.
public struct DepthMap {
    public var width: Int, height: Int
    public var values: [Float]
    public init(width: Int, height: Int, values: [Float]) {
        precondition(values.count == width * height, "depth buffer size mismatch")
        self.width = width; self.height = height; self.values = values
    }
}

/// What the pipeline hands to the memory layer: a Memory `Observation` plus the extras the
/// storage layer needs (schema columns `height_above_floor`, thumbnail media).
public struct PerceivedObject {
    public var observation: Observation
    public var heightAboveFloor: Float
    public var box: NormBox
    public var origin: ProposalOrigin
    public var thumbnailJPEG: Data?
    public init(observation: Observation, heightAboveFloor: Float, box: NormBox,
                origin: ProposalOrigin, thumbnailJPEG: Data?) {
        self.observation = observation; self.heightAboveFloor = heightAboveFloor
        self.box = box; self.origin = origin; self.thumbnailJPEG = thumbnailJPEG
    }
}
