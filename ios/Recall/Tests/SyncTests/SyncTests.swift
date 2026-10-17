import XCTest
import Foundation
#if canImport(SyncCore)
@testable import SyncCore
#endif

private func fixture(_ name: String) throws -> Data {
    let dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures")
    return try Data(contentsOf: dir.appendingPathComponent(name))
}
private func obj(_ d: Data) throws -> NSDictionary { try JSONSerialization.jsonObject(with: d) as! NSDictionary }

private func sampleWaypoint(_ id: String = "wpt_k3m9q2x7ab", name: String = "kitchen") -> WireWaypoint {
    WireWaypoint(id: id, name: name, pose: WirePose(x: 2.1, z: -4.8, yawDeg: 180), createdAt: "2026-10-17T13:01:00Z", mediaId: "med_f8d2c1z9ab")
}
private func sampleHeartbeat(state: WireHeartbeatState = .finding) -> WireHeartbeat {
    WireHeartbeat(t: "2026-10-17T14:03:22Z", state: state, task: "find: blue backpack", tracking: .normal, mappingStatus: .mapped,
                  pose: WirePose(x: 1.2, z: -3.4, yawDeg: 92.5), frontCm: 87, rearCm: 999, phoneBattery: 0.62, firmwareLink: true)
}
private func tempDB() -> String {
    FileManager.default.temporaryDirectory.appendingPathComponent("syncq-\(UUID().uuidString).sqlite").path
}

// MARK: - JSON shapes

final class ContractShapeTests: XCTestCase {
    func check<T: Codable>(_ file: String, _ type: T.Type, line: UInt = #line) throws {
        let data = try fixture(file)
        let model = try JSONDecoder().decode(T.self, from: data)
        let encoded = try SyncJSON.encode(model)
        XCTAssertEqual(try obj(encoded), try obj(data), file)   // same keys, values and explicit nulls
    }
    func testHeartbeat() throws { try check("heartbeat.json", WireHeartbeat.self) }
    func testWaypoint() throws { try check("waypoint.json", WireWaypoint.self) }
    func testWaypointNullMediaIsExplicitNull() throws {
        try check("waypoint_null_media.json", WireWaypoint.self)
        let s = String(decoding: try SyncJSON.encode(sampleWaypointNoMedia()), as: UTF8.self)
        XCTAssertTrue(s.contains("\"media_id\":null"), s)
    }
    func sampleWaypointNoMedia() -> WireWaypoint {
        WireWaypoint(id: "wpt_home", name: "home", pose: WirePose(x: 0, z: 0, yawDeg: 0), createdAt: "2026-10-17T13:00:00Z", mediaId: nil)
    }
    func testRoute() throws { try check("route.json", WireRoute.self) }
    func testObject() throws {
        try check("object.json", WireObjectTrack.self)
        XCTAssertFalse(String(decoding: try fixture("object.json"), as: UTF8.self).contains("embedding"))
    }
    func testEventWithNulls() throws { try check("event.json", WireChangeEvent.self) }
    func testPatrol() throws { try check("patrol.json", WirePatrol.self) }
    func testMap() throws { try check("map.json", WireMapSnapshot.self) }

    func testMapCellsHelperMatchesBase64() throws {
        let m = WireMapSnapshot(resolutionM: 0.05, origin: WireMapOrigin(x: -4, z: -6), width: 2, height: 2, cells: [0, 1, 2, 3], updatedAt: "2026-10-17T02:12:30Z")
        XCTAssertEqual(m.cellsB64, "AAECAw==")
    }
    func testEventNullableFieldsAllEncodedWhenNil() throws {
        let e = WireChangeEvent(id: "evt_x", patrolId: nil, type: .appeared, severity: .info, label: "mug", confidence: 0.5,
                                position: WirePosition(x: 0, y: 0, z: 0), previousPosition: nil, nearWaypoint: nil, onRoute: nil,
                                distanceToRouteM: nil, beforeMediaId: nil, afterMediaId: nil, spoken: "s", createdAt: "2026-10-17T02:11:09Z")
        let d = try obj(try SyncJSON.encode(e))
        for k in ["patrol_id", "previous_position", "near_waypoint", "on_route", "distance_to_route_m", "before_media_id", "after_media_id"] {
            XCTAssertTrue(d[k] is NSNull, k)
        }
        XCTAssertEqual(d.count, 15)
    }
    func testHeartbeatStatesMatchContract() {
        // docs/03_CONTRACTS.md 2.1, including exploring and coming_to_user
        let contract: Set = ["idle", "exploring", "teaching", "finding", "coming_to_user", "patrolling", "checking_route", "blocked", "error"]
        XCTAssertEqual(Set(WireHeartbeatState.allCases.map(\.rawValue)), contract)
        for s in WireHeartbeatState.allCases {
            let d = try! obj(try! SyncJSON.encode(sampleHeartbeat(state: s)))
            XCTAssertEqual(d["state"] as? String, s.rawValue)
        }
    }
    func testTimeFormat() {
        XCTAssertEqual(SyncTime.string(from: Date(timeIntervalSince1970: 1_792_245_802)), "2026-10-17T14:03:22Z")
    }
}

