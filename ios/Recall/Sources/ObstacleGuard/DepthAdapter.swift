#if canImport(ARKit)
import ARKit

// Thin ARKit adapter. NOT compiled or run in the authoring environment (no Xcode / iOS SDK).
// Converts ARFrame.sceneDepth into the plain arrays the pure core in CorridorSampler.swift expects.
// Requires a LiDAR device and ARWorldTrackingConfiguration.frameSemantics = .sceneDepth.

public enum DepthAdapter {
    /// Returns nil when the frame has no scene depth (no LiDAR, or semantics not enabled).
    public static func corridorResult(from frame: ARFrame,
                                      mount: CameraMount = CameraMount(),
                                      corridor: Corridor = Corridor(),
                                      stride: Int = 2) -> CorridorResult? {
        guard let depth = frame.sceneDepth else { return nil }
        let map = depth.depthMap
        CVPixelBufferLockBaseAddress(map, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(map, .readOnly) }
        guard CVPixelBufferGetPixelFormatType(map) == kCVPixelFormatType_DepthFloat32,
              let base = CVPixelBufferGetBaseAddress(map) else { return nil }

        let w = CVPixelBufferGetWidth(map), h = CVPixelBufferGetHeight(map)
        let rowFloats = CVPixelBufferGetBytesPerRow(map) / MemoryLayout<Float32>.size
        var buf = [Float](repeating: 0, count: w * h)

        // Drop low-confidence pixels (treated as no measurement).
        var conf: UnsafePointer<UInt8>?
        var confRow = 0
        if let cm = depth.confidenceMap {
            CVPixelBufferLockBaseAddress(cm, .readOnly)
            conf = CVPixelBufferGetBaseAddress(cm)?.assumingMemoryBound(to: UInt8.self)
            confRow = CVPixelBufferGetBytesPerRow(cm)
        }
        defer { if let cm = depth.confidenceMap { CVPixelBufferUnlockBaseAddress(cm, .readOnly) } }

        let src = base.assumingMemoryBound(to: Float32.self)
        for y in 0..<h {
            for x in 0..<w {
                if let conf, conf[y * confRow + x] < UInt8(ARConfidenceLevel.medium.rawValue) { continue }
                buf[y * w + x] = src[y * rowFloats + x]
            }
        }

        // ARCamera.intrinsics is for capturedImage resolution; scale to the depth map.
        let k = frame.camera.intrinsics
        let iw = Float(frame.camera.imageResolution.width), ih = Float(frame.camera.imageResolution.height)
        let sx = Float(w) / iw, sy = Float(h) / ih
        let intr = DepthIntrinsics(fx: k[0][0] * sx, fy: k[1][1] * sy, cx: k[2][0] * sx, cy: k[2][1] * sy)

        return CorridorSampler.sample(depth: buf, width: w, height: h, intrinsics: intr,
                                      mount: mount, corridor: corridor, stride: stride)
    }
}
#endif
