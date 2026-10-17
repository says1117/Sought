import Foundation
#if canImport(Vision)
import Vision
import CoreVideo

// Vision person-confirm for the last meters (docs/01_ROBOTICS_PLAN.md section 3.6).
//  - https://developer.apple.com/documentation/vision/vndetecthumanrectanglesrequest
//  - https://developer.apple.com/documentation/arkit/arframe/scenedepth
// The frame source is injected (the app wires it to the ARSession's current frame: capturedImage, sceneDepth.depthMap,
// intrinsics) so this file needs no ARKit. Orientation, bearing sign and the linear angle approximation are
// unverified; check them with docs/come-to-me-test.md step 7.

struct DetectorFrame {
    var image: CVPixelBuffer
    var depth: CVPixelBuffer?          // Float32 meters, same orientation as the image
    var horizontalFovDeg: Double       // from intrinsics: 2*atan(width / (2*fx))
    var orientation: CGImagePropertyOrientation   // .right for ARKit capturedImage with an upright portrait phone
}

final class VisionPersonDetector: PersonDetector {
    private let frame: () -> DetectorFrame?
    init(frame: @escaping () -> DetectorFrame?) { self.frame = frame }

    func detect() async -> PersonObservation? {
        guard let f = frame() else { return nil }
        let req = VNDetectHumanRectanglesRequest()
        req.upperBodyOnly = true
        let handler = VNImageRequestHandler(cvPixelBuffer: f.image, orientation: f.orientation, options: [:])
        guard (try? handler.perform([req])) != nil,
              let best = req.results?.max(by: { $0.boundingBox.width * $0.boundingBox.height < $1.boundingBox.width * $1.boundingBox.height })
        else { return nil }
        let box = best.boundingBox                                  // normalized, origin bottom-left, after orientation
        let bearing = -(Double(box.midX) - 0.5) * f.horizontalFovDeg    // person right of center -> negative (right)
        return PersonObservation(bearingDeg: bearing, distanceM: f.depth.flatMap { Self.depth($0, nx: box.midX, ny: box.midY) })
    }

    /// Depth at a normalized point (origin bottom-left). Returns nil for non-finite or non-positive values.
    static func depth(_ buf: CVPixelBuffer, nx: CGFloat, ny: CGFloat) -> Double? {
        CVPixelBufferLockBaseAddress(buf, .readOnly); defer { CVPixelBufferUnlockBaseAddress(buf, .readOnly) }
        guard CVPixelBufferGetPixelFormatType(buf) == kCVPixelFormatType_DepthFloat32,
              let base = CVPixelBufferGetBaseAddress(buf) else { return nil }
        let w = CVPixelBufferGetWidth(buf), h = CVPixelBufferGetHeight(buf), stride = CVPixelBufferGetBytesPerRow(buf)
        let x = min(w - 1, max(0, Int(nx * CGFloat(w)))), y = min(h - 1, max(0, Int((1 - ny) * CGFloat(h))))
        let v = base.advanced(by: y * stride + x * 4).assumingMemoryBound(to: Float32.self).pointee
        return (v.isFinite && v > 0) ? Double(v) : nil
    }
}
#endif
