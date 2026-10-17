import Foundation

/// Text side of the CLIP-style embedding model (MobileCLIP-S0, 512-d, see ml/conversion/README.md).
/// The real implementation is a Core ML text encoder behind a Swift CLIP BPE tokenizer; neither is
/// written yet, so everything here depends only on this protocol.
public protocol TextEncoder {
    /// Embedding of one prompt. Need not be normalized; callers normalize.
    func encode(_ text: String) throws -> [Float]
}

public enum QueryEncodingError: Error, Equatable {
    case emptyPhrase
    case dimensionMismatch
    case zeroVector
}

public enum QueryEncoder {
    /// Prompt template from docs/01_ROBOTICS_PLAN.md 4.4: the raw phrase and "a photo of " + phrase.
    public static func prompts(for phrase: String) -> [String] {
        [phrase, "a photo of " + phrase]
    }

    /// q = normalize(mean(encode(phrase), encode("a photo of " + phrase))).
    public static func queryVector(phrase: String, encoder: TextEncoder) throws -> [Float] {
        let trimmed = phrase.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw QueryEncodingError.emptyPhrase }
        let vecs = try prompts(for: trimmed).map { try encoder.encode($0) }
        guard let first = vecs.first, vecs.allSatisfy({ $0.count == first.count }) else {
            throw QueryEncodingError.dimensionMismatch
        }
        var mean = [Float](repeating: 0, count: first.count)
        for v in vecs { for i in v.indices { mean[i] += v[i] / Float(vecs.count) } }
        guard let q = normalized(mean) else { throw QueryEncodingError.zeroVector }
        return q
    }

    public static func normalized(_ v: [Float]) -> [Float]? {
        var n: Float = 0
        for x in v { n += x * x }
        n = n.squareRoot()
        guard n > 0, n.isFinite else { return nil }
        return v.map { $0 / n }
    }
}
