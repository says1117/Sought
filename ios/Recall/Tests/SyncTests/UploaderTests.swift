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
               first: String? = "2026-10-17T13:05:00Z", persistence: Double = 0.86, active: Int = 1) {
        let m = map.map { "'\($0)'" } ?? "NULL", f = first.map { "'\($0)'" } ?? "NULL"
        exec("""
        INSERT OR REPLACE INTO tracks (id,label,label_source,description,x,y,z,height_above_floor,embedding,embedding_dim,first_seen,last_seen,sightings,persistence,media_id,active,map_id)
        VALUES ('\(id)',NULL,'none',NULL,\(x),0.1,\(z),0.05,x'0000',1,\(f),'\(last)',7,\(persistence),NULL,\(active),\(m))
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
        snap.value.objects = [object("obj_aaaaaaaaaa", last: "2026-10-17T14:05:00Z")]   // seen again
        let third = await u.tick()
        XCTAssertEqual(third, 1)
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
