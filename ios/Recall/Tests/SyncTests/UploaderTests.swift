import XCTest
import Foundation
import SQLite3
#if canImport(SyncCore)
@testable import SyncCore
#endif

/// A database file laid out like the app's recall.sqlite: contract section 3 tables plus TrackStore's `map_id`.
private final class PhoneDB {
    let path = FileManager.default.temporaryDirectory.appendingPathComponent("phone-\(UUID().uuidString).sqlite").path
    private var db: OpaquePointer?
    init(tables: Bool = true) {
        sqlite3_open(path, &db)
        guard tables else { return }
        exec("CREATE TABLE waypoints (id TEXT PRIMARY KEY, name TEXT, x REAL, z REAL, yaw_deg REAL, media_id TEXT, created_at TEXT)")
        exec("""
        CREATE TABLE tracks (id TEXT PRIMARY KEY, label TEXT, label_source TEXT, description TEXT, x REAL, y REAL, z REAL,
          height_above_floor REAL, embedding BLOB, embedding_dim INTEGER, first_seen TEXT, last_seen TEXT, sightings INTEGER,
          persistence REAL, media_id TEXT, active INTEGER DEFAULT 1, map_id TEXT)
        """)
    }
    deinit { sqlite3_close(db); try? FileManager.default.removeItem(atPath: path) }
    func exec(_ sql: String) { XCTAssertEqual(sqlite3_exec(db, sql, nil, nil, nil), SQLITE_OK, sql) }
    func track(_ id: String, map: String?, x: Double = 0.8, z: Double = -2.9, last: String = "2026-10-17T14:02:10Z",
               first: String? = "2026-10-17T13:05:00Z", persistence: Double = 0.86, active: Int = 1, height: Double = 0.05) {
        let m = map.map { "'\($0)'" } ?? "NULL", f = first.map { "'\($0)'" } ?? "NULL"
        exec("""
        INSERT OR REPLACE INTO tracks (id,label,label_source,description,x,y,z,height_above_floor,embedding,embedding_dim,first_seen,last_seen,sightings,persistence,media_id,active,map_id)
        VALUES ('\(id)',NULL,'none',NULL,\(x),0.1,\(z),\(height),x'0000',1,\(f),'\(last)',7,\(persistence),NULL,\(active),\(m))
        """)
    }
    func waypoint(_ id: String, name: String, created: String = "2026-10-17T13:01:00Z", media: String? = nil) {
        exec("INSERT INTO waypoints VALUES ('\(id)','\(name)',2.1,-4.8,180,\(media.map { "'\($0)'" } ?? "NULL"),'\(created)')")
    }
}

final class LocalStoreReaderTests: XCTestCase {
    func testObjectsOfActiveMapOnlyInContractShape() throws {
        let db = PhoneDB()
        db.track("obj_aaaaaaaaaa", map: "map-1")
        db.track("obj_bbbbbbbbbb", map: "map-2")
        db.track("obj_cccccccccc", map: nil)                     // written before map identity: never uploads
        db.track("obj_dddddddddd", map: "map-1", active: 0)
        let r = try XCTUnwrap(LocalStoreReader(path: db.path))
        let objs = r.objects(mapId: "map-1")
        XCTAssertEqual(objs.map(\.id), ["obj_aaaaaaaaaa"])
        let o = objs[0]
        XCTAssertEqual(o.label, ""); XCTAssertEqual(o.labelSource, .none); XCTAssertEqual(o.description, "")
        XCTAssertEqual(o.position, WirePosition(x: 0.8, y: 0.1, z: -2.9))
        XCTAssertEqual(o.heightAboveFloorM, 0.05)
        XCTAssertEqual(o.firstSeen, "2026-10-17T13:05:00Z"); XCTAssertEqual(o.lastSeen, "2026-10-17T14:02:10Z")
        XCTAssertEqual(o.sightings, 7); XCTAssertEqual(o.persistence, 0.86); XCTAssertNil(o.mediaId)
        // Every contract key present, nullable media_id as explicit null, no embedding.
        let json = String(decoding: try SyncJSON.encode(o), as: UTF8.self)
        XCTAssertTrue(json.contains("\"media_id\":null"), json)
        XCTAssertFalse(json.contains("embedding"), json)
        XCTAssertEqual(r.objects(mapId: "map-2").map(\.id), ["obj_bbbbbbbbbb"])
        XCTAssertEqual(r.objects(mapId: "fresh-x"), [])
    }

