import Foundation
#if canImport(ImageIO) && canImport(CoreGraphics)
import ImageIO
import CoreGraphics
#endif
#if canImport(CoreImage)
import CoreImage
#endif
#if os(iOS) && canImport(ARKit) && canImport(CoreImage)
import ARKit
#endif

// Platform adapters for the arrival check. Thin on purpose: all decisions are in ArrivalCrop.swift.
// NOT exercised by unit tests where they need a real ARFrame; see the PR for what is unverified.

public enum ArrivalCropJPEG {
    #if canImport(ImageIO) && canImport(CoreGraphics)
    public static let encoder: ((RawImage) -> Data?)? = { image in
        guard let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        let data = Data(image.rgba) as CFData
        guard let provider = CGDataProvider(data: data),
              let cg = CGImage(width: image.width, height: image.height, bitsPerComponent: 8, bitsPerPixel: 32,
                               bytesPerRow: image.width * 4, space: space,
                               bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                               provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent),
              let out = CFDataCreateMutable(nil, 0),
              let dest = CGImageDestinationCreateWithData(out, "public.jpeg" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, cg, [kCGImageDestinationLossyCompressionQuality: 0.7] as CFDictionary)
        return CGImageDestinationFinalize(dest) ? (out as Data) : nil
    }
    #else
    public static let encoder: ((RawImage) -> Data?)? = nil
    #endif
}

#if canImport(CoreImage)
public enum CIImageRaw {
    /// Renders a CIImage (any extent) to tightly packed sRGB RGBA bytes, top row first. nil if it is empty or fails.
    public static func rawImage(from image: CIImage, context: CIContext) -> RawImage? {
        let e = image.extent.integral
        guard e.width >= 1, e.height >= 1, e.width.isFinite, e.height.isFinite,
              let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        let w = Int(e.width), h = Int(e.height)
        var bytes = [UInt8](repeating: 0, count: w * h * 4)
        context.render(image, toBitmap: &bytes, rowBytes: w * 4, bounds: e, format: .RGBA8, colorSpace: space)
        return RawImage(width: w, height: h, rgba: bytes)
    }
}
#endif

#if os(iOS) && canImport(ARKit) && canImport(CoreImage)
/// Latest frame of the shared ARSession. `capturedImage` is LANDSCAPE-RIGHT sensor orientation regardless of the UI
/// orientation, and `camera.intrinsics`, `imageResolution` and `transform` are expressed in that same frame, so the
/// geometry is passed through untouched and crops are cut from the buffer as delivered.
public final class ARKitFrameSource: CameraFrameSource {
    private let session: ARSession
    private let context: CIContext
    public init(session: ARSession, context: CIContext = CIContext()) { self.session = session; self.context = context }

    public func latestFrame() -> CameraFrame? {
        guard let frame = session.currentFrame, case .normal = frame.camera.trackingState else { return nil }
        let k = frame.camera.intrinsics, res = frame.camera.imageResolution
        let g = CameraGeometry(cameraToWorld: frame.camera.transform, fx: k[0][0], fy: k[1][1], cx: k[2][0], cy: k[2][1],
                               imageWidth: Int(res.width), imageHeight: Int(res.height), timestamp: frame.timestamp)
        return CameraFrame(geometry: g, pixels: PixelBufferCropper(buffer: frame.capturedImage, context: context))
    }
}

struct PixelBufferCropper: FrameCropping {
    let buffer: CVPixelBuffer
    let context: CIContext
    func crop(_ rect: PixelRect) -> RawImage? {
        let image = CIImage(cvPixelBuffer: buffer)
        let h = image.extent.height
        // CoreImage origin is bottom-left; PixelRect origin is top-left.
        let r = CGRect(x: image.extent.minX + CGFloat(rect.x), y: image.extent.minY + h - CGFloat(rect.y + rect.height),
                       width: CGFloat(rect.width), height: CGFloat(rect.height))
        return CIImageRaw.rawImage(from: image.cropped(to: r), context: context)
    }
}
#endif
