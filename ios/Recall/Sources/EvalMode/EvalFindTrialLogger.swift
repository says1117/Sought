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

    /// Furthest the robot may end from the true position and still count as arrived (docs/04_EVALS.md section 5).
    public static let arrivalThresholdM = 0.6

    /// Strict find outcome. `success` needs the trace to say success AND a measured arrival distance within the
    /// threshold AND an accepted track that is a ground-truth target. Missing evidence is `aborted` (unevaluable),
    /// never `success`. Returns the reason when it differs from what the trace reported.
    static func classify(traceOutcome: String, accepted: String?, targets: [String], arrivalDistM: Double?,
                         truth: EvalGroundTruth) -> (EvalOutcome, String) {
        switch traceOutcome {
        case "aborted": return (.aborted, "")
        case "not_found": return (.notFound, "")
        case "success": break
        default: return (.aborted, "unevaluable: unknown trace outcome '\(traceOutcome)'")
        }
        if targets.isEmpty || targets.contains(where: { truth.object(id: $0) == nil }) {
            return (.aborted, "unevaluable: no ground truth for target")
        }
        guard let accepted else { return (.aborted, "unevaluable: trace reported success but no accepted track") }
        if !targets.contains(accepted) { return (.wrongObject, "false accept: accepted \(accepted)") }
        guard let d = arrivalDistM, d.isFinite, d >= 0 else {
            return (.aborted, "unevaluable: arrival distance missing or invalid")
        }
        if d > arrivalThresholdM {
            return (.notFound, "right object accepted but arrival \(evalRound(d, places: 3)) m > \(arrivalThresholdM) m")
        }
        return (.success, "")
    }

    /// `arrivalDistM` is the measured distance from the robot's final pose to the true position, when the
    /// caller has it; required for a `success`; without it the trial is recorded `aborted` (unevaluable).
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
        let (outcome, reason) = Self.classify(traceOutcome: trace.outcome, accepted: accepted, targets: targets,
                                              arrivalDistM: arrivalDistM, truth: truth)
        let notes = [trace.notes, reason].filter { !$0.isEmpty }.joined(separator: "; ")
        let attempts = trace.attempts.map {
            EvalAttemptEntry(trackID: $0.trackID, verdict: $0.verdict, retrievalScore: evalRound(Double($0.retrievalScore)),
                             sImg: $0.sImg.map { evalRound(Double($0)) }, sText: $0.sText.map { evalRound(Double($0)) },
                             reason: $0.reason)
        }
        let trial = EvalTrial(queryID: queryID, text: trace.text, target: EvalTarget(targets), ranked: ranked, outcome: outcome,
                              timeS: evalRound(trace.timeS), nearMisses: trace.nearMisses, notes: notes,
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
