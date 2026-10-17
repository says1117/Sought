import Foundation
#if canImport(PoseCore)
import PoseCore
#endif

/// Time source, injected so the 20 s timeout is testable without waiting.
public protocol RelocClock {
    /// Monotonic seconds.
    func now() -> Double
}

public struct SystemRelocClock: RelocClock {
    public init() {}
    public func now() -> Double { ProcessInfo.processInfo.systemUptime }
}

public enum RelocalizationState: Equatable {
    /// Not started, or no saved map to relocalize against (go straight to a fresh Teach).
    case idle
    case waiting(elapsed: Double)
    case relocalized
    /// 20 s passed without normal tracking and a mapped status. UI shows "Rescan needed".
    case rescanNeeded
}

/// Decides when a loaded world map has been recognized. Pure: feed it tracking updates and clock ticks.
/// Plan section 3.2: wait for `.normal` tracking and `.mapped` status; after 20 s show "Rescan needed".
public final class RelocalizationMonitor {
    public static let timeout: Double = 20

    public private(set) var state: RelocalizationState = .idle
    private let clock: RelocClock
    private let timeout: Double
    private var startedAt: Double?

    public init(clock: RelocClock = SystemRelocClock(), timeout: Double = RelocalizationMonitor.timeout) {
        self.clock = clock
        self.timeout = timeout
    }

    /// Call when the session starts with a loaded map. Without a map there is nothing to wait for.
    public func start(hasSavedMap: Bool) {
        guard hasSavedMap else { startedAt = nil; state = .idle; return }
        startedAt = clock.now()
        state = .waiting(elapsed: 0)
    }

    /// Feed each tracking update. A late success after the timeout still recovers.
    @discardableResult
    public func update(tracking: TrackingKind, mapping: MappingKind) -> RelocalizationState {
        guard startedAt != nil else { return state }
        if tracking == .normal && mapping == .mapped { state = .relocalized; return state }
        return tick()
    }

    /// Call periodically (about 1 Hz) so the timeout fires even when no tracking updates arrive.
    @discardableResult
    public func tick() -> RelocalizationState {
        guard let t0 = startedAt else { return state }
        if state == .relocalized { return state }
        let elapsed = max(0, clock.now() - t0)
        state = elapsed >= timeout ? .rescanNeeded : .waiting(elapsed: elapsed)
        return state
    }

    /// The user chose "fresh Teach": drop the wait and stop watching.
    public func startFreshTeach() { startedAt = nil; state = .idle }
}
