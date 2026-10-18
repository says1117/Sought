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
    /// Changes whenever the coordinate frame may have changed (new ARKit run, tracking lost). Observations carry the
    /// generation they were captured in, so a result from an earlier frame is never written next to a later one.
    var generation: Int { get }
    /// Id of the saved world map this session is (or would be) relocalized against. Stored tracks belong to one map id
    /// and are only visible while it equals this. A session with no usable saved map has a fresh id nothing stored uses.
    var activeMapId: String? { get }
    /// Runs `body` (with the active map id) only if the frame is relocalized and still the one captured as `generation`
    /// (nil = whichever is current now), and returns nil otherwise. `WorldFrameGate` holds its lock across `body`, so a
    /// reset or new session cannot land between the check and the writes. The default is a plain check-then-run for
    /// simple conformers; callers still re-check with `isCurrent` just before committing.
    func performIfCurrent<T>(generation: Int?, _ body: (_ mapId: String) throws -> T) rethrows -> T?
    /// True when `mapId` is still the active map, relocalized, and the generation matches.
    func isCurrent(mapId: String, generation: Int) -> Bool
}

extension CoordinatorFrameValidity {
    var generation: Int { 0 }
    var activeMapId: String? { TrackStore.defaultMapId }

    func performIfCurrent<T>(generation: Int?, _ body: (_ mapId: String) throws -> T) rethrows -> T? {
        guard relocalized, generation == nil || generation == self.generation, let id = activeMapId else { return nil }
        return try body(id)
    }

    func isCurrent(mapId: String, generation: Int) -> Bool {
        relocalized && activeMapId == mapId && self.generation == generation
    }
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
    /// Recursive so `performIfCurrent`'s body may read the gate (and a TrackStore scope closure may ask `activeMapId`).
    private let lock = NSRecursiveLock()
    private let monitor: RelocalizationMonitor
    private let now: () -> Date
    private var frameStart: Date
    private var latched = false
    private var gen = 0
    private var mapId = "fresh-" + UUID().uuidString

    init(now: @escaping () -> Date = { Date() }, monitor: RelocalizationMonitor = RelocalizationMonitor()) {
        self.now = now; self.monitor = monitor; self.frameStart = now()
    }

    /// ARKit session (re)started. `loadedSavedMap` is false when there was no usable map to relocalize against
    /// (none saved, corrupt, or a reset), so persisted targets stay refused for the whole session.
    /// `mapId` identifies the loaded archive (`WorldMapStore.currentMapId`). Without a loaded map (or without an id)
    /// the session gets a fresh id, so it never sees, and never writes next to, tracks of an earlier map.
    func sessionStarted(loadedSavedMap: Bool, mapId: String? = nil) {
        lock.lock(); defer { lock.unlock() }
        self.mapId = (loadedSavedMap ? mapId : nil) ?? "fresh-" + UUID().uuidString
        frameStart = now()
        latched = false
        gen += 1
        monitor.start(hasSavedMap: loadedSavedMap)
    }

    /// Feed every tracking/mapping change. Losing tracking entirely drops the recognition (ARKit may re-anchor).
    func update(tracking: TrackingKind, mapping: MappingKind) {
        lock.lock(); defer { lock.unlock() }
        if tracking == .notAvailable { if latched { gen += 1 }; latched = false; return }
        if monitor.update(tracking: tracking, mapping: mapping) == .relocalized { latched = true }
    }

    var relocalized: Bool { lock.lock(); defer { lock.unlock() }; return latched }
    var generation: Int { lock.lock(); defer { lock.unlock() }; return gen }

    var activeMapId: String? { lock.lock(); defer { lock.unlock() }; return mapId }

    func performIfCurrent<T>(generation g: Int?, _ body: (_ mapId: String) throws -> T) rethrows -> T? {
        lock.lock(); defer { lock.unlock() }
        guard latched, g == nil || g == gen else { return nil }
        return try body(mapId)
    }

    func isCurrent(mapId id: String, generation g: Int) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return latched && mapId == id && gen == g
    }

    func isInCurrentFrame(createdAt isoTimestamp: String) -> Bool {
        lock.lock(); let start = frameStart; lock.unlock()
        guard let created = ISO8601DateFormatter().date(from: isoTimestamp) else { return false }
        return created.addingTimeInterval(1) > start   // timestamps have 1 s resolution
    }
}
