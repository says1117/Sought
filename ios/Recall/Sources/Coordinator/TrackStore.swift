import Foundation
import SQLite3
#if canImport(Memory)
import Memory
#endif

/// Where Retrieval reads remembered objects from.
protocol TrackProviding: AnyObject {
    func allTracks() throws -> [Track]
}

enum TrackStoreError: Error, Equatable { case sqlite(String) }

/// float16 BLOB codec for stored embeddings (little endian, 2 bytes per component).
enum EmbeddingCodec {
    static func encode(_ v: [Float]) -> Data {
        var d = Data(capacity: v.count * 2)
        for f in v { let h = halfBits(f); d.append(UInt8(h & 0xFF)); d.append(UInt8(h >> 8)) }
        return d
    }

    /// nil unless the blob is exactly `dim * 2` bytes and `dim` is positive.
    static func decode(_ blob: Data, dim: Int) -> [Float]? {
        guard dim > 0, blob.count == dim * 2 else { return nil }
        let b = [UInt8](blob)
        return (0..<dim).map { halfFloat(UInt16(b[2 * $0]) | UInt16(b[2 * $0 + 1]) << 8) }
    }

    static func halfBits(_ f: Float) -> UInt16 {
        let x = f.bitPattern
        let sign = UInt16((x >> 16) & 0x8000)
        let exp = Int((x >> 23) & 0xFF)
        var man = x & 0x7FFFFF
        if exp == 0xFF { return sign | 0x7C00 | (man != 0 ? 0x200 : 0) }
        let e = exp - 127 + 15
        if e >= 0x1F { return sign | 0x7C00 }
        if e <= 0 {
            if e < -10 { return sign }
            man |= 0x800000
            let shift = UInt32(14 - e)
            var h = man >> shift
            let rem = man & ((1 << shift) - 1), half = UInt32(1) << (shift - 1)
            if rem > half || (rem == half && (h & 1) == 1) { h += 1 }
            return sign | UInt16(h)
        }
        var h = UInt32(e) << 10 | (man >> 13)
        let rem = man & 0x1FFF
        if rem > 0x1000 || (rem == 0x1000 && (h & 1) == 1) { h += 1 }
        return sign | UInt16(h)
    }

    static func halfFloat(_ h: UInt16) -> Float {
        let sign = UInt32(h & 0x8000) << 16
        let exp = UInt32((h >> 10) & 0x1F), man = UInt32(h & 0x3FF)
        if exp == 0 {
            if man == 0 { return Float(bitPattern: sign) }
            let v = Float(man) / 16_777_216            // man * 2^-24
            return sign != 0 ? -v : v
        }
        if exp == 0x1F { return Float(bitPattern: sign | 0x7F80_0000 | (man << 13)) }
        return Float(bitPattern: sign | ((exp + 112) << 23) | (man << 13))
    }
}

/// SQLite persistence for object tracks, using the contract's `tracks` table (docs/03_CONTRACTS.md section 3).
/// Embeddings stay on the phone and are stored as little-endian float16 BLOBs (contract section 3), converted
/// with bit operations so no `Float16` type is needed on Intel simulators. A row whose BLOB length is not
/// `2 * embedding_dim` is skipped with a logged error rather than decoded into a wrong-sized vector.
/// Pass ":memory:" for tests. Can share the Teach database file (separate connection, busy timeout set).
///
/// MAP IDENTITY (PR 39 review, world-frame P1): x/z only mean something in the ARKit world map that produced them,
/// so every row carries `map_id`, the id of the saved world map it was recorded in (`WorldMapStore.currentMapId`).
/// `map_id` is a phone-local nullable column added by migration (`ALTER TABLE ... ADD COLUMN`); the contract's
/// `tracks` columns and the backend sync are unchanged. Reads return only rows whose `map_id` equals the scope, so
/// tracks of another map are invisible; rows with a NULL `map_id` (written before this column existed, map unknown)
/// match nothing. `purgeOtherMaps(keeping:)` deletes rows of other maps once a map is loaded; they can never become
/// valid again because their map archive was replaced.
final class TrackStore: TrackProviding {
    /// Map id used when no scope is supplied (tests, `TrustedFrame`). The app always supplies the gate's active map id.
    static let defaultMapId = "default"

