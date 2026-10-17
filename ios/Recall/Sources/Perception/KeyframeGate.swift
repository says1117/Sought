import Foundation

public struct KeyframeGateConfig: Equatable {
    /// Capture only below this speed (m/s), unless at a scan stop.
    public var maxSpeed: Double = 0.15
    /// Minimum seconds between keyframes.
    public var minInterval: Double = 0.5
    /// Overall cap on ML runs per second (2 Hz).
    public var maxPerSecond: Int = 2
    public init() {}
}

public enum KeyframeDecision: Equatable {
    case capture
    case skip(reason: String)
}

/// docs/01_ROBOTICS_PLAN.md 4.1. Pure and clock-free: the caller passes `now`.
public struct KeyframeGate {
    public var config: KeyframeGateConfig
    private var lastTime: Double?
    private var recent: [Double] = []

    public init(config: KeyframeGateConfig = KeyframeGateConfig()) { self.config = config }

    /// Ask whether to run perception on this frame. Records the capture when it says `.capture`.
    /// - speed: nil when unknown (treated as moving unless `atScanStop`).
    public mutating func evaluate(now: Double, speed: Double?, atScanStop: Bool, trackingNormal: Bool) -> KeyframeDecision {
        guard trackingNormal else { return .skip(reason: "tracking not normal") }
        if !atScanStop {
            guard let s = speed, s < config.maxSpeed else { return .skip(reason: "moving") }
        }
        if let last = lastTime, now - last < config.minInterval { return .skip(reason: "too soon") }
        recent.removeAll { now - $0 >= 1.0 }
        if recent.count >= config.maxPerSecond { return .skip(reason: "rate cap") }
        lastTime = now
        recent.append(now)
        return .capture
    }

    public mutating func reset() { lastTime = nil; recent.removeAll() }
}
