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
    /// 20 s passed without recognising the map. UI shows "Rescan needed".
    case rescanNeeded
}

/// Decides when a loaded world map has been recognized. Pure: feed it tracking updates and clock ticks.
/// With `initialWorldMap`, ARKit holds tracking at `limited(.relocalizing)` until it recognises the map, then reports
/// `.normal` (documented). So recognition is a limited -> normal transition after the run started; `worldMappingStatus`
/// is not required (it can sit at extending/limited for a long time). A `.normal` with no limited state seen first is
/// ignored: it can be a stale frame of the previous run. After tracking was lost (interruption), only a transition
/// through `limited(.relocalizing)` counts, because without relocalization ARKit may restart in a new frame.
/// After 20 s show "Rescan needed".
public final class RelocalizationMonitor {
    public static let timeout: Double = 20

    public private(set) var state: RelocalizationState = .idle
    private let clock: RelocClock
    private let timeout: Double
    private var startedAt: Double?
    /// A limited state (any reason, or only `.relocalizing` when `needRelocalizingReason`) was seen since (re)arming.
    private var sawLimited = false
    private var needRelocalizingReason = false

    public init(clock: RelocClock = SystemRelocClock(), timeout: Double = RelocalizationMonitor.timeout) {
        self.clock = clock
        self.timeout = timeout
    }

    /// Call when the session starts with a loaded map. Without a map there is nothing to wait for.
    public func start(hasSavedMap: Bool) {
        guard hasSavedMap else { startedAt = nil; state = .idle; return }
        startedAt = clock.now()
        state = .waiting(elapsed: 0)
        sawLimited = false
        needRelocalizingReason = false
    }

    /// Feed each tracking update. `relocalizing` is true for `limited(.relocalizing)`. `mapping` is shown in the UI
    /// but does not decide recognition. A late success after the timeout still recovers.
    @discardableResult
    public func update(tracking: TrackingKind, mapping: MappingKind, relocalizing: Bool = false) -> RelocalizationState {
        guard startedAt != nil else { return state }
        if state == .relocalized { return state }
        if tracking == .limited && (relocalizing || !needRelocalizingReason) { sawLimited = true }
        if tracking == .normal && sawLimited { state = .relocalized; return state }
        return tick()
    }

    /// Tracking became unavailable while still waiting. From now on only `limited(.relocalizing)` -> `.normal` counts.
    /// The startup `.notAvailable` (before any limited state) changes nothing.
    public func trackingLost() {
        guard startedAt != nil, state != .relocalized else { return }
        if sawLimited { needRelocalizingReason = true }
        sawLimited = false
    }

    /// Tracking was lost after the map had been recognised (or adopted): wait again, from now, for ARKit to
    /// relocalize (`limited(.relocalizing)` -> `.normal`).
    public func rearmAfterLoss() {
        startedAt = clock.now()
        state = .waiting(elapsed: 0)
        sawLimited = false
        needRelocalizingReason = true
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
    public func startFreshTeach() { startedAt = nil; state = .idle; sawLimited = false; needRelocalizingReason = false }
}
