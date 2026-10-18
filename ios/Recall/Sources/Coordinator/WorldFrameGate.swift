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
    /// True for a stored target recorded before the active map existed (e.g. waypoints from an older map, when this
    /// map was saved from a fresh scan). Relocalizing against this map says nothing about such a target's frame.
    func predatesActiveMap(createdAt isoTimestamp: String) -> Bool
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

    func predatesActiveMap(createdAt isoTimestamp: String) -> Bool { false }
}

/// Test and legacy default: every stored position is trusted. The app wiring always supplies `WorldFrameGate`.
final class TrustedFrame: CoordinatorFrameValidity {
    var relocalized: Bool { true }
    func isInCurrentFrame(createdAt isoTimestamp: String) -> Bool { true }
}

/// What `WorldFrameGate.adoptSavedMap` did, so the caller can carry stored data over to the new map id.
struct MapAdoption: Equatable {
    /// Map id the session used before (a "fresh-" id when it had no saved map).
    let previousMapId: String
    /// True when the session was already relocalized against `previousMapId`: the new map shares its frame.
    let wasRelocalized: Bool
    /// Stored targets created before this instant are not in the new map's frame (nil: all are). Persist it with the map.
    let waypointCutoff: Date?
}

/// Thread-safe. Main thread feeds it (`sessionStarted`, `update`); the coordinator reads it from any thread.
/// A new ARKit run (launch, resume, "fresh Teach" reset) is a new frame and invalidates everything until the
/// saved map is recognised again. Uses Teach's `RelocalizationMonitor` rule: a limited -> normal transition after a
/// run with the saved map. Saving a map in Teach adopts the running session as that map (`adoptSavedMap`).
final class WorldFrameGate: CoordinatorFrameValidity {
    /// Recursive so `performIfCurrent`'s body may read the gate (and a TrackStore scope closure may ask `activeMapId`).
    private let lock = NSRecursiveLock()
    private let monitor: RelocalizationMonitor
    private let now: () -> Date
    private var frameStart: Date
    private var latched = false
    private var gen = 0
    private var mapId = "fresh-" + UUID().uuidString
    /// True while `mapId` names a saved map (loaded at session start, or adopted after Save map).
    private var realMap = false
    private var waypointCutoff: Date?

    init(now: @escaping () -> Date = { Date() }, monitor: RelocalizationMonitor = RelocalizationMonitor()) {
        self.now = now; self.monitor = monitor; self.frameStart = now()
    }

    /// ARKit session (re)started. `loadedSavedMap` is false when there was no usable map to relocalize against
    /// (none saved, corrupt, or a reset), so persisted targets stay refused for the whole session.
    /// `mapId` identifies the loaded archive (`WorldMapStore.currentMapId`). Without a loaded map (or without an id)
    /// the session gets a fresh id, so it never sees, and never writes next to, tracks of an earlier map.
    /// `waypointCutoff` is the loaded map's stored cutoff (`WorldMapStore.waypointCutoff(mapId:)`).
    func sessionStarted(loadedSavedMap: Bool, mapId: String? = nil, waypointCutoff: Date? = nil) {
        lock.lock(); defer { lock.unlock() }
        let id = loadedSavedMap ? mapId : nil
        self.mapId = id ?? "fresh-" + UUID().uuidString
        realMap = id != nil
        self.waypointCutoff = id != nil ? waypointCutoff : nil
        frameStart = now()
        latched = false
        gen += 1
        monitor.start(hasSavedMap: loadedSavedMap)
    }

    /// Feed every tracking/mapping change. `relocalizing` is true for `limited(.relocalizing)`.
    /// Losing tracking entirely drops the recognition (ARKit may re-anchor) until ARKit relocalizes again.
    func update(tracking: TrackingKind, mapping: MappingKind, relocalizing: Bool = false) {
        lock.lock(); defer { lock.unlock() }
        if tracking == .notAvailable {
            if latched { gen += 1; latched = false; monitor.rearmAfterLoss() } else { monitor.trackingLost() }
            return
        }
        if monitor.update(tracking: tracking, mapping: mapping, relocalizing: relocalizing) == .relocalized { latched = true }
    }

    /// Teach saved the running session's world map as `mapId`. `getCurrentWorldMap` snapshots this session, so its
    /// frame IS the saved map's frame: adopt it now instead of waiting for a relaunch. `ifGeneration` is the
    /// generation read before the save started; if the frame changed meanwhile (new run, tracking lost) nothing is
    /// adopted and nil is returned (the map is used from the next launch). The frame start is unchanged, so targets
    /// marked earlier in this session stay valid; the generation moves so in-flight ingests of the old id are dropped.
    @discardableResult
    func adoptSavedMap(mapId newId: String, ifGeneration g: Int?) -> MapAdoption? {
        lock.lock(); defer { lock.unlock() }
        guard g == nil || g == gen else { return nil }
        let result = MapAdoption(previousMapId: mapId, wasRelocalized: latched,
                                 waypointCutoff: latched ? waypointCutoff : frameStart)
        mapId = newId
        realMap = true
        waypointCutoff = result.waypointCutoff
        latched = true
        gen += 1
        monitor.startFreshTeach()   // nothing to wait for; a later tracking loss re-arms it
        return result
    }

    var relocalized: Bool { lock.lock(); defer { lock.unlock() }; return latched }
    var generation: Int { lock.lock(); defer { lock.unlock() }; return gen }
    /// True while the session uses a saved map (loaded or adopted), even before it is recognised.
    var usesSavedMap: Bool { lock.lock(); defer { lock.unlock() }; return realMap }

    /// For the Teach banner: recognised, waiting (with elapsed time), rescan needed, or idle (no saved map in use).
    func relocalizationState() -> RelocalizationState {
        lock.lock(); defer { lock.unlock() }
        if latched { return .relocalized }
        let s = monitor.tick()
        return s == .relocalized ? .waiting(elapsed: 0) : s
    }

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

    func predatesActiveMap(createdAt isoTimestamp: String) -> Bool {
        lock.lock(); let cutoff = waypointCutoff; lock.unlock()
        guard let cutoff else { return false }
        guard let created = ISO8601DateFormatter().date(from: isoTimestamp) else { return true }
        return !(created.addingTimeInterval(1) > cutoff)
    }
}
