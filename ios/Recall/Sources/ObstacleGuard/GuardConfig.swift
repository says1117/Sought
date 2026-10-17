import Foundation

// All values below are PLACEHOLDERS to be tuned on the robot. None has been measured.
// Source of the rules: docs/01_ROBOTICS_PLAN.md section 3.4, docs/03_CONTRACTS.md section 1.
public enum GuardConfig {
    // Decision thresholds (meters). Plan 3.4: < 0.6 slow, < 0.35 stop.
    public static let slowBelowM: Float = 0.6          // PLACEHOLDER
    public static let stopBelowM: Float = 0.35         // PLACEHOLDER

    // Corridor in front of the rover (meters).
    public static let roverWidthM: Float = 0.25        // PLACEHOLDER: measure the chassis
    public static let corridorMarginM: Float = 0.10    // PLACEHOLDER: total, split across both sides
    public static let floorClearanceM: Float = 0.05    // PLACEHOLDER: points lower than this count as floor
    public static let corridorTopM: Float = 0.40       // plan 3.4: "about 40 cm"
    public static let maxRangeM: Float = 3.0           // PLACEHOLDER: ignore anything farther

    // LiDAR limits. Depth at very close range is unreliable; sonar covers it.
    public static let lidarMinRangeM: Float = 0.20     // PLACEHOLDER: samples nearer than this are discarded
    public static let minObstacleSamples = 4           // PLACEHOLDER: fewer corridor hits than this is noise
    public static let minValidFraction: Float = 0.10   // PLACEHOLDER: below this the depth frame is "blind"

    // Phone mount on the rover. PLACEHOLDERS: measure and verify the roll sign on the robot.
    public static let cameraHeightM: Float = 0.20
    public static let cameraPitchDownDeg: Float = 0

    // Detours (plan 3.4).
    public static let maxDetours = 3
    public static let detourDegrees = 30.0
    public static let stopConfirmFrames = 3            // PLACEHOLDER: LiDAR-only stop must persist this many updates before a detour
    public static let progressResetM = 1.0             // PLACEHOLDER: clear travel that refills the detour budget

    // Contract: front_cm / rear_cm 999 = no echo (docs/03_CONTRACTS.md section 1).
    public static let sonarNoEcho = 999
    public static let flagFrontBlocked = 2
    public static let flagRearBlocked = 4
}
