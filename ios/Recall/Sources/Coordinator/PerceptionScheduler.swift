import Foundation
#if canImport(PerceptionCore)
import PerceptionCore
#endif

/// Decides when the app may run perception on a camera frame so Memory fills while the robot is parked.
/// Never while driving (blur, and ML would compete with control). The camera and Core ML side is the app's
/// PerceptionLoop; this only gates.
struct PerceptionScheduler {
    private(set) var gate = KeyframeGate()
    private(set) var lastReason = "not started"

    /// - robotStationary: fresh telemetry showing both wheels stopped (`DriveLink.isRobotStationary`).
    mutating func decide(now: Double, robotStationary: Bool, trackingNormal: Bool, modelsAvailable: Bool) -> Bool {
        guard modelsAvailable else { lastReason = "image models not installed"; return false }
        guard robotStationary else { lastReason = "robot not stationary"; return false }
        switch gate.evaluate(now: now, speed: 0, atScanStop: false, trackingNormal: trackingNormal) {
        case .capture: lastReason = "capture"; return true
        case .skip(let reason): lastReason = reason; return false
        }
    }
}
