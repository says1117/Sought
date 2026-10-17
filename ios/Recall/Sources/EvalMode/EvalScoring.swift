import Foundation

/// Outcome and position-error rules from docs/04_EVALS.md section 5.
public enum EvalScoring {
    /// A memory track within this many metres of an annotated object counts as that object.
    /// 0.6 m mirrors the find success radius in 04_EVALS.md. A starting value, not a calibrated one.
    public static let defaultMatchRadius = 0.6

    /// Nearest annotated object within `radius` (horizontal plane), nil when none is close enough.
    public static func resolve(x: Double, z: Double, in truth: EvalGroundTruth, radius: Double = defaultMatchRadius) -> EvalGroundTruthObject? {
        var best: (EvalGroundTruthObject, Double)?
        for o in truth.objects {
            let d = hypot(o.x - x, o.z - z)
            if d <= radius, best == nil || d < best!.1 { best = (o, d) }
        }
        return best?.0
    }

    /// Horizontal distance (metres) from a point to the nearest of the target objects.
    public static func positionError(x: Double, z: Double, targets: [String], in truth: EvalGroundTruth) -> Double? {
        let ds = targets.compactMap { truth.object(id: $0) }.map { hypot($0.x - x, $0.z - z) }
        return ds.min()
    }

    /// Retrieval outcome: no candidates -> not_found; top-1 is a valid target -> success; else wrong_object.
    /// `ranked` carries ground-truth ids where resolved (see `EvalRankedEntry`).
    public static func retrievalOutcome(ranked: [EvalRankedEntry], targets: [String]) -> EvalOutcome {
        guard let top = ranked.first else { return .notFound }
        return targets.contains(top.trackID) ? .success : .wrongObject
    }

    public static func top3Hit(ranked: [EvalRankedEntry], targets: [String]) -> Bool {
        ranked.prefix(3).contains { targets.contains($0.trackID) }
    }

    /// Ranked entry for a memory track, relabelled to an object id when it resolves.
    static func entry(trackID: String, score: Double, x: Double, z: Double, truth: EvalGroundTruth, radius: Double) -> EvalRankedEntry {
        let resolved = resolve(x: x, z: z, in: truth, radius: radius)?.id
        return EvalRankedEntry(trackID: resolved ?? trackID, score: evalRound(score), x: evalRound(x, places: 4),
                               z: evalRound(z, places: 4), memoryTrackID: trackID)
    }
}