    func testRowsTheBackendWouldRejectAreSkippedOrRepaired() throws {
        let db = PhoneDB()
        db.track("obj_badtimeaaa", map: "m", last: "yesterday")
        db.track("obj_nofirstaaa", map: "m", first: nil, persistence: 1.7)
        let r = try XCTUnwrap(LocalStoreReader(path: db.path))
        let objs = r.objects(mapId: "m")
        XCTAssertEqual(objs.map(\.id), ["obj_nofirstaaa"])
        XCTAssertEqual(objs[0].firstSeen, objs[0].lastSeen)     // missing first_seen falls back to last_seen
        XCTAssertEqual(objs[0].persistence, 1)                   // backend requires 0..1
    }

    func testImplausibleHeightsAreNotSentAndFloorNoiseReadsAsZero() throws {
        // Seen on the live backend: tracks lifted from one bad keyframe at height -4.7 m, y -6 m (floor at y -1.3 m).
        let db = PhoneDB()
        db.track("obj_underfloor", map: "m", height: -4.73)
        db.track("obj_justunder1", map: "m", height: -0.31)
        db.track("obj_overceilin", map: "m", height: 3.6)
        db.track("obj_floornoise", map: "m", height: -0.04)
        db.track("obj_onshelfaaa", map: "m", height: 1.2)
        let objs = try XCTUnwrap(LocalStoreReader(path: db.path)).objects(mapId: "m")
        XCTAssertEqual(objs.map(\.id), ["obj_floornoise", "obj_onshelfaaa"])
        XCTAssertEqual(objs.map(\.heightAboveFloorM), [0, 1.2])
    }

    func testWaypoints() throws {
        let db = PhoneDB()
        db.waypoint("wpt_home", name: "home", created: "2026-10-17T13:00:00Z")
        db.waypoint("wpt_k3m9q2x7ab", name: "kitchen", media: "med_f8d2c1z9ab")
        db.waypoint("wpt_badmediaaa", name: "hall", created: "2026-10-17T13:02:00Z", media: "bad id!")
        let r = try XCTUnwrap(LocalStoreReader(path: db.path))
        let w = r.waypoints()
        XCTAssertEqual(w.map(\.id), ["wpt_home", "wpt_k3m9q2x7ab", "wpt_badmediaaa"])
        XCTAssertEqual(w[1], WireWaypoint(id: "wpt_k3m9q2x7ab", name: "kitchen", pose: WirePose(x: 2.1, z: -4.8, yawDeg: 180),
                                          createdAt: "2026-10-17T13:01:00Z", mediaId: "med_f8d2c1z9ab"))
        XCTAssertNil(w[2].mediaId)
    }

    func testMissingTablesReadEmpty() throws {
        let db = PhoneDB(tables: false)
        let r = try XCTUnwrap(LocalStoreReader(path: db.path))
        XCTAssertEqual(r.waypoints(), []); XCTAssertEqual(r.objects(mapId: "m"), [])
    }
}

private func object(_ id: String, x: Double = 0.8, z: Double = -2.9, last: String = "2026-10-17T14:02:10Z") -> WireObjectTrack {
    WireObjectTrack(id: id, label: "", labelSource: .none, description: "", position: WirePosition(x: x, y: 0, z: z),
                    heightAboveFloorM: 0, firstSeen: "2026-10-17T13:05:00Z", lastSeen: last, sightings: 1,
                    persistence: 0.5, mediaId: nil, history: [])
}
private func waypoint(_ id: String, name: String) -> WireWaypoint {
    WireWaypoint(id: id, name: name, pose: WirePose(x: 1, z: 2, yawDeg: 0), createdAt: "2026-10-17T13:01:00Z", mediaId: nil)
}
private func map(_ updated: String, cells: [UInt8] = [0, 1, 2, 3]) -> WireMapSnapshot {
    WireMapSnapshot(resolutionM: 0.05, origin: WireMapOrigin(x: -1, z: -1), width: 2, height: 2, cells: cells, updatedAt: updated)
}
private final class Box<T> { var value: T; init(_ v: T) { value = v } }

final class BackendUploaderTests: XCTestCase {
    private func make(_ snap: Box<UploadSnapshot>, server: FakeServer, queue: SyncQueue) -> BackendUploader {
        let sender = SyncSender(queue: queue, transport: server, clock: { 1_000 }, random: { 0.5 }, log: { _ in })
        return BackendUploader(queue: queue, sender: sender, clock: { 1_000 }) { snap.value }
    }

