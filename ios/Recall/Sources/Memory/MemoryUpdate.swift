/// Which stored fields must be rewritten after a matched observation (docs/01_ROBOTICS_PLAN.md 4.5).
/// `last_seen`, `sightings` and `persistence` are always updated and are not listed here.
public struct UpdatePlan: Equatable {
    public var rewritePosition = false
    public var rewriteEmbedding = false
    public var rewriteThumbnail = false
    /// True only when the track just became confirmed (keyframes are stored only then or on events).
    public var storeKeyframe = false
}

public enum EmbeddingPolicy {
    /// Keep the embedding of the highest-confidence detection. Plan says to test both policies.
    case bestConfidence(storedConfidence: Float)
    /// Running mean over sightings, renormalised.
    case runningMean
}

/// `p = 0.7p + 0.3` if seen, `p = 0.7p` if absent. Call for absent only when the expected location was visible.
public func updatedPersistence(_ p: Float, seen: Bool) -> Float {
    let d = MemoryThresholds.persistenceDecay
    return min(1, max(0, d * p + (seen ? 1 - d : 0)))
}

/// EMA position update for a matched track.
///
/// Caveat: with alpha 0.3 a single observation of an object that moved 0.4 m only shifts the stored
/// position by 0.12 m, so a moved object's stored position lags the truth and converges only over
/// several sightings. TODO(Patrol task): moved-object handling needs an explicit re-anchor path
/// (e.g. snap position to the observation when distance > movedDistance); not implemented here.
public func emaPosition(old: SIMD3<Float>, observed: SIMD3<Float>,
                        alpha: Float = MemoryThresholds.positionAlpha) -> SIMD3<Float> {
    old + (observed - old) * alpha
}

/// Decide what to rewrite. Position, embedding and thumbnail are rewritten only if the track moved,
/// similarity dropped below `rewriteCosine`, or persistence crossed `persistenceThreshold`.
public func planUpdate(track: Track, observation: Observation, cosine sim: Float, distance dist: Float) -> UpdatePlan {
    let newP = updatedPersistence(track.persistence, seen: true)
    let t = MemoryThresholds.persistenceThreshold
    let crossed = (track.persistence < t) != (newP < t)
    let rewrite = dist > MemoryThresholds.movedDistance || sim < MemoryThresholds.rewriteCosine || crossed
    var plan = UpdatePlan()
    plan.rewritePosition = rewrite
    plan.rewriteEmbedding = rewrite
    plan.rewriteThumbnail = rewrite
    plan.storeKeyframe = !track.isConfirmed && track.sightings + 1 >= MemoryThresholds.confirmSightings
    return plan
}

/// Apply a matched observation. Returns the updated track and the plan the storage layer must honour.
public func applyMatch(track: Track, observation: Observation, cosine sim: Float, distance dist: Float,
                       embeddingPolicy: EmbeddingPolicy = .runningMean) -> (Track, UpdatePlan) {
    let plan = planUpdate(track: track, observation: observation, cosine: sim, distance: dist)
    var t = track
    t.lastSeen = observation.time
    t.persistence = updatedPersistence(track.persistence, seen: true)
    t.sightings += 1
    if plan.rewritePosition {
        t.position = emaPosition(old: track.position, observed: observation.position)
    }
    if plan.rewriteEmbedding {
        switch embeddingPolicy {
        case .bestConfidence(let stored):
            if observation.confidence > stored { t.embedding = observation.embedding }
        case .runningMean:
            // Dimension mismatch (model changed): adopt the new embedding rather than trap.
            t.embedding = runningMean(track.embedding, count: track.sightings, adding: observation.embedding)
                ?? observation.embedding
        }
    }
    return (t, plan)
}

/// Running mean renormalised, or nil when dimensions differ.
func runningMean(_ mean: [Float], count n: Int, adding x: [Float]) -> [Float]? {
    guard mean.count == x.count else { return nil }
    let merged = zip(mean, x).map { ($0 * Float(n) + $1) / Float(n + 1) }
    let norm = merged.reduce(0) { $0 + $1 * $1 }.squareRoot()
    return norm > 0 ? merged.map { $0 / norm } : merged
}

/// Create a new, unconfirmed track from an observation.
public func newTrack(id: String, from obs: Observation) -> Track {
    Track(id: id, position: obs.position, embedding: obs.embedding, sightings: 1,
          persistence: updatedPersistence(0, seen: true), lastSeen: obs.time)
}