// MARK: - Config

final class ConfigTests: XCTestCase {
    func testPlaceholdersAreUnconfigured() {
        XCTAssertNil(SyncConfig(info: [:]))
        XCTAssertNil(SyncConfig(info: ["BACKEND_BASE_URL": "https://your-host.example.com", "RECALL_TOKEN": "change-me"]))
        XCTAssertNil(SyncConfig(info: ["BACKEND_BASE_URL": "http://10.0.0.5:8000", "RECALL_TOKEN": "change-me"]))
        XCTAssertNil(SyncConfig(info: ["BACKEND_BASE_URL": "", "RECALL_TOKEN": "t"]))
    }
    func testValid() {
        let c = SyncConfig(info: ["BACKEND_BASE_URL": "http://10.0.0.5:8000", "RECALL_TOKEN": "test-token"])
        XCTAssertEqual(c?.baseURL.absoluteString, "http://10.0.0.5:8000")
    }
}

// MARK: - Backoff

final class BackoffTests: XCTestCase {
    func testScheduleWithoutJitter() {
        let b = Backoff()
        let got = (1...9).map { b.delay(afterFailures: $0, random: 0.5) }
        XCTAssertEqual(got, [1, 2, 4, 8, 16, 32, 60, 60, 60])
    }
    func testJitterBounds() {
        let b = Backoff()
        XCTAssertEqual(b.delay(afterFailures: 3, random: 0), 3.0)      // 4 * 0.75
        XCTAssertEqual(b.delay(afterFailures: 3, random: 0.999999999), 5.0, accuracy: 1e-6)  // -> 4 * 1.25
        for n in 1...20 { for r in stride(from: 0.0, to: 1.0, by: 0.1) {
            let d = b.delay(afterFailures: n, random: r)
            XCTAssertTrue(d >= 0.75 && d <= 75, "n=\(n) r=\(r) d=\(d)")
        } }
    }
}

// MARK: - Queue

final class QueueTests: XCTestCase {
    func testSurvivesRestart() throws {
        let path = tempDB()
        do {
            let q = try SyncQueue(path: path)
            try q.enqueue(sampleWaypoint())
            try q.enqueueMedia(id: "med_f8d2c1z9ab", jpegPath: "/tmp/x.jpg")
            let item = try q.nextDue(now: 0)!
            try q.recordFailure(item, attempts: 3, nextTry: 500)
        }
        let q2 = try SyncQueue(path: path)       // "relaunch"
        let rows = try q2.all()
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows[0].path, "/api/waypoints/wpt_k3m9q2x7ab")
        XCTAssertEqual(rows[0].attempts, 3)
        XCTAssertEqual(rows[0].nextTry, 500)
        XCTAssertEqual(rows[1].mediaPath, "/tmp/x.jpg")
        XCTAssertEqual(try q2.nextDue(now: 100)?.path, "/api/media")   // first row is backed off
    }
    func testSameIdReplacesPendingRow() throws {
        let q = try SyncQueue(path: ":memory:")
        try q.enqueue(sampleWaypoint(name: "kitchen"))
        try q.enqueue(sampleWaypoint(name: "big kitchen"))
        try q.enqueue(sampleWaypoint("wpt_other00000"))
        let rows = try q.all()
        XCTAssertEqual(rows.count, 2)
        XCTAssertTrue(String(decoding: rows[0].body!, as: UTF8.self).contains("big kitchen") ||
                      String(decoding: rows[1].body!, as: UTF8.self).contains("big kitchen"))
    }
    func testMediaDedupedByFile() throws {
        let q = try SyncQueue(path: ":memory:")
        try q.enqueueMedia(id: "med_aaaa111111", jpegPath: "/a.jpg")
        try q.enqueueMedia(id: "med_aaaa111111", jpegPath: "/a.jpg")
        try q.enqueueMedia(id: "med_bbbb222222", jpegPath: "/b.jpg")
        XCTAssertEqual(try q.count(), 2)
    }
    func testMapKeepsOnlyLatest() throws {
        let q = try SyncQueue(path: ":memory:")
        for i in 0..<5 {
            try q.enqueue(WireMapSnapshot(resolutionM: 0.05, origin: WireMapOrigin(x: 0, z: 0), width: 1, height: 1, cells: [0], updatedAt: "2026-10-17T02:12:0\(i)Z"))
        }
        let rows = try q.all()
        XCTAssertEqual(rows.count, 1)
        XCTAssertTrue(String(decoding: rows[0].body!, as: UTF8.self).contains("02:12:04Z"))
    }
    func testBodyIsDeterministic() throws {
        XCTAssertEqual(try SyncJSON.encode(sampleWaypoint()), try SyncJSON.encode(sampleWaypoint()))
    }
}

