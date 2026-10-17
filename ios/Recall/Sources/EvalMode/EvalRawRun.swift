import Foundation

public enum EvalOutcome: String, Codable, Equatable {
    case success
    case wrongObject = "wrong_object"
    case notFound = "not_found"
    case aborted
}

public enum EvalRunKind: String, Codable, Equatable {
    case retrieval, find
}

/// One ranked candidate in a raw trial. `trackID` is the ground-truth object id when the track lies
/// within the match radius of an annotated object (so the aggregator in evals/make_tables.py can compare
/// it with `target`); otherwise it is the memory track id. `memoryTrackID` always keeps the real id.
public struct EvalRankedEntry: Codable, Equatable {
    public var trackID: String
    public var score: Double
    public var x: Double
    public var z: Double
    public var memoryTrackID: String?
    enum CodingKeys: String, CodingKey { case trackID = "track_id", score, x, z, memoryTrackID = "memory_track_id" }
    public init(trackID: String, score: Double, x: Double, z: Double, memoryTrackID: String? = nil) {
        self.trackID = trackID; self.score = score; self.x = x; self.z = z; self.memoryTrackID = memoryTrackID
    }
}

/// `target` is a string for one object and an array for ambiguous queries with two valid objects.
public struct EvalTarget: Codable, Equatable {
    public var ids: [String]
    public init(_ ids: [String]) { self.ids = ids }
    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let s = try? c.decode(String.self) { ids = [s] } else { ids = try c.decode([String].self) }
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        if ids.count == 1 { try c.encode(ids[0]) } else { try c.encode(ids) }
    }
}

/// One `trials[]` entry of docs/04_EVALS.md section 7, plus optional extras the aggregator ignores.
public struct EvalTrial: Codable, Equatable {
    public var queryID: String
    public var text: String
    public var target: EvalTarget
    public var ranked: [EvalRankedEntry]
    public var outcome: EvalOutcome
    public var timeS: Double
    public var nearMisses: Int
    public var notes: String
    // Optional extras (omitted when nil).
    public var positionErrorM: Double?
    public var acceptedTrackID: String?
    public var arrivalDistM: Double?
    public var attempts: [EvalAttemptEntry]?

    enum CodingKeys: String, CodingKey {
        case queryID = "query_id", text, target, ranked, outcome, timeS = "time_s", nearMisses = "near_misses", notes
        case positionErrorM = "position_error_m", acceptedTrackID = "accepted_track_id"
        case arrivalDistM = "arrival_dist_m", attempts
    }

    public init(queryID: String, text: String, target: EvalTarget, ranked: [EvalRankedEntry], outcome: EvalOutcome,
                timeS: Double, nearMisses: Int = 0, notes: String = "", positionErrorM: Double? = nil,
                acceptedTrackID: String? = nil, arrivalDistM: Double? = nil, attempts: [EvalAttemptEntry]? = nil) {
        self.queryID = queryID; self.text = text; self.target = target; self.ranked = ranked; self.outcome = outcome
        self.timeS = timeS; self.nearMisses = nearMisses; self.notes = notes; self.positionErrorM = positionErrorM
        self.acceptedTrackID = acceptedTrackID; self.arrivalDistM = arrivalDistM; self.attempts = attempts
    }
}

/// Arrival-check detail for one candidate visited during a find trial.
public struct EvalAttemptEntry: Codable, Equatable {
    public var trackID: String
    public var verdict: String
    public var retrievalScore: Double
    public var sImg: Double?
    public var sText: Double?
    public var reason: String
    enum CodingKeys: String, CodingKey {
        case trackID = "track_id", verdict, retrievalScore = "retrieval_score", sImg = "s_img", sText = "s_text", reason
    }
}

/// The whole raw run file (`evals/results/run_<timestamp>_<kind>.json`).
public struct EvalRawRun: Codable, Equatable {
    public var kind: EvalRunKind
    public var commit: String
    public var variant: String
    public var phoneHeight: String
    public var thresholds: [String: Double]
    public var trials: [EvalTrial]
    enum CodingKeys: String, CodingKey { case kind, commit, variant, phoneHeight = "phone_height", thresholds, trials }

    public init(kind: EvalRunKind, commit: String, variant: String, phoneHeight: String,
                thresholds: [String: Double], trials: [EvalTrial]) {
        self.kind = kind; self.commit = commit; self.variant = variant; self.phoneHeight = phoneHeight
        self.thresholds = thresholds; self.trials = trials
    }

    public func jsonData() throws -> Data {
        for t in trials {
            guard t.timeS.isFinite, t.ranked.allSatisfy({ $0.score.isFinite && $0.x.isFinite && $0.z.isFinite }) else {
                throw EvalRunError.nonFiniteValue(queryID: t.queryID)
            }
        }
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try e.encode(self)
    }

    /// `run_<UTC timestamp>_<kind>.json`, for example `run_20261017T143000Z_retrieval.json`.
    public static func fileName(kind: EvalRunKind, date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        return "run_\(f.string(from: date))_\(kind.rawValue).json"
    }

    /// Writes into `directory` (created if needed). The caller picks the directory; nothing defaults to evals/results.
    @discardableResult
    public func write(toDirectory directory: URL, date: Date = Date()) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(EvalRawRun.fileName(kind: kind, date: date))
        try jsonData().write(to: url, options: .atomic)
        return url
    }
}

public enum EvalRunError: Error, Equatable {
    case nonFiniteValue(queryID: String)
    case emptyGroundTruth
    case unknownTarget(queryID: String, objectID: String)
    case variantNotRunnable(variant: String, kind: String)
}

/// Variants that exist in code. Retrieval ranking is the same embedding code for both proposal
/// settings; which proposals built the stored memory is the operator's responsibility and is recorded
/// in the run file's variant name. `yolo_labels_only` (no label ranking), `clip_plus_gemini_rerank` and
/// `clip_plus_adapter` have no implementation yet, so they are deliberately absent.
public enum EvalVariants {
    public static let retrieval: [String] = ["clip_yolo_proposals", "clip_full_proposals"]
    public static let find: [String] = ["clip_plus_arrival_check"]

    public static func validate(_ variant: String, kind: EvalRunKind) throws {
        let allowed = kind == .retrieval ? retrieval : find
        guard allowed.contains(variant) else {
            throw EvalRunError.variantNotRunnable(variant: variant, kind: kind.rawValue)
        }
    }
}

/// Rounds values for stable files; this is formatting, not data processing.
func evalRound(_ v: Double, places: Int = 6) -> Double {
    let m = pow(10.0, Double(places))
    return (v * m).rounded() / m
}
