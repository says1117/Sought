import Foundation
#if canImport(Memory)
import Memory
#endif
#if canImport(Retrieval)
import Retrieval
#endif

/// Arrival-check constants from docs/01_ROBOTICS_PLAN.md 4.7.
/// `tauImg` is a placeholder to be calibrated on a separate calibration set; it is not a measurement.
public struct FindConfig: Equatable {
    public var tauImg: Float = 0.80
    /// s_text must reach this fraction of the candidate's retrieval score.
    public var textFraction: Float = 0.9
    public var maxCandidates = 3
    public var arrivalDistance = 0.8
    public var cropsPerCandidate = 3
    public var cropScale: Float = 1.5
    public init() {}
}

public enum CandidateVerdict: String, Equatable {
    case accepted
    case notHere = "not_here"
    case unreachable
    case noView = "no_view"
}

/// What happened at one candidate, for the dashboard and failure analysis.
public struct CandidateAttempt: Equatable {
    public var trackID: String
    public var retrievalScore: Float
    public var x: Float
    public var z: Float
    public var verdict: CandidateVerdict
    public var sImg: Float?
    public var sText: Float?
    public var reason: String
}

public enum FindOutcome: String, Equatable {
    case success
    case notFound = "not_found"
    case aborted
}

public struct FindResult: Equatable {
    public var outcome: FindOutcome
    public var foundTrackID: String?
    public var spoken: String
    public var attempts: [CandidateAttempt]
    /// Tracks the arrival check rejected; the caller may persist these as "not here".
    public var notHereTrackIDs: [String]
    public var trace: FindTrace
}

public struct FindExecutor {
    public let retriever: Retriever
    public let driver: ApproachDriver
    public let images: ImageEmbedder
    public var config: FindConfig
    /// Turns a world position into speech ("near the front door"). Default is plain coordinates.
    public var describeLocation: (SIMD3<Float>) -> String
    public var clock: () -> Double

    public init(retriever: Retriever, driver: ApproachDriver, images: ImageEmbedder, config: FindConfig = FindConfig(),
                describeLocation: @escaping (SIMD3<Float>) -> String = FindExecutor.coordinateDescription,
                clock: @escaping () -> Double = { ProcessInfo.processInfo.systemUptime }) {
        self.retriever = retriever; self.driver = driver; self.images = images; self.config = config
        self.describeLocation = describeLocation; self.clock = clock
    }

    public static func coordinateDescription(_ p: SIMD3<Float>) -> String {
        String(format: "at x %.1f, z %.1f", p.x, p.z)
    }

    /// Retrieve, then visit up to `maxCandidates` in rank order, accepting the first that passes the arrival check.
    /// `queryID` and `targetTrackID` are only recorded in the trace (evals); they do not affect behaviour.
    public func find(phrase: String, tracks: [Track], queryID: String = "", targetTrackID: String? = nil) async -> FindResult {
        let start = clock()
        var attempts: [CandidateAttempt] = []
        var nearMisses = 0
        var outcome = FindOutcome.notFound
        var found: String?
        var notes: [String] = []

        let retrieval: RetrievalResult
        do {
            retrieval = try retriever.retrieve(phrase: phrase, tracks: tracks)
        } catch {
            notes.append("query encoding failed: \(error)")
            return finish(phrase, queryID, targetTrackID, nil, [], .notFound, nil, 0, start, notes,
                          spoken: "I couldn't work out what to look for.")
        }
        if retrieval.log.usedUnconfirmed { notes.append("only unconfirmed tracks were available") }
        if !retrieval.log.rejectedByNegatives.isEmpty {
            notes.append("\(retrieval.log.rejectedByNegatives.count) of \(retrieval.log.scored.count) regions matched a person/wall/floor/furniture better (ranked last)")
        }
        if retrieval.ranked.contains(where: { $0.margin != 0 }) {
            notes.append("margins: " + retrieval.ranked.prefix(config.maxCandidates)
                .map { String(format: "%@ %.3f", String($0.trackID.suffix(4)), $0.margin) }.joined(separator: ", "))
        }
        if !retrieval.log.skippedIncomparable.isEmpty {
            notes.append("skipped incomparable tracks: \(retrieval.log.skippedIncomparable.joined(separator: ","))")
        }

        for cand in retrieval.ranked.prefix(config.maxCandidates) {
            if Task.isCancelled { outcome = .aborted; break }
            let report = await driver.approach(x: Double(cand.position.x), z: Double(cand.position.z),
                                               stopDistance: config.arrivalDistance)
            nearMisses += report.nearMisses
            switch report.outcome {
            case .cancelled:
                outcome = .aborted
            case .failed(let reason):
                attempts.append(attempt(cand, .unreachable, nil, nil, "drive failed: \(reason)"))
            case .arrived:
                let a = await check(cand, query: retrieval.query, negatives: retrieval.negatives)
                attempts.append(a)
                if a.verdict == .accepted { found = cand.trackID; outcome = .success }
            }
            if outcome != .notFound { break }
        }

        let foundCand = retrieval.ranked.first { $0.trackID == found }
        return finish(phrase, queryID, targetTrackID, retrieval, attempts, outcome, foundCand, nearMisses, start, notes,
                      spoken: nil)
    }