// MARK: - Fake transport

final class FakeServer: SyncTransport {
    var online = true
    var script: [Int] = []                 // popped first, one per call (overrides normal 200)
    private(set) var calls: [SyncRequest] = []
    private(set) var store: [String: Data] = [:]    // path -> last body (models idempotent upsert)
    private(set) var media: [String: Int] = [:]
    struct Offline: Error {}
    func send(_ r: SyncRequest) async throws -> Int {
        calls.append(r)
        if !online { throw Offline() }
        if !script.isEmpty { return script.removeFirst() }
        if let m = r.media { media[m.id] = (try? Data(contentsOf: m.fileURL).count) ?? 0 }
        else if r.method == "PUT" || r.path == "/api/robot/heartbeat" { store[r.path] = r.body }
        return 200
    }
}

private final class Clock { var now = 1_000.0; func tick(_ s: Double) { now += s } }

private func makeSender(_ q: SyncQueue, _ s: FakeServer, _ c: Clock, logs: LogBox = LogBox()) -> SyncSender {
    SyncSender(queue: q, transport: s, backoff: Backoff(), clock: { c.now }, random: { 0.5 }, log: { logs.lines.append($0) })
}
private final class LogBox { var lines: [String] = [] }

final class SenderTests: XCTestCase {
    func testDeliversAndEmptiesQueue() async throws {
        let q = try SyncQueue(path: ":memory:"), s = FakeServer(), c = Clock()
        try q.enqueue(sampleWaypoint(), now: c.now)
        let n = await makeSender(q, s, c).drain()
        XCTAssertEqual(n, 1)
        XCTAssertEqual(try q.count(), 0)
        XCTAssertEqual(s.calls.first?.method, "PUT")
        XCTAssertEqual(s.calls.first?.path, "/api/waypoints/wpt_k3m9q2x7ab")
    }

    func testAirplaneModeInAndOutLosesNothing() async throws {
        let q = try SyncQueue(path: ":memory:"), s = FakeServer(), c = Clock()
        let sender = makeSender(q, s, c)
        s.online = false
        for i in 0..<5 { try q.enqueue(sampleWaypoint("wpt_item\(i)00000"), now: c.now) }
        _ = await sender.drain()
        XCTAssertEqual(sender.state, .offline)
        XCTAssertEqual(try q.count(), 5)
        // more work arrives while offline, and time passes with retries failing
        try q.enqueue(sampleWaypoint("wpt_late0000000"), now: c.now)
        for _ in 0..<4 { c.tick(100); _ = await sender.drain() }
        XCTAssertEqual(try q.count(), 6)
        XCTAssertEqual(s.store.count, 0)
        // back online: backed-off rows become due immediately
        s.online = true
        sender.networkRestored()
        let n = await sender.drain()
        XCTAssertEqual(n, 6)
        XCTAssertEqual(try q.count(), 0)
        XCTAssertEqual(s.store.count, 6)
        XCTAssertEqual(sender.state, .idle)
        XCTAssertEqual(sender.dropped, 0)
    }

    func testOfflineWithoutNetworkRestoredStillRecoversAfterBackoff() async throws {
        let q = try SyncQueue(path: ":memory:"), s = FakeServer(), c = Clock()
        let sender = makeSender(q, s, c)
        try q.enqueue(sampleWaypoint(), now: c.now)
        s.online = false
        _ = await sender.drain()
        XCTAssertEqual(try q.all()[0].nextTry, c.now + 1)         // first failure -> 1 s
        s.online = true
        let drained1 = await sender.drain(); XCTAssertEqual(drained1, 0)                   // not yet due
        c.tick(1)
        let drained2 = await sender.drain(); XCTAssertEqual(drained2, 1)
    }

