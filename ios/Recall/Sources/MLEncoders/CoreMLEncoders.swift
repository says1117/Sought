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
    /// `tokens` is exactly `ModelConfig.contextLength` (77) ids (CLIPTokenizer output). Returns the raw model output.
    func run(tokens: [Int32]) throws -> [Float]
}
public protocol ImageModelRunning {
    /// `image` is `ModelConfig.imageSize` square RGBA bytes (ImagePreprocessing output). Returns the raw model output.
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
    public let config: ModelConfig
    public init(tokenizer: CLIPTokenizer, runner: TextModelRunning, config: ModelConfig = .mobileClipS0) {
        self.tokenizer = tokenizer; self.runner = runner; self.config = config
    }
    public func encode(_ text: String) throws -> [Float] {
        try EmbeddingMath.unit(try runner.run(tokens: tokenizer.isValidated ? tokenizer.encodeChecked(text) : tokenizer.encode(text)),
                               expected: config.embeddingDim)
    }
}

/// Per-crop image embedder (Perception `CropEmbedder`). Output vectors are unit length, in crop order.
public struct CoreMLImageEmbedder: CropEmbedder {
    public let runner: ImageModelRunning
    public var fitMode: CropFitMode
    public let config: ModelConfig
    public init(runner: ImageModelRunning, fitMode: CropFitMode = .centerCrop, config: ModelConfig = .mobileClipS0) {
        self.runner = runner; self.fitMode = fitMode; self.config = config
    }
    public func embed(_ crops: [RawImage]) throws -> [[Float]] {
        try crops.map { try embedOne($0) }
    }
    public func embedOne(_ crop: RawImage) throws -> [Float] {
        try EmbeddingMath.unit(try runner.run(image: ImagePreprocessing.prepare(crop, mode: fitMode, size: config.imageSize)),
                               expected: config.embeddingDim)
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
/// real (uncommitted) models. Input/output names match ml/conversion/convert.py and convert_openclip.py: "tokens", "image", "embedding".
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
    /// `expectedImageSize`: when given, the model's fixed image input must be that size, so a model installed
    /// without its matching `model_config.json` fails here with a clear message instead of at the first predict.
    public init(modelURL: URL, computeUnits: MLComputeUnits = .all, expectedImageSize: Int? = nil) throws {
        let cfg = MLModelConfiguration(); cfg.computeUnits = computeUnits
        do { model = try MLModel(contentsOf: modelURL, configuration: cfg) }
        catch { throw EncoderError.modelFailed("image model load: \(error)") }
        if let want = expectedImageSize,
           let c = model.modelDescription.inputDescriptionsByName["image"]?.imageConstraint,
           c.pixelsWide != want || c.pixelsHigh != want {
            throw EncoderError.modelFailed("image model takes \(c.pixelsWide)x\(c.pixelsHigh) but model_config.json says image_size \(want); "
                                           + "install the models and model_config.json from the same folder")
        }
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
        try build(try locator.locateAll())
    }

    /// Builds both encoders from located files, carrying the located `ModelConfig` (image size, embedding dimension)
    /// into the encoders and checking the image model's input size against it. Every caller that has `ModelLocations`
    /// (the app's EncoderProvider included) must build through here, or a 224 px model gets 256 px crops.
    public static func build(_ loc: ModelLocations) throws -> (text: CoreMLTextEncoder, image: CoreMLImageEmbedder) {
        let tok = try CLIPTokenizer(vocabURL: loc.vocab, mergesURL: loc.merges)
        return (CoreMLTextEncoder(tokenizer: tok, runner: try CoreMLTextRunner(modelURL: loc.textModel), config: loc.config),
                CoreMLImageEmbedder(runner: try CoreMLImageRunner(modelURL: loc.imageModel, expectedImageSize: loc.config.imageSize),
                                    config: loc.config))
    }
}
#endif
