import Foundation
#if canImport(Memory)
import Memory
#endif
#if canImport(Retrieval)
import Retrieval
#endif

/// Offline retrieval over stored memory: no driving, no camera. Produces the raw `retrieval` run file.
public struct EvalRetrievalRunner {
    public let retriever: Retriever
    public var matchRadius: Double
    public var clock: () -> Double

    public init(retriever: Retriever, matchRadius: Double = EvalScoring.defaultMatchRadius,
                clock: @escaping () -> Double = { ProcessInfo.processInfo.systemUptime }) {
        self.retriever = retriever; self.matchRadius = matchRadius; self.clock = clock
    }

    /// Thresholds as they are in code right now (starting guesses, recorded so a run is reproducible).
    public static func thresholdSnapshot(matchRadius: Double) -> [String: Double] {
        [
            "assoc_sim": Double(MemoryThresholds.matchCosine),
            "assoc_dist_m": Double(MemoryThresholds.matchDistance),
            "confirm_sightings": Double(MemoryThresholds.confirmSightings),
            "persistence_floor": Double(RetrievalConfig.persistenceFloor),
            "persistence_weight": Double(RetrievalConfig.persistenceWeight),
            "top_k": Double(RetrievalConfig.topK),
            "gt_match_radius_m": matchRadius,
        ]
    }

    public func run(queries: [EvalQuery], tracks: [Track], truth: EvalGroundTruth, variant: String,
                    commit: String, phoneHeight: String) throws -> EvalRawRun {
        try EvalVariants.validate(variant, kind: .retrieval)
        guard !truth.objects.isEmpty else { throw EvalRunError.emptyGroundTruth }
        for q in queries {
            for t in q.targets where truth.object(id: t) == nil {
                throw EvalRunError.unknownTarget(queryID: q.id, objectID: t)
            }
        }
        var trials: [EvalTrial] = []
        for q in queries {
            let start = clock()
            let result: RetrievalResult
            do {
                result = try retriever.retrieve(phrase: q.text, tracks: tracks)
            } catch {
                trials.append(EvalTrial(queryID: q.id, text: q.text, target: EvalTarget(q.targets), ranked: [],
                                        outcome: .aborted, timeS: max(0, clock() - start),
                                        notes: "query encoding failed: \(error)"))
                continue
            }
            let elapsed = max(0, clock() - start)
            let ranked = result.ranked.map {
                EvalScoring.entry(trackID: $0.trackID, score: Double($0.score), x: Double($0.position.x),
                                  z: Double($0.position.z), truth: truth, radius: matchRadius)
            }
            let outcome = EvalScoring.retrievalOutcome(ranked: ranked, targets: q.targets)
            let err = ranked.first.flatMap { EvalScoring.positionError(x: $0.x, z: $0.z, targets: q.targets, in: truth) }
            var notes = ["top3=\(EvalScoring.top3Hit(ranked: ranked, targets: q.targets) ? "hit" : "miss")",
                         "scored=\(result.log.scored.count)"]
            if result.log.usedUnconfirmed { notes.append("only unconfirmed tracks") }
            if !result.log.skippedIncomparable.isEmpty { notes.append("skipped incomparable=\(result.log.skippedIncomparable.count)") }
            trials.append(EvalTrial(queryID: q.id, text: q.text, target: EvalTarget(q.targets), ranked: ranked,
                                    outcome: outcome, timeS: evalRound(elapsed), notes: notes.joined(separator: "; "),
                                    positionErrorM: err.map { evalRound($0, places: 4) }))
        }
        return EvalRawRun(kind: .retrieval, commit: commit, variant: variant, phoneHeight: phoneHeight,
                          thresholds: Self.thresholdSnapshot(matchRadius: matchRadius), trials: trials)
    }
}
