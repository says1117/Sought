import Foundation

/// What the uploader should mirror to the backend right now.
public struct UploadSnapshot: Equatable {
    /// Map the objects belong to. nil = no relocalized map right now: no objects, and what was sent is remembered.
    /// Defaults to "default" (TrackStore's map id when no scope is given) so tests can pass objects alone.
    public var mapId: String?
    public var objects: [WireObjectTrack]
    public var waypoints: [WireWaypoint]
    /// Latest occupancy snapshot, or nil when the app has no grid (it does not build one yet).
    public var map: WireMapSnapshot?
    /// Thumbnails (contract 2.8) referenced by `media_id` in the bodies above; posted before those bodies.
    public var media: [UploadMedia]
    public init(mapId: String? = "default", objects: [WireObjectTrack] = [], waypoints: [WireWaypoint] = [],
                map: WireMapSnapshot? = nil, media: [UploadMedia] = []) {
        self.mapId = mapId; self.objects = objects; self.waypoints = waypoints; self.map = map; self.media = media
    }
}

public struct UploadMedia: Equatable {
    public var id: String, jpegPath: String
    public init(id: String, jpegPath: String) { self.id = id; self.jpegPath = jpegPath }
}

/// Short per-object sighting history for the `history` field: a point is added when an object is first uploaded
/// and whenever it has moved more than `minMoveM` since the last point, keeping the newest `maxPoints`.
/// Kept in memory only, so it restarts from one point after an app launch.
struct SightingHistory {
    static let minMoveM = 0.25, maxPoints = 10
    private var byId: [String: [WireSighting]] = [:]

    mutating func apply(_ o: WireObjectTrack) -> [WireSighting] {
        var h = byId[o.id] ?? []
        if let last = h.last {
            if hypot(last.x - o.position.x, last.z - o.position.z) > Self.minMoveM {
                h.append(WireSighting(t: o.lastSeen, x: o.position.x, z: o.position.z))
            }
        } else {
            h = [WireSighting(t: o.lastSeen, x: o.position.x, z: o.position.z)]
        }
        if h.count > Self.maxPoints { h.removeFirst(h.count - Self.maxPoints) }
        byId[o.id] = h
        return h
    }
}

/// Decides when an object track is worth a PUT. A constantly seen track changes `last_seen`, `sightings` and
/// `persistence` on every perception pass; sending each of those made the backend take a PUT per track per tick.
/// Sent right away: a new track, a move of more than `moveM` (x, y or z), a new label, label source, description or
/// media id, a different map id, or a track that comes back after leaving the active list. Otherwise a changed body
/// is sent at most once per `refreshS`, so the server's `last_seen` lags by at most that much.
/// In memory only: after an app launch every track is sent once (that also refills a backend that was reset).
struct ObjectChangeGate {
    static let moveM = 0.05, refreshS = 30.0
    private struct Sent { var o: WireObjectTrack, mapId: String, body: Data, at: Double }
    private var byId: [String: Sent] = [:]

    func shouldSend(_ o: WireObjectTrack, body: Data, mapId: String, now: Double) -> Bool {
        guard let p = byId[o.id] else { return true }
        if p.body == body && p.mapId == mapId { return false }
        let a = p.o.position, b = o.position
        let moved = ((a.x - b.x) * (a.x - b.x) + (a.y - b.y) * (a.y - b.y) + (a.z - b.z) * (a.z - b.z)).squareRoot()
        if moved > Self.moveM || p.mapId != mapId || p.o.label != o.label || p.o.labelSource != o.labelSource
            || p.o.description != o.description || p.o.mediaId != o.mediaId { return true }
        return now - p.at >= Self.refreshS
    }
    mutating func sent(_ o: WireObjectTrack, body: Data, mapId: String, now: Double) {
        byId[o.id] = Sent(o: o, mapId: mapId, body: body, at: now)
    }
    /// Forget tracks of `mapId` that are no longer listed (deactivated or purged), so a return counts as a change.
    mutating func keepOnly(_ ids: Set<String>, of mapId: String) {
        byId = byId.filter { $0.value.mapId != mapId || ids.contains($0.key) }
    }
}

