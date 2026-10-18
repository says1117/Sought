import Foundation
#if canImport(Memory)
import Memory
#endif

/// Tuning for retrieval. `topK` comes from docs/01_ROBOTICS_PLAN.md 4.6; the persistence blend is
/// score = cosine * (persistenceFloor + persistenceWeight * p).
public enum RetrievalConfig {
    public static let topK = 5
    public static let persistenceFloor: Float = 0.8
    public static let persistenceWeight: Float = 0.2
    /// Contrastive negatives for the app's finder. Raw text-image cosines are nearly flat (~0.23-0.25) on real memory,
    /// so a plain ranking picked a person as "bottle" on the rover. Retrieval ranks by margin = cos(query) - best
    /// cos(negative), so people, walls and floor sink, but nothing is rejected (a real object crop is mostly
    /// background, so a hard cut could drop the object itself). Negatives sharing a word with the query are dropped.
    public static let negatives = ["a person", "a wall", "the floor", "a chair", "a table", "a door",
                                   "a couch", "a window", "the ceiling", "a bed"]
    /// The arrival check only vetoes these: an accepted crop must look more like the query than like any of them.
    /// Background prompts are deliberately absent (the object's crop contains floor/table around it).
    public static let arrivalNegatives = ["a person"]
}

/// One scored track. `score` is what ranking and the arrival check use; `cosine` is the raw text-image similarity.
public struct RankedTrack: Equatable {
    public var trackID: String
    public var score: Float
    public var cosine: Float
    public var persistence: Float
    public var confirmed: Bool
    public var position: SIMD3<Float>
    public var embedding: [Float]
    /// cosine to the query minus the best cosine to any negative (0 when retrieval ran without negatives).
    public var margin: Float = 0
}

/// Per-query candidate log (4.6): every track that was scored, in rank order, for evals and failure analysis.
public struct QueryLog: Equatable {
    public var phrase: String
    /// Every comparable track that was scored, best first (not truncated to top-k).
    public var scored: [RankedTrack]
    /// Tracks skipped because their embedding dimension differs from the query's.
    public var skippedIncomparable: [String]
    /// True when no confirmed track was scorable, so unconfirmed tracks were ranked instead.
    public var usedUnconfirmed: Bool
    /// Tracks a negative prompt matched at least as well as the query (ranked last, not removed).
    public var rejectedByNegatives: [String] = []
}

public struct RetrievalResult: Equatable {
    public var query: [Float]
    /// Top-k of the eligible pool, best first.
    public var ranked: [RankedTrack]
    public var log: QueryLog
    /// Normalized embeddings of the arrival-check negatives (empty: no contrastive veto at arrival).
    public var negatives: [[Float]] = []
}

public struct Retriever {
    public let encoder: TextEncoder
    public let topK: Int
    /// Ranking negatives (see RetrievalConfig.negatives). Empty = plain cosine ranking, the original behaviour.
    public let negatives: [String]
    /// Arrival-check negatives, passed on in RetrievalResult.negatives (see RetrievalConfig.arrivalNegatives).
    public let arrivalNegatives: [String]

    public init(encoder: TextEncoder, topK: Int = RetrievalConfig.topK, negatives: [String] = [], arrivalNegatives: [String] = []) {
        self.encoder = encoder; self.topK = topK; self.negatives = negatives; self.arrivalNegatives = arrivalNegatives
    }

    public func retrieve(phrase: String, tracks: [Track]) throws -> RetrievalResult {
        let q = try QueryEncoder.queryVector(phrase: phrase, encoder: encoder)
        var r = Retriever.rank(query: q, phrase: phrase, tracks: tracks, topK: topK,
                               negatives: try encodeNegatives(negatives, phrase: phrase, query: q))
        r.negatives = try encodeNegatives(arrivalNegatives, phrase: phrase, query: q)
        return r
    }

    /// "a photo of <negative>" embeddings, minus negatives that share a word with the phrase ("find the chair" keeps
    /// chairs) and negatives indistinguishable from the query (they carry no information).
    private func encodeNegatives(_ list: [String], phrase: String, query q: [Float]) throws -> [[Float]] {
        let words = Set(phrase.lowercased().split { !$0.isLetter }.map(String.init))
        return try list
            .filter { n in n.lowercased().split { !$0.isLetter }.allSatisfy { !words.contains(String($0)) || ["a", "the"].contains(String($0)) } }
            .compactMap { try QueryEncoder.normalized(encoder.encode("a photo of " + $0)) }
            .filter { (cosine($0, q) ?? 0) < 0.999 }
    }

    /// Pure ranking step. Unconfirmed tracks are used only if no confirmed track could be scored.
    /// With `negatives`, tracks rank by margin (cosine to the query minus the best cosine to a negative).
    public static func rank(query q: [Float], phrase: String, tracks: [Track], topK: Int = RetrievalConfig.topK,
                            negatives: [[Float]] = []) -> RetrievalResult {
        var scored: [RankedTrack] = []
        var skipped: [String] = []
        var rejected: [String] = []
        for t in tracks {
            guard let c = cosine(q, t.embedding) else { skipped.append(t.id); continue }
            var margin: Float = 0
            if !negatives.isEmpty {
                let worst = negatives.compactMap { cosine($0, t.embedding) }.max() ?? -1
                margin = c - worst
                if margin <= 0 { rejected.append(t.id) }      // logged and ranked low, never removed
            }
            let s = c * (RetrievalConfig.persistenceFloor + RetrievalConfig.persistenceWeight * t.persistence)
            scored.append(RankedTrack(trackID: t.id, score: s, cosine: c, persistence: t.persistence,
                                      confirmed: t.isConfirmed, position: t.position, embedding: t.embedding,
                                      margin: margin))
        }
        // Deterministic: best margin (with negatives) then best score first, ties by id.
        scored.sort {
            if $0.margin != $1.margin { return $0.margin > $1.margin }
            return $0.score != $1.score ? $0.score > $1.score : $0.trackID < $1.trackID
        }
        let confirmed = scored.filter { $0.confirmed }
        let usedUnconfirmed = confirmed.isEmpty && !scored.isEmpty
        let pool = usedUnconfirmed ? scored : confirmed
        let log = QueryLog(phrase: phrase, scored: scored, skippedIncomparable: skipped, usedUnconfirmed: usedUnconfirmed,
                           rejectedByNegatives: rejected)
        return RetrievalResult(query: q, ranked: Array(pool.prefix(max(0, topK))), log: log, negatives: negatives)
    }
}
