import Foundation

/// Structured trace of one find. The first block of fields matches one `trials[]` entry of the raw run
/// file in docs/04_EVALS.md section 7 (`outcome` is success | not_found | aborted; `wrong_object` is
/// decided later by comparing `found_track_id` with `target`). The extra fields feed the dashboard.
public struct FindTrace: Codable, Equatable {
    public var queryID: String
    public var text: String
    public var target: String?
    public var ranked: [RankedEntry]
    public var outcome: String
    public var timeS: Double
    public var nearMisses: Int
    public var notes: String
    // Extras beyond the eval schema.
    public var foundTrackID: String?
    public var attempts: [AttemptEntry]
    public var spoken: String

    enum CodingKeys: String, CodingKey {
        case queryID = "query_id", text, target, ranked, outcome, timeS = "time_s", nearMisses = "near_misses", notes
        case foundTrackID = "found_track_id", attempts, spoken
    }

    /// Stable JSON (sorted keys) for run files and the dashboard.
    public func jsonData() throws -> Data {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys]
        return try e.encode(self)
    }
}

public struct RankedEntry: Codable, Equatable {
    public var trackID: String
    public var score: Float
    public var x: Float
    public var z: Float
    enum CodingKeys: String, CodingKey { case trackID = "track_id", score, x, z }
}

public struct AttemptEntry: Codable, Equatable {
    public var trackID: String
    public var verdict: String
    public var retrievalScore: Float
    public var sImg: Float?
    public var sText: Float?
    public var reason: String

    init(_ a: CandidateAttempt) {
        trackID = a.trackID; verdict = a.verdict.rawValue; retrievalScore = a.retrievalScore
        sImg = a.sImg; sText = a.sText; reason = a.reason
    }
    enum CodingKeys: String, CodingKey {
        case trackID = "track_id", verdict, retrievalScore = "retrieval_score", sImg = "s_img", sText = "s_text", reason
    }
}
