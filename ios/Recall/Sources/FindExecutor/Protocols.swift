import Foundation

/// Outcome of one drive-to-candidate attempt.
public enum ApproachOutcome: Equatable {
    case arrived
    /// The controller gave up (blocked, tracking lost, timeout...). `reason` is free text for the trace.
    case failed(reason: String)
    /// The user or caller cancelled; the whole find stops.
    case cancelled
}

public struct ApproachReport: Equatable {
    public var outcome: ApproachOutcome
    /// Obstacle-guard near-misses seen during this drive, for the eval trial's `near_misses`.
    public var nearMisses: Int
    public init(outcome: ApproachOutcome, nearMisses: Int = 0) {
        self.outcome = outcome; self.nearMisses = nearMisses
    }
}

/// Drive abstraction. The real adapter wraps Controller.goTo(x:z:stopDistance:) followed by a
/// rotateBy so the phone faces the target; that adapter is not written here (Controller is internal
/// to its own module today).
public protocol ApproachDriver {
    /// Drive to within `stopDistance` metres of (x, z) and finish facing it.
    func approach(x: Double, z: Double, stopDistance: Double) async -> ApproachReport
}

/// Camera + Core ML image encoder. The real adapter projects the 3D point into the current ARKit
/// frame, crops `cropScale` times the stored box, and embeds the crop with MobileCLIP-S0.
public protocol ImageEmbedder {
    /// Embeddings of `count` crops around the world point `position`. May return fewer when frames
    /// are unavailable (the executor treats an empty result as "could not look").
    func captureEmbeddings(around position: SIMD3<Float>, count: Int, cropScale: Float) async throws -> [[Float]]
}