    private func check(_ cand: RankedTrack, query: [Float], negatives: [[Float]]) async -> CandidateAttempt {
        let embs: [[Float]]
        do {
            embs = try await images.captureEmbeddings(around: cand.position, count: config.cropsPerCandidate,
                                                      cropScale: config.cropScale)
        } catch {
            return attempt(cand, .noView, nil, nil, "capture failed: \(error)")
        }
        guard !embs.isEmpty else { return attempt(cand, .noView, nil, nil, "no crops captured") }
        // Best crop for each score independently (max over the captured frames).
        let sImg = embs.compactMap { cosine($0, cand.embedding) }.max()
        let sText = embs.compactMap { cosine($0, query) }.max()
        guard let si = sImg, let st = sText else {
            return attempt(cand, .notHere, nil, nil, "embedding dimension mismatch")
        }
        let needText = config.textFraction * cand.score
        // Contrastive veto (arrival negatives, i.e. "a person"): at least one crop must look more like the query than
        // like every arrival negative. s_img alone only says "same region as remembered"; it accepted a person as
        // "bottle" on the rover. Background prompts are not used here (an object's crop contains floor around it).
        var contrastOK = true
        var bestMargin: Float?
        if !negatives.isEmpty {
            bestMargin = embs.compactMap { e -> Float? in
                guard let t = cosine(e, query) else { return nil }
                return t - (negatives.compactMap { cosine($0, e) }.max() ?? -1)
            }.max()
            contrastOK = (bestMargin ?? -1) > 0
        }
        let marginText = bestMargin.map { String(format: "; text margin %.3f", $0) } ?? ""
        if si >= config.tauImg && st >= needText && contrastOK {
            return attempt(cand, .accepted, si, st, "s_img >= tau_img and s_text >= \(config.textFraction) * score" + marginText)
        }
        var why: [String] = []
        if si < config.tauImg { why.append("s_img below tau_img") }
        if st < needText { why.append("s_text below \(config.textFraction) * score") }
        if !contrastOK { why.append("looks more like a person than the query" + marginText) }
        return attempt(cand, .notHere, si, st, why.joined(separator: "; "))
    }

    private func attempt(_ c: RankedTrack, _ v: CandidateVerdict, _ si: Float?, _ st: Float?, _ reason: String) -> CandidateAttempt {
        CandidateAttempt(trackID: c.trackID, retrievalScore: c.score, x: c.position.x, z: c.position.z,
                         verdict: v, sImg: si, sText: st, reason: reason)
    }

    private func finish(_ phrase: String, _ queryID: String, _ target: String?, _ retrieval: RetrievalResult?,
                        _ attempts: [CandidateAttempt], _ outcome: FindOutcome, _ found: RankedTrack?,
                        _ nearMisses: Int, _ start: Double, _ notes: [String], spoken: String?) -> FindResult {
        let text = spoken ?? speak(phrase, outcome, found, attempts, retrieval)
        let trace = FindTrace(queryID: queryID, text: phrase, target: target,
                              ranked: (retrieval?.ranked ?? []).map { RankedEntry(trackID: $0.trackID, score: $0.score, x: $0.position.x, z: $0.position.z) },
                              outcome: outcome.rawValue, timeS: max(0, clock() - start), nearMisses: nearMisses,
                              notes: notes.joined(separator: "; "), foundTrackID: found?.trackID,
                              attempts: attempts.map(AttemptEntry.init), spoken: text)
        return FindResult(outcome: outcome, foundTrackID: found?.trackID, spoken: text, attempts: attempts,
                          notHereTrackIDs: attempts.filter { $0.verdict == .notHere }.map { $0.trackID }, trace: trace)
    }

    private func speak(_ phrase: String, _ outcome: FindOutcome, _ found: RankedTrack?,
                       _ attempts: [CandidateAttempt], _ retrieval: RetrievalResult?) -> String {
        switch outcome {
        case .success:
            guard let f = found else { return "Found \(phrase)." }
            return "Found \(phrase) \(describeLocation(f.position))."
        case .aborted:
            return "Stopped looking for \(phrase)."
        case .notFound:
            guard let r = retrieval, !r.ranked.isEmpty else {
                return "I don't have anything in memory that matches \(phrase)."
            }
            let guesses = attempts.map { describeLocation(SIMD3<Float>($0.x, 0, $0.z)) }
            if guesses.isEmpty {
                return "I couldn't get to any place where \(phrase) might be."
            }
            return "I couldn't confirm \(phrase). I checked \(guesses.count) likely place\(guesses.count == 1 ? "" : "s") and it wasn't there: \(guesses.joined(separator: "; "))."
        }
    }
}