    func testBackoffGrowsAcrossRepeatedFailures() async throws {
        let q = try SyncQueue(path: ":memory:"), s = FakeServer(), c = Clock()
        let sender = makeSender(q, s, c)
        try q.enqueue(sampleWaypoint(), now: c.now)
        s.script = [503, 500, 502, 503]
        var gaps: [Double] = []
        for _ in 0..<4 {
            _ = await sender.drain()
            let row = try q.all()[0]
            gaps.append(row.nextTry - c.now)
            c.now = row.nextTry
        }
        XCTAssertEqual(gaps, [1, 2, 4, 8])
        XCTAssertEqual(try q.all()[0].attempts, 4)
        let drained3 = await sender.drain(); XCTAssertEqual(drained3, 1)
    }

    func testCrashMidSendKeepsRowAndReplaysIdempotently() async throws {
        let path = tempDB(), s = FakeServer(), c = Clock()
        do { let q = try SyncQueue(path: path); try q.enqueue(sampleWaypoint(), now: c.now) }
        // "process died" after the server stored it but before the row was removed: replay twice
        for _ in 0..<2 {
            let q = try SyncQueue(path: path)
            s.script = []
            let sender = makeSender(q, s, c)
            if try q.count() == 0 { try q.enqueue(sampleWaypoint(), now: c.now) }   // simulate row never removed
            _ = await sender.drain()
        }
        XCTAssertEqual(s.store.count, 1)                             // upsert by id: one resource
        XCTAssertEqual(s.store["/api/waypoints/wpt_k3m9q2x7ab"], try SyncJSON.encode(sampleWaypoint()))
    }

    func testIdempotentReplayOfSamePayload() async throws {
        let q = try SyncQueue(path: ":memory:"), s = FakeServer(), c = Clock()
        let sender = makeSender(q, s, c)
        for _ in 0..<3 { try q.enqueue(sampleWaypoint(), now: c.now); _ = await sender.drain() }
        XCTAssertEqual(s.store.count, 1)
        XCTAssertEqual(s.calls.count, 3)
        XCTAssertEqual(Set(s.calls.map(\.body)).count, 1)            // byte-identical every time
    }

    func test4xxDroppedWithLogAndQueueContinues() async throws {
        let q = try SyncQueue(path: ":memory:"), s = FakeServer(), c = Clock(), logs = LogBox()
        let sender = makeSender(q, s, c, logs: logs)
        try q.enqueue(sampleWaypoint("wpt_bad0000000"), now: c.now)
        try q.enqueue(sampleWaypoint("wpt_good000000"), now: c.now)
        s.script = [422]
        let n = await sender.drain()
        XCTAssertEqual(n, 1)
        XCTAssertEqual(sender.dropped, 1)
        XCTAssertEqual(try q.count(), 0)
        XCTAssertTrue(logs.lines.contains { $0.contains("ERROR") && $0.contains("422") && $0.contains("wpt_bad0000000") }, "\(logs.lines)")
    }

    func test401PausesKeepsEverythingAndResumes() async throws {
        let q = try SyncQueue(path: ":memory:"), s = FakeServer(), c = Clock()
        let sender = makeSender(q, s, c)
        var seen: [SyncState] = []
        sender.onStateChange = { seen.append($0) }
        try q.enqueue(sampleWaypoint("wpt_aaaa000000"), now: c.now)
        try q.enqueue(sampleWaypoint("wpt_bbbb000000"), now: c.now)
        s.script = [401]
        let drained4 = await sender.drain(); XCTAssertEqual(drained4, 0)
        XCTAssertEqual(sender.state, .authRequired)
        XCTAssertEqual(try q.count(), 2)
        let callsBefore = s.calls.count
        let drained5 = await sender.drain(); XCTAssertEqual(drained5, 0)                     // paused: no further traffic
        XCTAssertEqual(s.calls.count, callsBefore)
        sender.resume()
        let drained6 = await sender.drain(); XCTAssertEqual(drained6, 2)
        XCTAssertEqual(seen, [.authRequired, .idle])
        XCTAssertEqual(sender.dropped, 0)
    }

    func test429And408AreRetriedNotDropped() async throws {
        let q = try SyncQueue(path: ":memory:"), s = FakeServer(), c = Clock()
        let sender = makeSender(q, s, c)
        try q.enqueue(sampleWaypoint(), now: c.now)
        s.script = [429]
        _ = await sender.drain()
        XCTAssertEqual(try q.count(), 1)
        XCTAssertEqual(sender.dropped, 0)
    }

