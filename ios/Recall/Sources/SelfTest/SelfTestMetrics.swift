import Foundation
#if canImport(PoseCore)
import PoseCore
#endif

// Pure metric math for the self-test. tools/motion_report.py recomputes the same definitions from the raw log;
// keep the two in step (see docs/field-test-checklist.md "Metric definitions").

enum SelfTestMetrics {
    /// Unit vector (x, z) the rover faces at `yawDeg`. Yaw 0 faces -z, +90 faces -x (CCW positive from above).
    static func forwardUnit(yawDeg: Double) -> (x: Double, z: Double) {
        let r = yawDeg * .pi / 180
        return (-sin(r), -cos(r))
    }

    /// Signed distance of `p` from `origin` along the heading `u`.
    static func alongTrack(origin: Pose2D, u: (x: Double, z: Double), p: Pose2D) -> Double {
        (p.x - origin.x) * u.x + (p.z - origin.z) * u.z
    }

    /// Signed sideways offset of `p` from the line through `origin` along `u`. Positive = left of the heading.
    static func lateral(origin: Pose2D, u: (x: Double, z: Double), p: Pose2D) -> Double {
        (p.x - origin.x) * u.z - (p.z - origin.z) * u.x
    }

    static func distance(_ a: Pose2D, _ b: Pose2D) -> Double {
        let dx = a.x - b.x, dz = a.z - b.z
        return (dx * dx + dz * dz).squareRoot()
    }

    static func mean(_ v: [Double]) -> Double? {
        v.isEmpty ? nil : v.reduce(0, +) / Double(v.count)
    }

    /// Status rate from receive times. Needs at least 2 samples and a positive span.
    static func statusRateHz(times: [Double]) -> Double? {
        guard times.count >= 2, let first = times.first, let last = times.last, last > first else { return nil }
        return Double(times.count - 1) / (last - first)
    }

    /// Seconds from `suspendT` to the first status that shows both motors at zero, or nil if none.
    static func watchdogStopLatency(suspendT: Double, statuses: [TimedStatus]) -> Double? {
        statuses.first { $0.t >= suspendT && $0.left == 0 && $0.right == 0 }.map { $0.t - suspendT }
    }

    /// Seconds from `suspendT` to the first status with the watchdog flag set, or nil if none.
    static func watchdogFlagLatency(suspendT: Double, statuses: [TimedStatus]) -> Double? {
        statuses.first { $0.t >= suspendT && $0.watchdogStopped }.map { $0.t - suspendT }
    }
}

/// Total rotation from consecutive yaw samples, unwrapped. Positive = counter-clockwise (left).
/// Valid while the rover turns less than 180 degrees between samples (10 Hz tick: more than 1800 deg/s would break it).
struct YawAccumulator {
    private(set) var total = 0.0
    private var last: Double?

    mutating func add(yawDeg: Double) {
        if let l = last { total += PoseMath.shortestDelta(from: l, to: yawDeg) }
        last = yawDeg
    }

    mutating func reset() { total = 0; last = nil }
}