    func testUploadsObjectsWaypointsAndMapToContractPaths() async throws {
        let q = try SyncQueue(path: ":memory:"), s = FakeServer()
        let snap = Box(UploadSnapshot(objects: [object("obj_aaaaaaaaaa")], waypoints: [waypoint("wpt_home", name: "home")],
                                      map: map("2026-10-17T02:12:30Z")))
        let u = make(snap, server: s, queue: q)
        let delivered = await u.tick()
        XCTAssertEqual(delivered, 3)
        XCTAssertEqual(Set(s.calls.map { "\($0.method) \($0.path)" }),
                       ["PUT /api/waypoints/wpt_home", "PUT /api/objects/obj_aaaaaaaaaa", "PUT /api/map"])
        let body = try JSONSerialization.jsonObject(with: XCTUnwrap(s.store["/api/objects/obj_aaaaaaaaaa"])) as! [String: Any]
        let history = try XCTUnwrap(body["history"] as? [[String: Any]])
        XCTAssertEqual(history.count, 1)
        XCTAssertEqual(history[0]["t"] as? String, "2026-10-17T14:02:10Z")
        XCTAssertEqual(try q.count(), 0)
    }

    func testUnchangedResourcesAreNotResent() async throws {
        let q = try SyncQueue(path: ":memory:"), s = FakeServer()
        let snap = Box(UploadSnapshot(objects: [object("obj_aaaaaaaaaa")], waypoints: [waypoint("wpt_home", name: "home")],
                                      map: map("2026-10-17T02:12:30Z")))
        let u = make(snap, server: s, queue: q)
        await u.tick()
        snap.value.map = map("2026-10-17T02:13:00Z")            // only the timestamp moved
        let again = await u.tick()
        XCTAssertEqual(again, 0)
        XCTAssertEqual(s.calls.count, 3)
        snap.value.objects = [object("obj_aaaaaaaaaa", last: "2026-10-17T14:05:00Z")]   // seen again: waits for the refresh
        let third = await u.tick()
        XCTAssertEqual(third, 0)
        snap.value.objects = [object("obj_aaaaaaaaaa", x: 1.5, last: "2026-10-17T14:05:00Z")]   // moved: sent now
        let fourth = await u.tick()
        XCTAssertEqual(fourth, 1)
        XCTAssertEqual(s.calls.last?.path, "/api/objects/obj_aaaaaaaaaa")
    }

    func testHistoryGrowsOnlyWhenTheObjectMoves() throws {
        var h = SightingHistory()
        XCTAssertEqual(h.apply(object("o", x: 0, z: 0, last: "2026-10-17T14:00:00Z")).count, 1)
        XCTAssertEqual(h.apply(object("o", x: 0.1, z: 0, last: "2026-10-17T14:01:00Z")).count, 1)   // jitter
        let moved = h.apply(object("o", x: 2, z: 0, last: "2026-10-17T14:02:00Z"))
        XCTAssertEqual(moved.map(\.t), ["2026-10-17T14:00:00Z", "2026-10-17T14:02:00Z"])
        for i in 0..<20 { _ = h.apply(object("o", x: Double(i) + 3, z: 0)) }
        XCTAssertEqual(h.apply(object("o", x: 100, z: 0)).count, SightingHistory.maxPoints)
    }

    func testOfflineKeepsLatestBodyQueuedAndDeliversLater() async throws {
        let q = try SyncQueue(path: ":memory:"), s = FakeServer()
        s.online = false
        let snap = Box(UploadSnapshot(objects: [object("obj_aaaaaaaaaa")]))
        let clock = Box(1_000.0)
        let sender = SyncSender(queue: q, transport: s, clock: { clock.value }, random: { 0.5 }, log: { _ in })
        let u = BackendUploader(queue: q, sender: sender, clock: { clock.value }) { snap.value }
        let first = await u.tick()
        XCTAssertEqual(first, 0)
        snap.value.objects = [object("obj_aaaaaaaaaa", x: 3, last: "2026-10-17T14:09:00Z")]
        await u.tick()
        XCTAssertEqual(try q.count(), 1)                           // coalesced: one row per object
        s.online = true; clock.value += 120
        let delivered = await u.tick()
        XCTAssertEqual(delivered, 1)
        let body = try JSONSerialization.jsonObject(with: XCTUnwrap(s.store["/api/objects/obj_aaaaaaaaaa"])) as! [String: Any]
        XCTAssertEqual(body["last_seen"] as? String, "2026-10-17T14:09:00Z")
    }