/// T-071: mirrors remembered objects, waypoints and (when there is one) the map snapshot to the backend.
///
/// Every `interval` seconds, off the robot's threads: read a snapshot, put each body that changed since the last
/// tick into the durable `SyncQueue` (one pending row per resource, latest wins; objects only on a real change, see
/// `ObjectChangeGate`), then let `SyncSender` drain what is
/// due (backoff on network errors and 5xx, pause on 401, drop on other 4xx). Nothing here is awaited by driving or
/// perception, and at most one tick runs at a time. Only built when a backend is configured.
public final class BackendUploader {
    public static let interval: TimeInterval = 5
    private let queue: SyncQueue
    private let sender: SyncSender
    private let snapshot: () -> UploadSnapshot
    private let clock: () -> Double
    private let lock = NSLock()
    private var running = false
    private var lastQueued: [String: Data] = [:]      // resource key -> body last put in the queue (not objects)
    private var objectGate = ObjectChangeGate()
    private var history = SightingHistory()
    private var task: Task<Void, Never>?
    public private(set) var queuedTotal = 0

    public init(queue: SyncQueue, sender: SyncSender, clock: @escaping () -> Double = { Date().timeIntervalSince1970 },
                snapshot: @escaping () -> UploadSnapshot) {
        self.queue = queue; self.sender = sender; self.clock = clock; self.snapshot = snapshot
    }

    /// The app's wiring: read `databasePath` (shared with WaypointStore/TrackStore) read-only, queue in its own file,
    /// and upload tracks of `mapId()` only (nil = no relocalized map right now, so no objects). nil if the queue can't
    /// open.
    public static func make(config: SyncConfig, databasePath: String, queuePath: String,
                            mapId: @escaping () -> String?) -> BackendUploader? {
        guard let q = try? SyncQueue(path: queuePath) else { return nil }
        let sender = SyncSender(queue: q, transport: URLSessionTransport(config: config))
        var reader: LocalStoreReader?
        return BackendUploader(queue: q, sender: sender) {
            if reader == nil { reader = LocalStoreReader(path: databasePath) }   // the stores may create the file later
            guard let r = reader else { return UploadSnapshot(mapId: nil) }
            let id = mapId()
            return UploadSnapshot(mapId: id, objects: id.map(r.objects(mapId:)) ?? [], waypoints: r.waypoints())
        }
    }

    public func start() {
        guard task == nil else { return }
        task = Task.detached(priority: .utility) { [weak self] in
            while !Task.isCancelled {
                await self?.tick()
                try? await Task.sleep(nanoseconds: UInt64(BackendUploader.interval * 1_000_000_000))
            }
        }
    }
    public func stop() { task?.cancel(); task = nil }

    /// One pass: queue what changed, then drain. Returns rows delivered (0 if another tick is running).
    @discardableResult
    public func tick() async -> Int {
        lock.lock()
        if running { lock.unlock(); return 0 }
        running = true; lock.unlock()
        defer { lock.lock(); running = false; lock.unlock() }
        enqueueChanges(snapshot())
        return await sender.drain()
    }

    /// Puts every changed resource in the queue. Media first, so a thumbnail is on the server before the body
    /// naming it (the queue drains oldest first). Returns how many rows were queued.
    @discardableResult
    func enqueueChanges(_ s: UploadSnapshot) -> Int {
        let now = clock()
        var n = 0
        func put(_ key: String, _ body: Data?, _ write: () throws -> Void) {
            guard let body, lastQueued[key] != body else { return }
            do { try write(); lastQueued[key] = body; n += 1 } catch { /* retried next tick */ }
        }
        for m in s.media {
            put("media:\(m.id)", Data(m.jpegPath.utf8)) { try queue.enqueueMedia(id: m.id, jpegPath: m.jpegPath, now: now) }
        }
        for w in s.waypoints {
            put("waypoint:\(w.id)", try? SyncJSON.encode(w)) { try queue.enqueue(w, now: now) }
        }
        if let mapId = s.mapId {
            for var o in s.objects {
                o.history = history.apply(o)
                guard let body = try? SyncJSON.encode(o), objectGate.shouldSend(o, body: body, mapId: mapId, now: now) else { continue }
                do { try queue.enqueue(o, now: now); objectGate.sent(o, body: body, mapId: mapId, now: now); n += 1 } catch { /* next tick */ }
            }
            objectGate.keepOnly(Set(s.objects.map(\.id)), of: mapId)
        }
        if let m = s.map {
            var same = m; same.updatedAt = ""                   // a new timestamp alone is not a change
            put("map", try? SyncJSON.encode(same)) { try queue.enqueue(m, now: now) }
        }
        queuedTotal += n
        return n
    }
}
