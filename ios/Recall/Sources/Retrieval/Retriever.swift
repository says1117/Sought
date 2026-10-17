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
}

public struct RetrievalResult: Equatable {
    public var query: [Float]
    /// Top-k of the eligible pool, best first.
    public var ranked: [RankedTrack]
    public var log: QueryLog
}

public struct Retriever {
    public let encoder: TextEncoder
    public let topK: Int

    public init(encoder: TextEncoder, topK: Int = RetrievalConfig.topK) {
        self.encoder = encoder; self.topK = topK
    }

    public func retrieve(phrase: String, tracks: [Track]) throws -> RetrievalResult {
        let q = try QueryEncoder.queryVector(phrase: phrase, encoder: encoder)
        return Retriever.rank(query: q, phrase: phrase, tracks: tracks, topK: topK)
    }

    /// Pure ranking step. Unconfirmed tracks are used only if no confirmed track could be scored.
    public static func rank(query q: [Float], phrase: String, tracks: [Track], topK: Int = RetrievalConfig.topK) -> RetrievalResult {
        var scored: [RankedTrack] = []
        var skipped: [String] = []
        for t in tracks {
            guard let c = cosine(q, t.embedding) else { skipped.append(t.id); continue }
            let s = c * (RetrievalConfig.persistenceFloor + RetrievalConfig.persistenceWeight * t.persistence)
            scored.append(RankedTrack(trackID: t.id, score: s, cosine: c, persistence: t.persistence,
                                      confirmed: t.isConfirmed, position: t.position, embedding: t.embedding))
        }
        // Deterministic: best score first, ties by id.
        scored.sort { $0.score != $1.score ? $0.score > $1.score : $0.trackID < $1.trackID }
        let confirmed = scored.filter { $0.confirmed }
        let usedUnconfirmed = confirmed.isEmpty && !scored.isEmpty
        let pool = usedUnconfirmed ? scored : confirmed
        let log = QueryLog(phrase: phrase, scored: scored, skippedIncomparable: skipped, usedUnconfirmed: usedUnconfirmed)
        return RetrievalResult(query: q, ranked: Array(pool.prefix(max(0, topK))), log: log)
    }
}