    func testMediaIsPostedBeforeTheBodyThatNamesIt() async throws {
        let q = try SyncQueue(path: ":memory:"), s = FakeServer()
        let jpeg = FileManager.default.temporaryDirectory.appendingPathComponent("med_thumb12345.jpg")
        try Data([0xFF, 0xD8, 0xFF, 0xD9]).write(to: jpeg)
        defer { try? FileManager.default.removeItem(at: jpeg) }
        var o = object("obj_aaaaaaaaaa"); o.mediaId = "med_thumb12345"
        let snap = Box(UploadSnapshot(objects: [o], media: [UploadMedia(id: "med_thumb12345", jpegPath: jpeg.path)]))
        let u = make(snap, server: s, queue: q)
        await u.tick()
        XCTAssertEqual(s.calls.map(\.path), ["/api/media", "/api/objects/obj_aaaaaaaaaa"])
        XCTAssertEqual(s.media["med_thumb12345"], 4)
        await u.tick()
        XCTAssertEqual(s.calls.count, 2)                           // the thumbnail is not re-sent
    }

    func testMakeReadsTheSharedDatabaseForTheActiveMapOnly() async throws {
        let db = PhoneDB()
        db.track("obj_aaaaaaaaaa", map: "map-1"); db.track("obj_bbbbbbbbbb", map: "map-2")
        db.waypoint("wpt_home", name: "home")
        let cfg = SyncConfig(baseURL: URL(string: "http://127.0.0.1:9")!, token: "test-token")
        let qpath = FileManager.default.temporaryDirectory.appendingPathComponent("q-\(UUID().uuidString).sqlite").path
        defer { try? FileManager.default.removeItem(atPath: qpath) }
        let mapId = Box<String?>("map-1")
        let u = try XCTUnwrap(BackendUploader.make(config: cfg, databasePath: db.path, queuePath: qpath, mapId: { mapId.value }))
        XCTAssertEqual(u.enqueueChanges(UploadSnapshot()), 0)
        let q = try SyncQueue(path: qpath)
        // Port 9 refuses the connection, so the rows stay queued and can be inspected.
        await u.tick()
        XCTAssertEqual(Set(try q.all().map(\.path)), ["/api/waypoints/wpt_home", "/api/objects/obj_aaaaaaaaaa"])
        XCTAssertEqual(u.queuedTotal, 2)
    }
}

/// The upload storm (live backend, 2026-10-18: one track PUT 6,133 times, the rest about 10): objects go out only on
/// a real change, refresh-only changes at most every 30 s, one queue row per object, one send per row per drain pass.
final class ObjectUploadGateTests: XCTestCase {
    private func setup(_ snap: Box<UploadSnapshot>) throws -> (BackendUploader, FakeServer, SyncQueue, Box<Double>) {
        let q = try SyncQueue(path: ":memory:"), s = FakeServer(), clock = Box(1_000.0)
        let sender = SyncSender(queue: q, transport: s, clock: { clock.value }, random: { 0.5 }, log: { _ in })
        return (BackendUploader(queue: q, sender: sender, clock: { clock.value }) { snap.value }, s, q, clock)
    }
    private func seen(_ o: WireObjectTrack, at t: Double, x: Double? = nil) -> WireObjectTrack {
        var o = o
        o.lastSeen = SyncTime.string(from: Date(timeIntervalSince1970: t)); o.sightings += 1
        o.persistence = min(1, o.persistence + 0.01)
        if let x { o.position.x = x }
        return o
    }
    private func puts(_ s: FakeServer) -> Int { s.calls.filter { $0.path == "/api/objects/obj_aaaaaaaaaa" }.count }

    func testConstantlySeenTrackIsRefreshedAtMostEvery30s() async throws {
        var o = object("obj_aaaaaaaaaa")
        let snap = Box(UploadSnapshot(objects: [o]))
        let (u, s, q, clock) = try setup(snap)
        for _ in 0..<24 {                                         // two minutes of 5 s ticks, seen on every one
            o = seen(o, at: clock.value); snap.value.objects = [o]
            await u.tick(); clock.value += 5
        }
        XCTAssertEqual(puts(s), 4)                                // t = 0, 30, 60, 90 (was 24)
        XCTAssertEqual(try q.count(), 0)
        let body = try JSONSerialization.jsonObject(with: XCTUnwrap(s.store["/api/objects/obj_aaaaaaaaaa"])) as! [String: Any]
        XCTAssertEqual(body["sightings"] as? Int, 1 + 19)         // the t = 90 s version
    }

