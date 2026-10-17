import Foundation

/// Exponential backoff with symmetric jitter: delay = min(cap, base * factor^attempts) * (1 + jitter * (2r - 1)),
/// r in [0,1). `attempts` is the number of failures so far (1 after the first failure).
/// Defaults: 1, 2, 4, 8, 16, 32, 60, 60 ... seconds, each +-25%.
public struct Backoff: Equatable {
    public var base: Double = 1
    public var factor: Double = 2
    public var cap: Double = 60
    public var jitter: Double = 0.25
    public init(base: Double = 1, factor: Double = 2, cap: Double = 60, jitter: Double = 0.25) {
        self.base = base; self.factor = factor; self.cap = cap; self.jitter = jitter
    }
    public func delay(afterFailures attempts: Int, random r: Double = Double.random(in: 0..<1)) -> Double {
        let raw = min(cap, base * pow(factor, Double(max(0, attempts - 1))))
        return raw * (1 + jitter * (2 * r - 1))
    }
}
