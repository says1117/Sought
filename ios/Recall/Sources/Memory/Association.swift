/// A remembered object. Pure value type: persistence to SQLite happens elsewhere.
public struct Track: Equatable {
    public var id: String
    public var position: SIMD3<Float>
    public var embedding: [Float]
    public var sightings: Int
    public var persistence: Float
    public var lastSeen: Double

    public init(id: String, position: SIMD3<Float>, embedding: [Float],
                sightings: Int = 1, persistence: Float = 0.3, lastSeen: Double = 0) {
        self.id = id; self.position = position; self.embedding = embedding
        self.sightings = sightings; self.persistence = persistence; self.lastSeen = lastSeen
    }

    public var isConfirmed: Bool { sightings >= MemoryThresholds.confirmSightings }
}

/// One detection from the perception pipeline, already lifted to a 3D world position.
public struct Observation {
    public var position: SIMD3<Float>
    public var embedding: [Float]
    public var confidence: Float
    public var time: Double

    public init(position: SIMD3<Float>, embedding: [Float], confidence: Float = 1, time: Double = 0) {
        self.position = position; self.embedding = embedding
        self.confidence = confidence; self.time = time
    }
}

/// Score of one track against one observation. Logged for every candidate (feeds the evals).
public struct Candidate: Equatable {
    public var trackID: String
    public var cosine: Float
    public var distance: Float
    public var passes: Bool
}

public enum AssociationResult: Equatable {
    case matched(trackID: String, cosine: Float, distance: Float)
    case newTrack
}

public struct Association {
    public var result: AssociationResult
    public var candidates: [Candidate]
}

public func cosine(_ a: [Float], _ b: [Float]) -> Float {
    precondition(a.count == b.count, "embedding dimension mismatch")
    var dot: Float = 0, na: Float = 0, nb: Float = 0
    for i in a.indices { dot += a[i] * b[i]; na += a[i] * a[i]; nb += b[i] * b[i] }
    let denom = (na * nb).squareRoot()
    return denom > 0 ? dot / denom : 0
}

func distance(_ a: SIMD3<Float>, _ b: SIMD3<Float>) -> Float {
    let d = a - b
    return (d * d).sum().squareRoot()
}

/// Match an observation to the best existing track: cosine >= matchCosine AND distance < matchDistance.
/// Among passing tracks the highest cosine wins (ties: nearer). Otherwise it is a new track.
public func associate(_ obs: Observation, tracks: [Track]) -> Association {
    let candidates = tracks.map { t -> Candidate in
        let c = cosine(obs.embedding, t.embedding)
        let d = distance(obs.position, t.position)
        return Candidate(trackID: t.id, cosine: c, distance: d,
                         passes: c >= MemoryThresholds.matchCosine && d < MemoryThresholds.matchDistance)
    }
    let best = candidates.filter(\.passes).max {
        $0.cosine != $1.cosine ? $0.cosine < $1.cosine : $0.distance > $1.distance
    }
    let result = best.map { AssociationResult.matched(trackID: $0.trackID, cosine: $0.cosine, distance: $0.distance) }
    return Association(result: result ?? .newTrack, candidates: candidates)
}