    func testRefreshOnlyChangeIsDeliveredOnceItIsDueEvenIfNotSeenAgain() async throws {
        let o = object("obj_aaaaaaaaaa")
        let snap = Box(UploadSnapshot(objects: [o]))
        let (u, s, _, clock) = try setup(snap)
        await u.tick()
        clock.value += 5; snap.value.objects = [seen(o, at: clock.value)]
        await u.tick()
        XCTAssertEqual(puts(s), 1)
        clock.value += 25; await u.tick()                         // 30 s after the first send: the newer last_seen goes
        XCTAssertEqual(puts(s), 2)
        clock.value += 5; await u.tick()
        XCTAssertEqual(puts(s), 2)
    }

    func testMeaningfulChangesAreSentImmediately() async throws {
        var o = object("obj_aaaaaaaaaa")
        let snap = Box(UploadSnapshot(mapId: "map-1", objects: [o]))
        let (u, s, _, clock) = try setup(snap)
        await u.tick()
        func step(_ change: (inout WireObjectTrack) -> Void, mapId: String = "map-1") async -> Int {
            clock.value += 5; change(&o); snap.value.mapId = mapId; snap.value.objects = [o]
            await u.tick(); return puts(s)
        }
        var n = await step { $0.position.x += 0.03 }              // jitter under 5 cm
        XCTAssertEqual(n, 1)
        n = await step { $0.position.x += 0.03 }                  // now 6 cm from what was sent
        XCTAssertEqual(n, 2)
        n = await step { $0.position.y += 0.06 }
        XCTAssertEqual(n, 3)
        n = await step { $0.label = "backpack"; $0.labelSource = .detector }
        XCTAssertEqual(n, 4)
        n = await step { $0.description = "blue backpack" }
        XCTAssertEqual(n, 5)
        n = await step { $0.mediaId = "med_thumb12345" }
        XCTAssertEqual(n, 6)
        n = await step({ _ in }, mapId: "map-2")                  // Teach saved a new map and the track moved over
        XCTAssertEqual(n, 7)
        n = await step({ _ in }, mapId: "map-2")
        XCTAssertEqual(n, 7)
    }

    func testTrackThatLeavesAndReturnsIsResentButNoMapForgetsNothing() async throws {
        let o = object("obj_aaaaaaaaaa")
        let snap = Box(UploadSnapshot(mapId: "map-1", objects: [o]))
        let (u, s, _, clock) = try setup(snap)
        await u.tick()
        snap.value = UploadSnapshot(mapId: nil); clock.value += 5; await u.tick()        // not relocalized: no objects
        snap.value = UploadSnapshot(mapId: "map-1", objects: [o]); clock.value += 5; await u.tick()
        XCTAssertEqual(puts(s), 1)                                // recognised again, nothing changed: not resent
        snap.value.objects = []; clock.value += 5; await u.tick()                       // deactivated
        snap.value.objects = [o]; clock.value += 5; await u.tick()                      // active again
        XCTAssertEqual(puts(s), 2)
    }

    func testFastChangingTrackHoldsOneQueueRowWhileOffline() async throws {
        var o = object("obj_aaaaaaaaaa")
        let snap = Box(UploadSnapshot(objects: [o, object("obj_bbbbbbbbbb")]))
        let (u, s, q, clock) = try setup(snap)
        s.online = false
        for i in 0..<50 {
            o = seen(o, at: clock.value, x: 0.8 + Double(i) * 0.1)  // moves 10 cm every tick
            snap.value.objects = [o, object("obj_bbbbbbbbbb")]
            await u.tick(); clock.value += 5
        }
        XCTAssertEqual(Set(try q.all().map(\.path)), ["/api/objects/obj_aaaaaaaaaa", "/api/objects/obj_bbbbbbbbbb"])
        s.online = true; clock.value += 120
        await u.tick()
        let body = try JSONSerialization.jsonObject(with: XCTUnwrap(s.store["/api/objects/obj_aaaaaaaaaa"])) as! [String: Any]
        XCTAssertEqual((body["position"] as? [String: Double])?["x"] ?? 0, 0.8 + 49 * 0.1, accuracy: 1e-9)
        XCTAssertEqual(try q.count(), 0)
    }
}

