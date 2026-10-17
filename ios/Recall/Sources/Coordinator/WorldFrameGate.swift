import Foundation
#if canImport(PoseCore)
import PoseCore
#endif
#if canImport(TeachCore)
import TeachCore
#endif

/// Whether stored x/z coordinates are in the coordinate frame the phone is using right now.
/// Saved waypoints and remembered objects are world-frame positions from an earlier ARKit session; they only mean
/// anything again after ARKit relocalizes against the matching saved world map. A target created in this frame
/// (its `createdAt` is not older than the frame's start) is also fine.
protocol CoordinatorFrameValidity: AnyObject {
    /// True once this session relocalized against the saved map. Persisted targets may be driven to only then.
    var relocalized: Bool { get }
    /// True for a target recorded at `isoTimestamp` inside the current frame (no relocalization needed).
    func isInCurrentFrame(createdAt isoTimestamp: String) -> Bool
}

/// Test and legacy default: every stored position is trusted. The app wiring always supplies `WorldFrameGate`.
final class TrustedFrame: CoordinatorFrameValidity {
    var relocalized: Bool { true }
    func isInCurrentFrame(createdAt isoTimestamp: String) -> Bool { true }
}

/// Thread-safe. Main thread feeds it (`sessionStarted`, `update`); the coordinator reads it from any thread.
/// A new ARKit run (launch, resume, "fresh Teach" reset) is a new frame and invalidates everything until the
/// saved map is recognised again. Uses Teach's `RelocalizationMonitor` rule: normal tracking AND mapped status.
final class WorldFrameGate: CoordinatorFrameValidity {
    private let lock = NSLock()
    private let monitor: RelocalizationMonitor
    private let now: () -> Date
    private var frameStart: Date
    private var latched = false

    init(now: @escaping () -> Date = { Date() }, monitor: RelocalizationMonitor = RelocalizationMonitor()) {
        self.now = now; self.monitor = monitor; self.frameStart = now()
    }

    /// ARKit session (re)started. `loadedSavedMap` is false when there was no usable map to relocalize against
    /// (none saved, corrupt, or a reset), so persisted targets stay refused for the whole session.
    func sessionStarted(loadedSavedMap: Bool) {
        lock.lock(); defer { lock.unlock() }
        frameStart = now()
        latched = false
        monitor.start(hasSavedMap: loadedSavedMap)
    }

    /// Feed every tracking/mapping change. Losing tracking entirely drops the recognition (ARKit may re-anchor).
    func update(tracking: TrackingKind, mapping: MappingKind) {
        lock.lock(); defer { lock.unlock() }
        if tracking == .notAvailable { latched = false; return }
        if monitor.update(tracking: tracking, mapping: mapping) == .relocalized { latched = true }
    }

    var relocalized: Bool { lock.lock(); defer { lock.unlock() }; return latched }

    func isInCurrentFrame(createdAt isoTimestamp: String) -> Bool {
        lock.lock(); let start = frameStart; lock.unlock()
        guard let created = ISO8601DateFormatter().date(from: isoTimestamp) else { return false }
        return created.addingTimeInterval(1) > start   // timestamps have 1 s resolution
    }
}
