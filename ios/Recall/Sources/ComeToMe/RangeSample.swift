import Foundation

// Latest UWB reading, shared by the robot and the Companion app.
struct RangeSample {
    var distanceM: Double?
    var bearingDeg: Double?     // positive = left of the robot heading
    var updatedAt: Double?      // same clock as the runner's `clock`
}

protocol RangingSource { func latest() -> RangeSample }
