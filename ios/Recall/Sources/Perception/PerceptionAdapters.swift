#if canImport(Vision) && canImport(CoreImage) && canImport(ARKit)
import ARKit
import CoreImage
import Vision
import simd

// Thin platform adapters around the pure core. Compiled by the app target only; NOT run in CI:
// they need a real ARFrame (LiDAR device) which the simulator cannot supply.

/// Vision objectness saliency -> proposals. Vision boxes are bottom-left origin; flipped to top-left here.
public struct SaliencyProposalSource: ProposalSource {
    public init() {}
    public func proposals(in frame: CVPixelBuffer) -> [Proposal] {
        let request = VNGenerateObjectnessBasedSaliencyImageRequest()
        let handler = VNImageRequestHandler(cvPixelBuffer: frame, orientation: .up, options: [:])
        guard (try? handler.perform([request])) != nil,
              let objects = request.results?.first?.salientObjects else { return [] }
        return objects.map { o in
            let b = o.boundingBox
            return Proposal(box: NormBox(x: Float(b.minX), y: Float(1 - b.maxY), w: Float(b.width), h: Float(b.height)),
                            score: o.confidence, origin: .saliency)
        }
    }
}

/// Crops a camera pixel buffer with CoreImage and encodes JPEG thumbnails.
public struct CIFrameCropSource: CropSource {
    private let image: CIImage
    private let context: CIContext
    public init(pixelBuffer: CVPixelBuffer, context: CIContext = CIContext()) {
        self.image = CIImage(cvPixelBuffer: pixelBuffer); self.context = context
    }
    public func crop(_ box: NormBox) -> CIImage? {
        let e = image.extent
        let b = box.clamped()
        guard b.area > 0 else { return nil }
        // CoreImage origin is bottom-left.
        let r = CGRect(x: e.minX + CGFloat(b.x) * e.width, y: e.minY + CGFloat(1 - b.y - b.h) * e.height,
                       width: CGFloat(b.w) * e.width, height: CGFloat(b.h) * e.height)
        return image.cropped(to: r)
    }
    public func thumbnailJPEG(_ crop: CIImage, maxEdge: Int) -> Data? {
        let longest = max(crop.extent.width, crop.extent.height)
        let scale = min(1, CGFloat(maxEdge) / longest)
        let scaled = crop.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        guard let cs = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        return context.jpegRepresentation(of: scaled, colorSpace: cs, options: [:])
    }
}

public enum ARKitKeyframeAdapter {
    /// Plain geometry + depth from an ARFrame. nil when the frame has no scene depth.
    /// `floorY` comes from the plane/floor estimate. Depth is the raw map; confidence filtering is left to
    /// a later pass (low-confidence pixels are not masked here).
    public static func extract(from frame: ARFrame, floorY: Float) -> (KeyframeGeometry, DepthMap)? {
        guard let sd = frame.sceneDepth else { return nil }
        let map = sd.depthMap
        CVPixelBufferLockBaseAddress(map, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(map, .readOnly) }
        guard CVPixelBufferGetPixelFormatType(map) == kCVPixelFormatType_DepthFloat32,
              let base = CVPixelBufferGetBaseAddress(map) else { return nil }
        let w = CVPixelBufferGetWidth(map), h = CVPixelBufferGetHeight(map)
        let rowFloats = CVPixelBufferGetBytesPerRow(map) / MemoryLayout<Float32>.size
        let src = base.assumingMemoryBound(to: Float32.self)
        var values = [Float](repeating: 0, count: w * h)
        for v in 0..<h { for u in 0..<w { values[v * w + u] = src[v * rowFloats + u] } }
        let k = frame.camera.intrinsics, res = frame.camera.imageResolution
        let g = KeyframeGeometry(cameraToWorld: frame.camera.transform,
                                 fx: k[0][0], fy: k[1][1], cx: k[2][0], cy: k[2][1],
                                 imageWidth: Int(res.width), imageHeight: Int(res.height),
                                 floorY: floorY, time: frame.timestamp)
        return (g, DepthMap(width: w, height: h, values: values))
    }
}
#endif