/// A transport that queues a newer body for the same object while each PUT is in flight, so the delivered row's
/// delete never matches what is in the queue. The old drain re-read the queue after every send and PUT forever.
private final class RequeueingServer: SyncTransport {
    let queue: SyncQueue
    var calls = 0
    init(queue: SyncQueue) { self.queue = queue }
    func send(_ r: SyncRequest) async throws -> Int {
        calls += 1
        try queue.enqueue(object("obj_aaaaaaaaaa", last: SyncTime.string(from: Date(timeIntervalSince1970: Double(calls)))))
        return 200
    }
}

final class DrainBoundTests: XCTestCase {
    func testEachRowIsSentAtMostOncePerPass() async throws {
        let q = try SyncQueue(path: ":memory:")
        try q.enqueue(object("obj_aaaaaaaaaa"))
        let s = RequeueingServer(queue: q)
        let sender = SyncSender(queue: q, transport: s, clock: { 1_000 }, random: { 0.5 }, log: { _ in })
        let delivered = await sender.drain()
        XCTAssertEqual(delivered, 1)
        XCTAssertEqual(s.calls, 1)
        XCTAssertEqual(try q.count(), 1)                          // the newer version waits for the next pass
        await sender.drain()
        XCTAssertEqual(s.calls, 2)
    }
}

/// End-to-end against a running backend. Skipped unless RECALL_SMOKE_URL and RECALL_SMOKE_TOKEN are set (use a
/// throwaway local backend and a fake token); RECALL_SMOKE_JPEG optionally names a <=320 px JPEG for the media path.
final class LiveBackendSmokeTests: XCTestCase {
    func testUploadsReachALiveBackend() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let base = env["RECALL_SMOKE_URL"].flatMap(URL.init(string:)), let token = env["RECALL_SMOKE_TOKEN"] else {
            throw XCTSkip("set RECALL_SMOKE_URL and RECALL_SMOKE_TOKEN to run")
        }
        let cfg = SyncConfig(baseURL: base, token: token)
        let db = PhoneDB()
        db.track("obj_smokemap1a", map: "map-1"); db.track("obj_smokemap2b", map: "map-2")
        db.waypoint("wpt_home", name: "home")
        let qpath = FileManager.default.temporaryDirectory.appendingPathComponent("q-\(UUID().uuidString).sqlite").path
        defer { try? FileManager.default.removeItem(atPath: qpath) }
        let u = try XCTUnwrap(BackendUploader.make(config: cfg, databasePath: db.path, queuePath: qpath, mapId: { "map-1" }))
        let delivered = await u.tick()
        XCTAssertEqual(delivered, 2)
        XCTAssertEqual(try SyncQueue(path: qpath).count(), 0)

        // Thumbnail, then an object naming it, then a map snapshot, through the same queue and sender.
        let q = try SyncQueue(path: ":memory:")
        let sender = SyncSender(queue: q, transport: URLSessionTransport(config: cfg))
        var o = object("obj_smokethumb"); o.mediaId = env["RECALL_SMOKE_JPEG"] == nil ? nil : "med_smoketest01"
        let media = env["RECALL_SMOKE_JPEG"].map { [UploadMedia(id: "med_smoketest01", jpegPath: $0)] } ?? []
        let u2 = BackendUploader(queue: q, sender: sender) { UploadSnapshot(objects: [o], map: map("2026-10-17T02:12:30Z"), media: media) }
        let d2 = await u2.tick()
        XCTAssertEqual(d2, 2 + media.count)
        XCTAssertEqual(sender.dropped, 0)

        // Which heartbeat states the backend accepts (T-029 tracks exploring / coming_to_user).
        let t = URLSessionTransport(config: cfg)
        for s in WireHeartbeatState.allCases {
            let hb = WireHeartbeat(t: SyncTime.string(from: Date()), state: s, task: "", tracking: .normal, mappingStatus: .mapped,
                                   pose: WirePose(x: 0, z: 0, yawDeg: 0), frontCm: 999, rearCm: 999, phoneBattery: 0.5, firmwareLink: true)
            let status = try await t.send(SyncRequest(method: "POST", path: "/api/robot/heartbeat", body: SyncJSON.encode(hb), media: nil))
            print("[smoke] heartbeat state \(s.rawValue): HTTP \(status)")
        }
    }
}
