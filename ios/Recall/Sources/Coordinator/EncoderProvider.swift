import Foundation
#if canImport(Retrieval)
import Retrieval
#endif
#if canImport(FindExecutor)
import FindExecutor
#endif

/// The CLIP-style encoders the find path needs, or an explanation of why they are missing.
struct EncoderSet {
    var text: TextEncoder
    var images: ImageEmbedder
    /// False for the placeholder set. The find adapter refuses cleanly instead of driving.
    var isAvailable: Bool
    /// Spoken when `isAvailable` is false.
    var unavailableMessage: String?
}

protocol EncoderProvider {
    func encoders() -> EncoderSet
}

enum EncoderError: Error, Equatable { case modelsMissing }

/// Used until the Core ML encoders ship (PR 32). Every use throws `modelsMissing`.
struct ModelsMissingEncoder: TextEncoder, ImageEmbedder {
    func encode(_ text: String) throws -> [Float] { throw EncoderError.modelsMissing }
    func captureEmbeddings(around position: SIMD3<Float>, count: Int, cropScale: Float) async throws -> [[Float]] {
        throw EncoderError.modelsMissing
    }
}

struct ModelsMissingEncoderProvider: EncoderProvider {
    static let spoken = "The image models are not installed, so I can't look for objects yet. I can still go to saved places."
    func encoders() -> EncoderSet {
        let m = ModelsMissingEncoder()
        return EncoderSet(text: m, images: m, isAvailable: false, unavailableMessage: Self.spoken)
    }
}

/// Fixed encoders, for tests and for wiring real ones.
struct StaticEncoderProvider: EncoderProvider {
    var set: EncoderSet
    func encoders() -> EncoderSet { set }
}

/// THE seam for PR 32 (CoreMLTextEncoder, ModelLocator). After merging it, change the body of `makeDefault`
/// (App/AppRuntime.swift calls only this) to try `ModelLocator().locateAll()` and build `CoreMLTextEncoder` +
/// `CoreMLLookEmbedder`, falling back to `ModelsMissingEncoderProvider()` when the locator throws.
enum EncoderProviders {
    static func makeDefault() -> EncoderProvider { ModelsMissingEncoderProvider() }
}