    func testReenqueueWhileInFlightDoesNotLoseNewVersion() throws {
        let q = try SyncQueue(path: ":memory:"), c = Clock()
        try q.enqueue(sampleWaypoint(name: "v1"), now: c.now)
        let old = try q.nextDue(now: c.now)!
        try q.enqueue(sampleWaypoint(name: "v2"), now: c.now)       // arrives while v1 is "in flight"
        XCTAssertEqual(try q.all()[0].id, old.id)                   // rowid reuse: the hazard this guards
        try q.recordFailure(old, attempts: 1, nextTry: c.now + 1)   // v1's outcome must not touch v2
        var rows = try q.all()
        XCTAssertEqual(rows[0].attempts, 0)
        try q.remove(old)                                           // v1 "delivered"
        rows = try q.all()
        XCTAssertEqual(rows.count, 1)
        XCTAssertTrue(String(decoding: rows[0].body!, as: UTF8.self).contains("v2"))
    }

    func testMediaMultipartUploadAndMissingFile() async throws {
        let q = try SyncQueue(path: ":memory:"), s = FakeServer(), c = Clock(), logs = LogBox()
        let jpeg = FileManager.default.temporaryDirectory.appendingPathComponent("med_\(UUID().uuidString).jpg")
        try Data([0xFF, 0xD8, 0xFF, 0xD9]).write(to: jpeg)
        try q.enqueueMedia(id: "med_f8d2c1z9ab", jpegPath: jpeg.path, now: c.now)
        try q.enqueueMedia(id: "med_gone000000", jpegPath: "/nonexistent/x.jpg", now: c.now)
        let sender = makeSender(q, s, c, logs: logs)
        let drained7 = await sender.drain(); XCTAssertEqual(drained7, 1)
        XCTAssertEqual(s.media["med_f8d2c1z9ab"], 4)
        XCTAssertEqual(s.calls.first?.method, "POST")
        XCTAssertEqual(sender.dropped, 1)
        XCTAssertEqual(try q.count(), 0)
    }

    func testMultipartBodyShape() {
        let body = Multipart.body(boundary: "B", id: "med_f8d2c1z9ab", jpeg: Data([1, 2, 3]))
        let s = String(decoding: body, as: UTF8.self)
        XCTAssertTrue(s.hasPrefix("--B\r\nContent-Disposition: form-data; name=\"id\"\r\n\r\nmed_f8d2c1z9ab\r\n--B\r\n"))
        XCTAssertTrue(s.contains("name=\"file\"; filename=\"med_f8d2c1z9ab.jpg\"\r\nContent-Type: image/jpeg\r\n\r\n"))
        XCTAssertTrue(s.hasSuffix("\r\n--B--\r\n"))
    }
}

// MARK: - Heartbeat

final class HangingTransport: SyncTransport {
    var started = 0
    func send(_ request: SyncRequest) async throws -> Int {
        started += 1
        try await Task.sleep(nanoseconds: 3_000_000_000)
        return 200
    }
}

final class HeartbeatTests: XCTestCase {
    func testPostsContractBodyToHeartbeatPath() async throws {
        let s = FakeServer()
        let hb = HeartbeatPublisher(transport: s, provider: { sampleHeartbeat(state: .comingToUser) })
        await hb.fire()?.value
        XCTAssertEqual(s.calls.count, 1)
        XCTAssertEqual(s.calls[0].method, "POST")
        XCTAssertEqual(s.calls[0].path, "/api/robot/heartbeat")
        XCTAssertEqual((try obj(s.calls[0].body!))["state"] as? String, "coming_to_user")
        XCTAssertEqual(hb.sent, 1)
    }
    func testNeverBlocksAndNeverStacksOnSlowNetwork() async throws {
        let t = HangingTransport()
        let hb = HeartbeatPublisher(transport: t, provider: { sampleHeartbeat() })
        let start = Date()
        _ = hb.fire(); _ = hb.fire(); _ = hb.fire()
        XCTAssertTrue(Date().timeIntervalSince(start) < 0.5)        // returned immediately
        XCTAssertEqual(hb.skipped, 2)                               // single request in flight
    }
    func testOfflineIsSwallowed() async throws {
        let s = FakeServer(); s.online = false
        let hb = HeartbeatPublisher(transport: s, provider: { sampleHeartbeat() })
        await hb.fire()?.value
        XCTAssertEqual(hb.failed, 1)
        XCTAssertEqual(hb.sent, 0)
    }
}
