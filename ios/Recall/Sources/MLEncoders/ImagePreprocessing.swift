import Foundation

/// Tightly packed 8-bit RGBA image (row-major, top-left origin, 4 bytes per pixel). Platform neutral so
/// preprocessing is a pure, testable function; the Core ML runner turns it into a CVPixelBuffer.
public struct RawImage: Equatable {
    public let width: Int
    public let height: Int
    public let rgba: [UInt8]

    public init(width: Int, height: Int, rgba: [UInt8]) {
        precondition(width > 0 && height > 0 && rgba.count == width * height * 4, "RawImage size mismatch")
        self.width = width; self.height = height; self.rgba = rgba
    }
}

public enum CropFitMode: Equatable {
    /// MobileCLIP's own transform: resize the SHORT side to 256 then center-crop 256x256 (default).
    case centerCrop
    /// Stretch the whole crop to 256x256 (keeps everything in the detector box, distorts aspect).
    case squash
}

/// MobileCLIP-S0 image input: 256x256 RGB, bytes 0...255. The 1/255 scale lives INSIDE the Core ML graph
/// (ImageType scale=1/255, no mean/std; see ml/conversion/README.md), so we must NOT scale here.
public enum ImagePreprocessing {
    public static let inputSize = 256

    public static func prepare(_ image: RawImage, mode: CropFitMode = .centerCrop, size: Int = inputSize) -> RawImage {
        // Source window (in source pixels, floating) that maps onto the full output square.
        let w = Double(image.width), h = Double(image.height)
        var sx = 0.0, sy = 0.0, sw = w, sh = h
        if mode == .centerCrop {
            let side = min(w, h)
            sw = side; sh = side; sx = (w - side) / 2; sy = (h - side) / 2
        }
        var out = [UInt8](repeating: 255, count: size * size * 4)
        for y in 0..<size {
            let fy = sy + (Double(y) + 0.5) * sh / Double(size) - 0.5
            let y0 = Int(fy.rounded(.down)), ty = fy - Double(y0)
            for x in 0..<size {
                let fx = sx + (Double(x) + 0.5) * sw / Double(size) - 0.5
                let x0 = Int(fx.rounded(.down)), tx = fx - Double(x0)
                for c in 0..<3 {
                    let p00 = sample(image, x0, y0, c), p10 = sample(image, x0 + 1, y0, c)
                    let p01 = sample(image, x0, y0 + 1, c), p11 = sample(image, x0 + 1, y0 + 1, c)
                    let top = p00 * (1 - tx) + p10 * tx
                    let bot = p01 * (1 - tx) + p11 * tx
                    out[(y * size + x) * 4 + c] = UInt8(max(0, min(255, (top * (1 - ty) + bot * ty).rounded())))
                }
            }
        }
        return RawImage(width: size, height: size, rgba: out)
    }

    private static func sample(_ img: RawImage, _ x: Int, _ y: Int, _ c: Int) -> Double {
        let cx = max(0, min(img.width - 1, x)), cy = max(0, min(img.height - 1, y))
        return Double(img.rgba[(cy * img.width + cx) * 4 + c])
    }

    /// Planar CHW floats scaled by 1/255, for backends whose model takes a tensor instead of an image.
    /// The shipped model takes an image, so the Core ML path does not use this.
    public static func chwUnitScale(_ image: RawImage) -> [Float] {
        let n = image.width * image.height
        var out = [Float](repeating: 0, count: 3 * n)
        for i in 0..<n { for c in 0..<3 { out[c * n + i] = Float(image.rgba[i * 4 + c]) / 255 } }
        return out
    }
}
