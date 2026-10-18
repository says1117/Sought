import Foundation

/// Which encoder pair the app is running, read from `model_config.json` shipped next to the compiled models
/// (written by `ml/conversion/convert_openclip.py`). Without that file the app assumes the MobileCLIP-S0 values
/// the project started with, so existing installs keep working.
public struct ModelConfig: Codable, Equatable {
    public var name: String
    /// Square input of the image model, pixels.
    public var imageSize: Int
    public var embeddingDim: Int
    /// Token ids the text model takes. The Swift tokenizer always emits 77.
    public var contextLength: Int
    /// true: the Core ML graph does all pixel scaling and mean/std itself, so Swift passes raw 0...255 bytes (both
    /// shipped models). false would need a Swift-side normalisation that does not exist, so it is rejected.
    public var normalizationBaked: Bool
    /// Compiled model base names (no extension). Default to the MobileCLIP-S0 names when omitted.
    public var imageModel: String
    public var textModel: String

    public init(name: String, imageSize: Int, embeddingDim: Int, contextLength: Int, normalizationBaked: Bool,
                imageModel: String = "MobileCLIP_S0_Image", textModel: String = "MobileCLIP_S0_Text") {
        self.name = name; self.imageSize = imageSize; self.embeddingDim = embeddingDim
        self.contextLength = contextLength; self.normalizationBaked = normalizationBaked
        self.imageModel = imageModel; self.textModel = textModel
    }

    /// Used when no `model_config.json` is present (Apple research-only licence; see ml/conversion/README.md).
    public static let mobileClipS0 = ModelConfig(name: "mobileclip-s0", imageSize: 256, embeddingDim: 512,
                                                 contextLength: 77, normalizationBaked: true)

    public static let fileName = "model_config.json"
    public static let supportedContextLength = 77

    enum CodingKeys: String, CodingKey {
        case name, imageSize = "image_size", embeddingDim = "embedding_dim", contextLength = "context_length"
        case normalizationBaked = "normalization_baked", imageModel = "image_model", textModel = "text_model"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        imageSize = try c.decode(Int.self, forKey: .imageSize)
        embeddingDim = try c.decode(Int.self, forKey: .embeddingDim)
        contextLength = try c.decode(Int.self, forKey: .contextLength)
        normalizationBaked = try c.decode(Bool.self, forKey: .normalizationBaked)
        imageModel = try c.decodeIfPresent(String.self, forKey: .imageModel) ?? Self.mobileClipS0.imageModel
        textModel = try c.decodeIfPresent(String.self, forKey: .textModel) ?? Self.mobileClipS0.textModel
    }

    /// Parses and validates; throws `ModelConfigError` with a sentence a person can act on.
    public static func parse(_ data: Data) throws -> ModelConfig {
        let cfg: ModelConfig
        do { cfg = try JSONDecoder().decode(ModelConfig.self, from: data) }
        catch { throw ModelConfigError(reason: "not valid model config JSON (\(error.localizedDescription))") }
        try cfg.validate()
        return cfg
    }

    public func validate() throws {
        guard (32...1024).contains(imageSize) else { throw ModelConfigError(reason: "image_size \(imageSize) is outside 32...1024") }
        guard embeddingDim > 0 else { throw ModelConfigError(reason: "embedding_dim must be positive, got \(embeddingDim)") }
        guard contextLength == Self.supportedContextLength else {
            throw ModelConfigError(reason: "context_length \(contextLength) is unsupported; the tokenizer produces \(Self.supportedContextLength)")
        }
        guard normalizationBaked else {
            throw ModelConfigError(reason: "normalization_baked=false is unsupported; convert the model with mean/std inside the graph")
        }
        for n in [imageModel, textModel] where n.isEmpty || n.contains("/") || n.contains(".") {
            throw ModelConfigError(reason: "model name \"\(n)\" must be a plain base name without a path or extension")
        }
    }
}

public struct ModelConfigError: Error, Equatable, CustomStringConvertible {
    public let reason: String
    public var description: String { "Invalid \(ModelConfig.fileName): \(reason). Regenerate it with ml/conversion (see ml/conversion/README.md) or delete it to use the MobileCLIP-S0 defaults." }
}
