import XCTest
import SQLite3
import simd
#if canImport(CoordinatorCore)
@testable import CoordinatorCore
#endif
#if canImport(Memory)
import Memory
#endif
#if canImport(PerceptionCore)
import PerceptionCore
#endif

// Findings 4 and 5 from the PR 33 review: float16 BLOBs validated against embedding_dim, and the Memory
// UpdatePlan honoured on write. Prefixed Track* because the RecallTests bundle shares one module.

final class TrackStorageTests: XCTestCase {
    private var paths: [String] = []
    override func tearDown() {
        paths.forEach { try? FileManager.default.removeItem(atPath: $0) }
        paths = []
    }

    private func tempPath() -> String {
        let p = NSTemporaryDirectory() + "track-\(UUID().uuidString).sqlite"
        paths.append(p)
        return p
    }

    /// A second connection for raw SQL: audit triggers, direct row inserts, BLOB length checks.
    private func raw(_ path: String, _ sql: String) {
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(path, &db), SQLITE_OK)
        defer { sqlite3_close(db) }
        XCTAssertEqual(sqlite3_exec(db, sql, nil, nil, nil), SQLITE_OK, String(cString: sqlite3_errmsg(db)))
    }

    private func scalar(_ path: String, _ sql: String) -> Int {
        var db: OpaquePointer?
        sqlite3_open(path, &db); defer { sqlite3_close(db) }
        var stmt: OpaquePointer?
        sqlite3_prepare_v2(db, sql, -1, &stmt, nil); defer { sqlite3_finalize(stmt) }
        return sqlite3_step(stmt) == SQLITE_ROW ? Int(sqlite3_column_int(stmt, 0)) : -1
    }

    // MARK: finding 4

    func testEmbeddingIsStoredAsFloat16AndRoundTrips() throws {
        let path = tempPath()
        let store = try TrackStore(path: path)
        let e: [Float] = [1, 0, -0.5, 0.1234]
        try store.upsert(Track(id: "obj_a", position: SIMD3(1, 2, 3), embedding: e, sightings: 2, persistence: 0.6))
        XCTAssertEqual(scalar(path, "SELECT length(embedding) FROM tracks WHERE id='obj_a'"), 8, "4 components = 8 bytes in float16")
        XCTAssertEqual(scalar(path, "SELECT embedding_dim FROM tracks WHERE id='obj_a'"), 4)
        let back = try XCTUnwrap(store.allTracks().first)
        XCTAssertEqual(back.embedding.count, 4)
        for (a, b) in zip(e, back.embedding) { XCTAssertEqual(a, b, accuracy: 1e-3) }
        XCTAssertEqual(back.position, SIMD3(1, 2, 3))
        XCTAssertEqual(store.invalidRowCount, 0)
    }

    func testHalfFloatCodecEdgeCases() {
        for v: Float in [0, -0, 1, -1, 0.5, 65504, 6.1e-5, 6e-8, 3.14159] {
            let back = EmbeddingCodec.halfFloat(EmbeddingCodec.halfBits(v))
            XCTAssertEqual(back, v, accuracy: max(abs(v) * 1e-3, 1e-7), "\(v)")
        }
        XCTAssertEqual(EmbeddingCodec.halfFloat(EmbeddingCodec.halfBits(1e9)), .infinity)
        XCTAssertTrue(EmbeddingCodec.halfFloat(EmbeddingCodec.halfBits(.nan)).isNaN)
        XCTAssertEqual(EmbeddingCodec.halfBits(1), 0x3C00)
        XCTAssertEqual(EmbeddingCodec.halfBits(-2), 0xC000)
    }

    func testBlobLengthThatDisagreesWithEmbeddingDimIsSkippedAndLogged() throws {
        let path = tempPath()
        let store = try TrackStore(path: path)
        try store.upsert(Track(id: "obj_ok", position: SIMD3(0, 0, 0), embedding: [1, 0, 0, 0]))
        // 16 bytes (a float32 4-vector) but dim 4 claims float16, and an 8-byte blob with dim 3.
        raw(path, """
        INSERT INTO tracks (id,x,y,z,embedding,embedding_dim,sightings,persistence,last_seen,active,map_id)
        VALUES ('obj_f32', 0,0,0, zeroblob(16), 4, 1, 0.3, '2026-01-01T00:00:00Z', 1, 'default'),
               ('obj_short', 0,0,0, zeroblob(8), 3, 1, 0.3, '2026-01-01T00:00:00Z', 1, 'default'),
               ('obj_nodim', 0,0,0, zeroblob(8), 0, 1, 0.3, '2026-01-01T00:00:00Z', 1, 'default')
        """)
        var logged: [String] = []
        store.onInvalidRow = { logged.append($0) }
        let ids = try store.allTracks().map(\.id)
        XCTAssertEqual(ids, ["obj_ok"])
        XCTAssertEqual(store.invalidRowCount, 3)
        XCTAssertEqual(logged.count, 3)
        XCTAssertTrue(logged.contains { $0.contains("obj_f32") && $0.contains("16 bytes") }, "\(logged)")
    }

    // MARK: finding 5

    private func obs(_ x: Float, _ e: [Float]) -> PerceivedObject {
        PerceivedObject(observation: Observation(position: SIMD3(x, 0, -2), embedding: e, confidence: 0.9, time: 5),
                        heightAboveFloor: 0.2, box: NormBox(x: 0, y: 0, w: 1, h: 1), origin: .grid, thumbnailJPEG: nil)
    }

    private func auditedStore() throws -> (TrackStore, String) {
        let path = tempPath()
        let store = try TrackStore(path: path)
        // Confirmed, well-persisted track, so an identical observation plans no rewrite.
        try store.upsert(Track(id: "obj_a", position: SIMD3(0, 0, -2), embedding: [1, 0, 0, 0], sightings: 3, persistence: 0.9),
                         height: 0.2)
        raw(path, """
        CREATE TABLE audit (col TEXT);
        CREATE TRIGGER audit_emb AFTER UPDATE OF embedding ON tracks BEGIN INSERT INTO audit VALUES ('embedding'); END;
        CREATE TRIGGER audit_pos AFTER UPDATE OF x, y, z ON tracks BEGIN INSERT INTO audit VALUES ('position'); END;
        """)
        return (store, path)
    }

    func testUnchangedConfirmedObservationCausesZeroEmbeddingOrPositionRewrites() throws {
        let (store, path) = try auditedStore()
        let ing = MemoryIngestor(store: store)
        XCTAssertEqual(try ing.ingest([obs(0, [1, 0, 0, 0])]), .init(matched: 1, created: 0))
        XCTAssertEqual(scalar(path, "SELECT count(*) FROM audit WHERE col='embedding'"), 0)
        XCTAssertEqual(scalar(path, "SELECT count(*) FROM audit WHERE col='position'"), 0)
        let t = try XCTUnwrap(store.allTracks().first)
        XCTAssertEqual(t.sightings, 4, "sightings still updated")
        XCTAssertEqual(t.lastSeen, ISO8601DateFormatter().date(from: ISO8601DateFormatter().string(from: Date()))!.timeIntervalSince1970,
                       accuracy: 5, "last_seen still updated")
        XCTAssertGreaterThan(t.persistence, 0.9, "persistence still updated")
    }

    func testPlannedRewriteStillWritesEmbeddingAndPositionOnce() throws {
        let (store, path) = try auditedStore()
        let ing = MemoryIngestor(store: store)
        // Moved 0.4 m (> movedDistance 0.15) but still a match (< matchDistance 0.5): the plan says rewrite.
        XCTAssertEqual(try ing.ingest([obs(0.4, [1, 0, 0, 0])]), .init(matched: 1, created: 0))
        XCTAssertEqual(scalar(path, "SELECT count(*) FROM audit WHERE col='embedding'"), 1)
        XCTAssertEqual(scalar(path, "SELECT count(*) FROM audit WHERE col='position'"), 1)
        XCTAssertGreaterThan(try XCTUnwrap(store.allTracks().first).position.x, 0)
    }

    // MARK: PR 39 review P1: ingestion respects the ARKit frame

    private final class TrackFrameFake: CoordinatorFrameValidity {
        var relocalized = false
        var generation = 1
        func isInCurrentFrame(createdAt isoTimestamp: String) -> Bool { false }
    }

    func testNewFrameObservationsAreRejectedAndStoreUntouched() throws {
        let (store, path) = try auditedStore()
        let frame = TrackFrameFake()                       // fresh map: not relocalized
        let ing = MemoryIngestor(store: store, frame: frame)
        XCTAssertFalse(ing.canIngest)
        let s = try ing.ingest([obs(0, [1, 0, 0, 0]), obs(5, [0, 1, 0, 0])], generation: ing.generation)
        XCTAssertTrue(s.rejected)
        XCTAssertEqual(s.matched + s.created, 0)
        XCTAssertEqual(try store.allTracks().count, 1)
        XCTAssertEqual(scalar(path, "SELECT sightings FROM tracks WHERE id='obj_a'"), 3, "old track not updated by new-frame data")
    }

    func testRelocalizedFrameObservationsAreAccepted() throws {
        let (store, _) = try auditedStore()
        let frame = TrackFrameFake(); frame.relocalized = true
        let ing = MemoryIngestor(store: store, frame: frame)
        XCTAssertTrue(ing.canIngest)
        let s = try ing.ingest([obs(0, [1, 0, 0, 0]), obs(5, [0, 1, 0, 0])], generation: ing.generation)
        XCTAssertFalse(s.rejected)
        XCTAssertEqual(s, .init(matched: 1, created: 1))
    }

    func testResultFromEarlierGenerationIsDroppedNotAssociated() throws {
        let (store, _) = try auditedStore()
        let frame = TrackFrameFake(); frame.relocalized = true
        let ing = MemoryIngestor(store: store, frame: frame)
        let captured = ing.generation
        frame.generation += 1                              // session restarted / tracking lost and recovered in between
        let s = try ing.ingest([obs(0, [1, 0, 0, 0])], generation: captured)
        XCTAssertTrue(s.rejected)
        XCTAssertEqual(try store.allTracks().first?.sightings, 3)
    }

    func testRealGateBumpsGenerationOnNewSessionAndLostTracking() {
        let g = WorldFrameGate()
        g.sessionStarted(loadedSavedMap: true)
        let g1 = g.generation
        g.update(tracking: .limited, mapping: .limited, relocalizing: true); g.update(tracking: .normal, mapping: .mapped)
        XCTAssertTrue(g.relocalized); XCTAssertEqual(g.generation, g1, "relocalizing keeps the generation")
        g.update(tracking: .notAvailable, mapping: .notAvailable)
        XCTAssertGreaterThan(g.generation, g1, "losing tracking may re-anchor")
        let g2 = g.generation
        g.sessionStarted(loadedSavedMap: false)
        XCTAssertGreaterThan(g.generation, g2)
        g.update(tracking: .limited, mapping: .limited, relocalizing: true); g.update(tracking: .normal, mapping: .mapped)
        let ing = MemoryIngestor(store: try! TrackStore(path: ":memory:"), frame: g)
        XCTAssertFalse(ing.canIngest, "fresh map session never writes the persistent store")
    }
}
