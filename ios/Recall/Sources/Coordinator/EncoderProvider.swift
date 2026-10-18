import Foundation
#if canImport(Retrieval)
import Retrieval
#endif
#if canImport(FindExecutor)
import FindExecutor
#endif
#if canImport(MLEncoders)
import MLEncoders
#endif

/// The CLIP-style encoders the find path needs, or an explanation of why they are missing.
struct EncoderSet {
    var text: TextEncoder
    var images: ImageEmbedder
    /// False for the placeholder set. The find adapter refuses cleanly instead of driving.
    var isAvailable: Bool
    /// Spoken when `isAvailable` is false.
    var unavailableMessage: String?
    /// The Core ML image model behind `images`, for the perception loop (nil for placeholder and fake sets).
    var imageModel: CoreMLImageEmbedder? = nil
    /// Long form of why the set is unavailable, for logs (not spoken).
    var diagnostic: String? = nil
}

protocol EncoderProvider {
    func encoders() -> EncoderSet
}

enum ModelsMissingError: Error, Equatable { case modelsMissing }

/// Used until the Core ML encoders ship (PR 32). Every use throws `modelsMissing`.
struct ModelsMissingEncoder: TextEncoder, ImageEmbedder {
    func encode(_ text: String) throws -> [Float] { throw ModelsMissingError.modelsMissing }
    func captureEmbeddings(around position: SIMD3<Float>, count: Int, cropScale: Float) async throws -> [[Float]] {
        throw ModelsMissingError.modelsMissing
    }
}

struct ModelsMissingEncoderProvider: EncoderProvider {
    static let spoken = "The image models are not installed, so I can't look for objects yet. I can still go to saved places."
    var message = Self.spoken
    var diagnostic: String? = nil
    func encoders() -> EncoderSet {
        let m = ModelsMissingEncoder()
        return EncoderSet(text: m, images: m, isAvailable: false, unavailableMessage: message, diagnostic: diagnostic)
    }
}

/// Fixed encoders, for tests and for wiring real ones.
struct StaticEncoderProvider: EncoderProvider {
    var set: EncoderSet
    func encoders() -> EncoderSet { set }
}

enum EncoderProviders {
    /// Builds the text encoder and image model from located files. Injectable so selection is testable without models.
    typealias Builder = (ModelLocations) throws -> (text: TextEncoder, image: CoreMLImageEmbedder)

    /// The real Core ML encoders when every model and tokenizer file is found and loads; otherwise the models-missing
    /// provider, whose spoken message names what is missing. `frames` feeds the arrival check (the ARKit session).
    static func makeDefault(locator: ModelLocator = ModelLocator(),
                            frames: CameraFrameSource = NoCameraFrameSource(),
                            debugSink: ArrivalCropDebugSink = NoOpArrivalCropDebugSink(),
                            trackLookup: @escaping (SIMD3<Float>) -> String? = { _ in nil },
                            build: Builder = realBuilder) -> EncoderProvider {
        do {
            let locations = try locator.locateAll()
            let built = try build(locations)
            let looker = ArrivalCropEmbedder(frames: frames, embedder: built.image, debugSink: debugSink, trackLookup: trackLookup)
            return StaticEncoderProvider(set: EncoderSet(text: built.text, images: looker, isAvailable: true,
                                                        unavailableMessage: nil, imageModel: built.image))
        } catch let e as ModelLocatorError {
            let names = e.missing.map(\.spokenName).joined(separator: ", ")
            let spoken = e.missing.isEmpty ? ModelsMissingEncoderProvider.spoken : "\(e.spokenMessage) Missing: \(names)."
            return ModelsMissingEncoderProvider(message: spoken, diagnostic: e.description)
        } catch {
            return ModelsMissingEncoderProvider(
                message: "My vision models are installed but would not load, so I can't look for objects yet.",
                diagnostic: "Model load failed: \(error)")
        }
    }

    /// Validated CLIP tokenizer + compiled Core ML text and image models.
    static let realBuilder: Builder = { loc in
        #if canImport(CoreML)
        let tokenizer = try CLIPTokenizer(vocabURL: loc.vocab, mergesURL: loc.merges)
        let text = CoreMLTextEncoder(tokenizer: tokenizer, runner: try CoreMLTextRunner(modelURL: loc.textModel))
        return (text, CoreMLImageEmbedder(runner: try CoreMLImageRunner(modelURL: loc.imageModel)))
        #else
        throw ModelsMissingError.modelsMissing
        #endif
    }
}

extension ModelAsset {
    var spokenName: String {
        switch self {
        case .textModel: return "text model"
        case .imageModel: return "image model"
        case .vocab: return "tokenizer vocabulary"
        case .merges: return "tokenizer merges"
        }
    }
}
