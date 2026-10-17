/// Memory tuning constants. The association values come from docs/01_ROBOTICS_PLAN.md 4.5.
/// ALL of them are starting guesses to be calibrated on a held-out set; none is a measurement.
public enum MemoryThresholds {
    /// Minimum embedding cosine similarity to match an existing track. TO BE CALIBRATED.
    public static let matchCosine: Float = 0.85
    /// Maximum 3D distance (metres) to match an existing track. TO BE CALIBRATED.
    public static let matchDistance: Float = 0.5
    /// Sightings needed before a track is confirmed. TO BE CALIBRATED.
    public static let confirmSightings = 2
    /// EMA weight of the new observation's position. TO BE CALIBRATED.
    public static let positionAlpha: Float = 0.3
    /// Persistence weights from 4.5: seen -> 0.7p + 0.3, absent -> 0.7p. TO BE CALIBRATED.
    public static let persistenceDecay: Float = 0.7
    /// Similarity below this rewrites the stored embedding. TO BE CALIBRATED.
    public static let rewriteCosine: Float = 0.9
    /// A matched observation further than this (metres) from the track counts as "moved". TO BE CALIBRATED.
    public static let movedDistance: Float = 0.15
    /// Persistence level whose crossing (either way) triggers a rewrite. TO BE CALIBRATED.
    public static let persistenceThreshold: Float = 0.5
}
