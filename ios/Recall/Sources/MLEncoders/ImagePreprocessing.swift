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
    /// The CLIP transform: resize the SHORT side to the model size then center-crop a square (default).
    case centerCrop
    /// Stretch the whole crop to a square of the model size (keeps everything in the detector box, distorts aspect).
    case squash
}

/// Image model input: `size` x `size` RGB, bytes 0...255 (256 for MobileCLIP-S0, 224 for CLIP ViT-B/32; the size comes
/// from `ModelConfig.imageSize`). All scaling and any mean/std live INSIDE the Core ML graph (see ml/conversion/README.md),
/// so we must NOT scale here.
public enum ImagePreprocessing {
    /// Default size (MobileCLIP-S0), used when no model_config.json is present.
    public static let inputSize = ModelConfig.mobileClipS0.imageSize

    /// Resize like the conversion reference (PIL `Image.resize(..., BICUBIC)`, which antialiases when downscaling):
    /// `.centerCrop` resizes the short side to `size` (long side `Int(size * long / short)`, as torchvision
    /// `Resize(size)`) and crops the centre; `.squash` resizes the whole image to `size` x `size`.
    public static func prepare(_ image: RawImage, mode: CropFitMode = .centerCrop, size: Int = inputSize) -> RawImage {
        let w = image.width, h = image.height
        var newW = size, newH = size
        if mode == .centerCrop {
            if w <= h { newW = size; newH = max(size, Int(Double(size) * Double(h) / Double(w))) }
            else { newH = size; newW = max(size, Int(Double(size) * Double(w) / Double(h))) }
        }
        // torchvision CenterCrop offsets: int(round((full - crop) / 2.0)); Python's round() is half-to-even.
        let left = Int((Double(newW - size) / 2).rounded(.toNearestOrEven)), top = Int((Double(newH - size) / 2).rounded(.toNearestOrEven))
        let xt = PILResample.table(inSize: w, outSize: newW, outStart: left, outCount: size)
        let yt = PILResample.table(inSize: h, outSize: newH, outStart: top, outCount: size)

        // Horizontal pass over only the source rows the vertical pass needs, rounded to 8 bits in between (as PIL).
        let rowLo = yt.first?.start ?? 0, rowHi = yt.map { $0.start + $0.weights.count }.max() ?? h
        var tmp = [UInt8](repeating: 0, count: (rowHi - rowLo) * size * 3)
        image.rgba.withUnsafeBufferPointer { src in
            for row in rowLo..<rowHi {
                for (ox, t) in xt.enumerated() {
                    for c in 0..<3 {
                        var acc: Int64 = PILResample.half
                        for (k, wgt) in t.weights.enumerated() { acc += Int64(wgt) * Int64(src[(row * w + t.start + k) * 4 + c]) }
                        tmp[((row - rowLo) * size + ox) * 3 + c] = PILResample.clip8(acc)
                    }
                }
            }
        }
        var out = [UInt8](repeating: 255, count: size * size * 4)
        for (oy, t) in yt.enumerated() {
            for ox in 0..<size {
                for c in 0..<3 {
                    var acc: Int64 = PILResample.half
                    for (k, wgt) in t.weights.enumerated() { acc += Int64(wgt) * Int64(tmp[((t.start + k - rowLo) * size + ox) * 3 + c]) }
                    out[(oy * size + ox) * 4 + c] = PILResample.clip8(acc)
                }
            }
        }
        return RawImage(width: size, height: size, rgba: out)
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

/// Port of Pillow's `Resample.c` (bicubic, a = -0.5, support scaled by the downscale factor = antialiasing, 22-bit
/// fixed-point coefficients, 8-bit rounding after each pass). Reproduces `PIL.Image.resize(BICUBIC)` to within
/// rounding, which is what MobileCLIP's torchvision transform uses.
enum PILResample {
    static let bits = 22
    static let half: Int64 = 1 << 21

    struct Taps { let start: Int; let weights: [Int32] }

    static func clip8(_ acc: Int64) -> UInt8 { UInt8(max(0, min(255, acc >> Int64(bits)))) }

    private static func bicubic(_ x: Double) -> Double {
        let a = -0.5, x = abs(x)
        if x < 1 { return ((a + 2) * x - (a + 3)) * x * x + 1 }
        if x < 2 { return (((x - 5) * x + 8) * x - 4) * a }
        return 0
    }

    /// Taps for output positions `outStart ..< outStart + outCount` of a resize `inSize -> outSize`.
    static func table(inSize: Int, outSize: Int, outStart: Int, outCount: Int) -> [Taps] {
        let scale = Double(inSize) / Double(outSize)
        let filterScale = max(scale, 1.0)
        let support = 2.0 * filterScale
        return (outStart..<(outStart + outCount)).map { xx in
            let center = (Double(xx) + 0.5) * scale
            let xmin = max(0, Int(center - support + 0.5))
            let xmax = min(inSize, Int(center + support + 0.5)) - xmin
            var k = (0..<max(xmax, 1)).map { bicubic((Double($0 + xmin) - center + 0.5) / filterScale) }
            let total = k.reduce(0, +)
            if total != 0 { k = k.map { $0 / total } }
            return Taps(start: xmin, weights: k.map { Int32(($0 * Double(1 << bits) + ($0 < 0 ? -0.5 : 0.5)).rounded(.towardZero)) })
        }
    }
}
