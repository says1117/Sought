import Foundation
#if canImport(FindExecutor)
import FindExecutor
#endif
#if canImport(Memory)
import Memory
#endif
#if canImport(Retrieval)
import Retrieval
#endif

/// Collects end-to-end find trials into the raw `find` run format. It only records what a
/// `FindExecutor` trace says happened; it never drives and never fills in missing measurements.
public final class EvalFindTrialLogger {
    public private(set) var trials: [EvalTrial] = []
    private let truth: EvalGroundTruth
    private let matchRadius: Double

    public init(truth: EvalGroundTruth, matchRadius: Double = EvalScoring.defaultMatchRadius) {
        self.truth = truth; self.matchRadius = matchRadius
    }

    /// `arrivalDistM` is the measured distance from the robot's final pose to the true position, when the
    /// caller has it; leave nil otherwise (the aggregator then relies on `outcome` alone).
    @discardableResult
    public func record(trace: FindTrace, queryID: String, targets: [String], arrivalDistM: Double? = nil) -> EvalTrial {
        let ranked = trace.ranked.map {
            EvalScoring.entry(trackID: $0.trackID, score: Double($0.score), x: Double($0.x), z: Double($0.z),
                              truth: truth, radius: matchRadius)
        }
        // Resolve the accepted track the same way as ranked entries.
        let accepted: String? = trace.foundTrackID.flatMap { id in
            trace.ranked.first { $0.trackID == id }.map {
                EvalScoring.entry(trackID: id, score: 0, x: Double($0.x), z: Double($0.z), truth: truth, radius: matchRadius).trackID
            } ?? id
        }
        var outcome: EvalOutcome
        switch trace.outcome {
        case "success": outcome = .success
        case "aborted": outcome = .aborted
        default: outcome = .notFound
        }
        if outcome == .success, let a = accepted, !targets.contains(a) { outcome = .wrongObject }
        let attempts = trace.attempts.map {
            EvalAttemptEntry(trackID: $0.trackID, verdict: $0.verdict, retrievalScore: evalRound(Double($0.retrievalScore)),
                             sImg: $0.sImg.map { evalRound(Double($0)) }, sText: $0.sText.map { evalRound(Double($0)) },
                             reason: $0.reason)
        }
        let trial = EvalTrial(queryID: queryID, text: trace.text, target: EvalTarget(targets), ranked: ranked, outcome: outcome,
                              timeS: evalRound(trace.timeS), nearMisses: trace.nearMisses, notes: trace.notes,
                              acceptedTrackID: accepted, arrivalDistM: arrivalDistM, attempts: attempts)
        trials.append(trial)
        return trial
    }

    public func makeRun(variant: String, commit: String, phoneHeight: String, tauImg: Double,
                        textFraction: Double) throws -> EvalRawRun {
        try EvalVariants.validate(variant, kind: .find)
        var thresholds = EvalRetrievalRunner.thresholdSnapshot(matchRadius: matchRadius)
        thresholds["tau_img"] = tauImg
        thresholds["text_fraction"] = textFraction
        return EvalRawRun(kind: .find, commit: commit, variant: variant, phoneHeight: phoneHeight,
                          thresholds: thresholds, trials: trials)
    }
}