    private var db: OpaquePointer?
    /// Recursive: `transaction` holds it across `upsert` / `recordMatch` calls.
    private let lock = NSRecursiveLock()
    /// The map id `allTracks()` reads. nil matches nothing (no map identity known).
    private let scope: () -> String?
    /// Rows skipped because their embedding BLOB did not match `embedding_dim`.
    private(set) var invalidRowCount = 0
    var onInvalidRow: (String) -> Void = { NSLog("TrackStore: %@", $0) }
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    init(path: String, scope: @escaping () -> String? = { TrackStore.defaultMapId }) throws {
        self.scope = scope
        if path != ":memory:" {
            try FileManager.default.createDirectory(at: URL(fileURLWithPath: path).deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
        }
        guard sqlite3_open(path, &db) == SQLITE_OK else {
            let e = TrackStoreError.sqlite(msg()); sqlite3_close(db); db = nil; throw e
        }
        sqlite3_busy_timeout(db, 2000)
        for s in MemorySchema.statements where s.contains("EXISTS tracks") { try exec(s) }
        try migrateMapId()
    }

    /// Databases created before map identity have no `map_id` column. Add it (nullable) and index it.
    private func migrateMapId() throws {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "PRAGMA table_info(tracks)", -1, &stmt, nil) == SQLITE_OK else { throw TrackStoreError.sqlite(msg()) }
        var has = false
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let n = sqlite3_column_text(stmt, 1), String(cString: n) == "map_id" { has = true }
        }
        sqlite3_finalize(stmt)
        if !has { try exec("ALTER TABLE tracks ADD COLUMN map_id TEXT") }
        try exec("CREATE INDEX IF NOT EXISTS idx_tracks_map_id ON tracks(map_id)")
    }
    deinit { sqlite3_close(db) }

    static func newId() -> String {
        let alphabet = Array("abcdefghijklmnopqrstuvwxyz0123456789")
        return "obj_" + String((0..<10).map { _ in alphabet.randomElement()! })
    }

    /// Tracks of the current scope's map only.
    func allTracks() throws -> [Track] {
        guard let id = scope() else { return [] }
        return try allTracks(mapId: id)
    }

    /// Tracks recorded in the map `mapId`; every other map's rows (and rows with an unknown map) stay invisible.
    func allTracks(mapId: String) throws -> [Track] {
        lock.lock(); defer { lock.unlock() }
        var out: [Track] = []
        var stmt: OpaquePointer?
        let sql = "SELECT id,x,y,z,embedding,sightings,persistence,last_seen,embedding_dim FROM tracks WHERE active = 1 AND map_id = ?1"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { throw TrackStoreError.sqlite(msg()) }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, mapId, -1, Self.transient)
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let idc = sqlite3_column_text(stmt, 0) else { continue }
            let id = String(cString: idc)
            let n = Int(sqlite3_column_bytes(stmt, 4))
            let dim = Int(sqlite3_column_int(stmt, 8))
            let blob = (n > 0 ? sqlite3_column_blob(stmt, 4).map { Data(bytes: $0, count: n) } : nil) ?? Data()
            guard let emb = EmbeddingCodec.decode(blob, dim: dim) else {
                invalidRowCount += 1
                onInvalidRow("skipping \(id): embedding BLOB is \(n) bytes but embedding_dim is \(dim) (float16 needs \(dim * 2))")
                continue
            }
            let seen = sqlite3_column_text(stmt, 7).flatMap { ISO8601DateFormatter().date(from: String(cString: $0)) }
            out.append(Track(id: id,
                             position: SIMD3(Float(sqlite3_column_double(stmt, 1)), Float(sqlite3_column_double(stmt, 2)),
                                             Float(sqlite3_column_double(stmt, 3))),
                             embedding: emb, sightings: Int(sqlite3_column_int(stmt, 5)),
                             persistence: Float(sqlite3_column_double(stmt, 6)),
                             lastSeen: seen?.timeIntervalSince1970 ?? 0))
        }
        return out
    }

    /// Delete every track not recorded in `mapId` (other maps, unknown map). Returns how many rows went.
    @discardableResult
    func purgeOtherMaps(keeping mapId: String) throws -> Int {
        lock.lock(); defer { lock.unlock() }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "DELETE FROM tracks WHERE map_id IS NULL OR map_id <> ?1", -1, &stmt, nil) == SQLITE_OK else {
            throw TrackStoreError.sqlite(msg())
        }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, mapId, -1, Self.transient)
        guard sqlite3_step(stmt) == SQLITE_DONE else { throw TrackStoreError.sqlite(msg()) }
        return Int(sqlite3_changes(db))
    }

    /// Runs `body` in one SQLite transaction. Just before COMMIT, `commitIf` is asked whether the writes are still
    /// valid (the frame / map did not change meanwhile); if not, everything is rolled back and nil returned.
    /// A throwing body also rolls back. The store lock is held throughout, so other store calls wait.
    func transaction<T>(commitIf: () -> Bool = { true }, _ body: () throws -> T) throws -> T? {
        lock.lock(); defer { lock.unlock() }
        try exec("BEGIN IMMEDIATE")
        do {
            let r = try body()
            guard commitIf() else { try? exec("ROLLBACK"); return nil }
            try exec("COMMIT")
            return r
        } catch {
            try? exec("ROLLBACK")
            throw error
        }
    }

    /// Insert or update one track in map `mapId`. `height` is metres above the floor; `at` stamps first/last seen.
    func upsert(_ t: Track, height: Float = 0, at date: Date = Date(), mapId: String = TrackStore.defaultMapId) throws {
        lock.lock(); defer { lock.unlock() }
        let iso = ISO8601DateFormatter().string(from: date)
        let sql = """
        INSERT INTO tracks (id,label,label_source,description,x,y,z,height_above_floor,embedding,embedding_dim,first_seen,last_seen,sightings,persistence,media_id,active,map_id)
        VALUES (?1,NULL,'none',NULL,?2,?3,?4,?5,?6,?7,?8,?8,?9,?10,NULL,1,?11)
        ON CONFLICT(id) DO UPDATE SET x=?2,y=?3,z=?4,height_above_floor=?5,embedding=?6,embedding_dim=?7,last_seen=?8,sightings=?9,persistence=?10,map_id=?11
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { throw TrackStoreError.sqlite(msg()) }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, t.id, -1, Self.transient)
        sqlite3_bind_double(stmt, 2, Double(t.position.x))
        sqlite3_bind_double(stmt, 3, Double(t.position.y))
        sqlite3_bind_double(stmt, 4, Double(t.position.z))
        sqlite3_bind_double(stmt, 5, Double(height))
        let blob = EmbeddingCodec.encode(t.embedding)
        _ = blob.withUnsafeBytes { sqlite3_bind_blob(stmt, 6, $0.baseAddress, Int32($0.count), Self.transient) }
        sqlite3_bind_int(stmt, 7, Int32(t.embedding.count))
        sqlite3_bind_text(stmt, 8, iso, -1, Self.transient)
        sqlite3_bind_int(stmt, 9, Int32(t.sightings))
        sqlite3_bind_double(stmt, 10, Double(t.persistence))
        sqlite3_bind_text(stmt, 11, mapId, -1, Self.transient)
        guard sqlite3_step(stmt) == SQLITE_DONE else { throw TrackStoreError.sqlite(msg()) }
    }

    /// Persist a matched observation, honouring the Memory `UpdatePlan`. `last_seen`, `sightings` and
    /// `persistence` are always written; position/height and the embedding only when the plan says so.
    /// (The thumbnail is not stored in this table.) Falls back to a full insert if the row is missing.
    func recordMatch(_ t: Track, plan: UpdatePlan, height: Float = 0, at date: Date = Date(),
                     mapId: String = TrackStore.defaultMapId) throws {
        lock.lock(); defer { lock.unlock() }
        var sets = ["last_seen=?", "sightings=?", "persistence=?"]
        if plan.rewritePosition { sets += ["x=?", "y=?", "z=?", "height_above_floor=?"] }
        if plan.rewriteEmbedding { sets += ["embedding=?", "embedding_dim=?"] }
        var stmt: OpaquePointer?
        let sql = "UPDATE tracks SET \(sets.joined(separator: ",")) WHERE id=? AND map_id=?"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { throw TrackStoreError.sqlite(msg()) }
        defer { sqlite3_finalize(stmt) }
        var i: Int32 = 1
        func next() -> Int32 { defer { i += 1 }; return i }
        sqlite3_bind_text(stmt, next(), ISO8601DateFormatter().string(from: date), -1, Self.transient)
        sqlite3_bind_int(stmt, next(), Int32(t.sightings))
        sqlite3_bind_double(stmt, next(), Double(t.persistence))
        if plan.rewritePosition {
            sqlite3_bind_double(stmt, next(), Double(t.position.x))
            sqlite3_bind_double(stmt, next(), Double(t.position.y))
            sqlite3_bind_double(stmt, next(), Double(t.position.z))
            sqlite3_bind_double(stmt, next(), Double(height))
        }
        if plan.rewriteEmbedding {
            let blob = EmbeddingCodec.encode(t.embedding)
            _ = blob.withUnsafeBytes { sqlite3_bind_blob(stmt, next(), $0.baseAddress, Int32($0.count), Self.transient) }
            sqlite3_bind_int(stmt, next(), Int32(t.embedding.count))
        }
        sqlite3_bind_text(stmt, next(), t.id, -1, Self.transient)
        sqlite3_bind_text(stmt, next(), mapId, -1, Self.transient)
        guard sqlite3_step(stmt) == SQLITE_DONE else { throw TrackStoreError.sqlite(msg()) }
        if sqlite3_changes(db) == 0 { try upsert(t, height: height, at: date, mapId: mapId) }
    }

    private func msg() -> String { db.map { String(cString: sqlite3_errmsg($0)) } ?? "no db" }
    private func exec(_ sql: String) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw TrackStoreError.sqlite(msg()) }
    }
}
