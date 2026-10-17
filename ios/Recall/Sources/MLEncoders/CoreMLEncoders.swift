import Foundation
#if canImport(Retrieval)
import Retrieval
#endif
#if canImport(FindExecutor)
import FindExecutor
#endif
#if canImport(PerceptionCore)
import PerceptionCore
#endif
#if canImport(simd)
import simd
#endif

public enum EncoderError: Error, Equatable {
    case wrongOutputSize(expected: Int, got: Int)
    case zeroVector
    case modelFailed(String)
}

/// The only seam to Core ML. Real runners wrap `MLModel`; tests use fakes.
public protocol TextModelRunning {
    /// `tokens` is exactly 77 ids (CLIPTokenizer output). Returns the raw model output.
    func run(tokens: [Int32]) throws -> [Float]
}
public protocol ImageModelRunning {
    /// `image` is 256x256 RGBA bytes (ImagePreprocessing output). Returns the raw model output.
    func run(image: RawImage) throws -> [Float]
}

public enum EmbeddingMath {
    public static let dimension = 512

    /// Scales to unit length; throws on zero/non-finite or wrong size (so a bad model never yields garbage).
    public static func unit(_ v: [Float], expected: Int = dimension) throws -> [Float] {
        guard v.count == expected else { throw EncoderError.wrongOutputSize(expected: expected, got: v.count) }
        var n: Float = 0
        for x in v { n += x * x }
        n = n.squareRoot()
        guard n > 0, n.isFinite else { throw EncoderError.zeroVector }
        return v.map { $0 / n }
    }
}

/// Retrieval `TextEncoder` backed by the Core ML text model + CLIP BPE tokenizer.
public struct CoreMLTextEncoder: TextEncoder {
    public let tokenizer: CLIPTokenizer
    public let runner: TextModelRunning
    public init(tokenizer: CLIPTokenizer, runner: TextModelRunning) {
        self.tokenizer = tokenizer; self.runner = runner
    }
    public func encode(_ text: String) throws -> [Float] {
        try EmbeddingMath.unit(try runner.run(tokens: tokenizer.encode(text)))
    }
}

/// Per-crop image embedder (Perception `CropEmbedder`). Output vectors are unit length, in crop order.
public struct CoreMLImageEmbedder: CropEmbedder {
    public let runner: ImageModelRunning
    public var fitMode: CropFitMode
    public init(runner: ImageModelRunning, fitMode: CropFitMode = .centerCrop) {
        self.runner = runner; self.fitMode = fitMode
    }
    public func embed(_ crops: [RawImage]) throws -> [[Float]] {
        try crops.map { try embedOne($0) }
    }
    public func embedOne(_ crop: RawImage) throws -> [Float] {
        try EmbeddingMath.unit(try runner.run(image: ImagePreprocessing.prepare(crop, mode: fitMode)))
    }
}

/// Supplies camera crops around a stored world point (the ARKit projection lives in an app adapter).
public protocol LookCropProviding {
    func crops(around position: SIMD3<Float>, count: Int, cropScale: Float) async throws -> [RawImage]
}

/// FindExecutor `ImageEmbedder`: provider's crops -> the same Core ML image model.
public struct CoreMLLookEmbedder: ImageEmbedder {
    public let provider: LookCropProviding
    public let embedder: CoreMLImageEmbedder
    public init(provider: LookCropProviding, embedder: CoreMLImageEmbedder) {
        self.provider = provider; self.embedder = embedder
    }
    public func captureEmbeddings(around position: SIMD3<Float>, count: Int, cropScale: Float) async throws -> [[Float]] {
        try embedder.embed(try await provider.crops(around: position, count: count, cropScale: cropScale))
    }
}

#if canImport(CoreML) && canImport(CoreVideo)
import CoreML
import CoreVideo

/// Loads a compiled `.mlmodelc` (from ModelLocator) and runs it. Not exercised by unit tests: needs the
/// real (uncommitted) models. Input/output names match ml/conversion/convert.py: "tokens", "image", "embedding".
public final class CoreMLTextRunner: TextModelRunning {
    private let model: MLModel
    public init(modelURL: URL, computeUnits: MLComputeUnits = .all) throws {
        let cfg = MLModelConfiguration(); cfg.computeUnits = computeUnits
        do { model = try MLModel(contentsOf: modelURL, configuration: cfg) }
        catch { throw EncoderError.modelFailed("text model load: \(error)") }
    }
    public func run(tokens: [Int32]) throws -> [Float] {
        do {
            let arr = try MLMultiArray(shape: [1, NSNumber(value: tokens.count)], dataType: .int32)
            for (i, t) in tokens.enumerated() { arr[i] = NSNumber(value: t) }
            let out = try model.prediction(from: MLDictionaryFeatureProvider(dictionary: ["tokens": arr]))
            return Self.floats(out.featureValue(for: "embedding")?.multiArrayValue)
        } catch let e as EncoderError { throw e } catch { throw EncoderError.modelFailed("text predict: \(error)") }
    }
    static func floats(_ a: MLMultiArray?) -> [Float] {
        guard let a else { return [] }
        return (0..<a.count).map { a[$0].floatValue }
    }
}

public final class CoreMLImageRunner: ImageModelRunning {
    private let model: MLModel
    public init(modelURL: URL, computeUnits: MLComputeUnits = .all) throws {
        let cfg = MLModelConfiguration(); cfg.computeUnits = computeUnits
        do { model = try MLModel(contentsOf: modelURL, configuration: cfg) }
        catch { throw EncoderError.modelFailed("image model load: \(error)") }
    }
    public func run(image: RawImage) throws -> [Float] {
        var pb: CVPixelBuffer?
        let st = CVPixelBufferCreate(nil, image.width, image.height, kCVPixelFormatType_32BGRA, nil, &pb)
        guard st == kCVReturnSuccess, let buf = pb else { throw EncoderError.modelFailed("pixel buffer \(st)") }
        CVPixelBufferLockBaseAddress(buf, [])
        if let base = CVPixelBufferGetBaseAddress(buf)?.assumingMemoryBound(to: UInt8.self) {
            let stride = CVPixelBufferGetBytesPerRow(buf)
            for y in 0..<image.height {
                for x in 0..<image.width {
                    let s = (y * image.width + x) * 4, d = y * stride + x * 4
                    base[d] = image.rgba[s + 2]; base[d + 1] = image.rgba[s + 1]; base[d + 2] = image.rgba[s]; base[d + 3] = 255
                }
            }
        }
        CVPixelBufferUnlockBaseAddress(buf, [])
        do {
            let out = try model.prediction(from: MLDictionaryFeatureProvider(dictionary: ["image": MLFeatureValue(pixelBuffer: buf)]))
            return CoreMLTextRunner.floats(out.featureValue(for: "embedding")?.multiArrayValue)
        } catch { throw EncoderError.modelFailed("image predict: \(error)") }
    }
}

/// One call from the app: locate files, build the real encoders.
public enum CoreMLEncoderFactory {
    public static func make(locator: ModelLocator = ModelLocator()) throws -> (text: CoreMLTextEncoder, image: CoreMLImageEmbedder) {
        let loc = try locator.locateAll()
        let tok = try CLIPTokenizer(vocabURL: loc.vocab, mergesURL: loc.merges)
        return (CoreMLTextEncoder(tokenizer: tok, runner: try CoreMLTextRunner(modelURL: loc.textModel)),
                CoreMLImageEmbedder(runner: try CoreMLImageRunner(modelURL: loc.imageModel)))
    }
}
#endif
