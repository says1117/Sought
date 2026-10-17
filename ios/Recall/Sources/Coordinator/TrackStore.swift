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

/// SQLite persistence for object tracks, using the contract's `tracks` table (docs/03_CONTRACTS.md section 3).
/// Embeddings stay on the phone. They are stored as float32 BLOBs here (the contract text says float16; nothing
/// outside this file reads them, and float32 avoids a Float16 dependency on Intel simulators).
/// Pass ":memory:" for tests. Can share the Teach database file (separate connection, busy timeout set).
final class TrackStore: TrackProviding {
    private var db: OpaquePointer?
    private let lock = NSLock()
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    init(path: String) throws {
        if path != ":memory:" {
            try FileManager.default.createDirectory(at: URL(fileURLWithPath: path).deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
        }
        guard sqlite3_open(path, &db) == SQLITE_OK else {
            let e = TrackStoreError.sqlite(msg()); sqlite3_close(db); db = nil; throw e
        }
        sqlite3_busy_timeout(db, 2000)
        for s in MemorySchema.statements where s.contains("EXISTS tracks") { try exec(s) }
    }
    deinit { sqlite3_close(db) }

    static func newId() -> String {
        let alphabet = Array("abcdefghijklmnopqrstuvwxyz0123456789")
        return "obj_" + String((0..<10).map { _ in alphabet.randomElement()! })
    }

    func allTracks() throws -> [Track] {
        lock.lock(); defer { lock.unlock() }
        var out: [Track] = []
        var stmt: OpaquePointer?
        let sql = "SELECT id,x,y,z,embedding,sightings,persistence,last_seen FROM tracks WHERE active = 1"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { throw TrackStoreError.sqlite(msg()) }
        defer { sqlite3_finalize(stmt) }
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let idc = sqlite3_column_text(stmt, 0) else { continue }
            let n = Int(sqlite3_column_bytes(stmt, 4))
            var emb = [Float](repeating: 0, count: n / MemoryLayout<Float>.size)
            if n > 0, let raw = sqlite3_column_blob(stmt, 4) { memcpy(&emb, raw, emb.count * MemoryLayout<Float>.size) }
            let seen = sqlite3_column_text(stmt, 7).flatMap { ISO8601DateFormatter().date(from: String(cString: $0)) }
            out.append(Track(id: String(cString: idc),
                             position: SIMD3(Float(sqlite3_column_double(stmt, 1)), Float(sqlite3_column_double(stmt, 2)),
                                             Float(sqlite3_column_double(stmt, 3))),
                             embedding: emb, sightings: Int(sqlite3_column_int(stmt, 5)),
                             persistence: Float(sqlite3_column_double(stmt, 6)),
                             lastSeen: seen?.timeIntervalSince1970 ?? 0))
        }
        return out
    }

    /// Insert or update one track. `height` is metres above the floor; `at` stamps first/last seen.
    func upsert(_ t: Track, height: Float = 0, at date: Date = Date()) throws {
        lock.lock(); defer { lock.unlock() }
        let iso = ISO8601DateFormatter().string(from: date)
        let sql = """
        INSERT INTO tracks (id,label,label_source,description,x,y,z,height_above_floor,embedding,embedding_dim,first_seen,last_seen,sightings,persistence,media_id,active)
        VALUES (?1,NULL,'none',NULL,?2,?3,?4,?5,?6,?7,?8,?8,?9,?10,NULL,1)
        ON CONFLICT(id) DO UPDATE SET x=?2,y=?3,z=?4,height_above_floor=?5,embedding=?6,embedding_dim=?7,last_seen=?8,sightings=?9,persistence=?10
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { throw TrackStoreError.sqlite(msg()) }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, t.id, -1, Self.transient)
        sqlite3_bind_double(stmt, 2, Double(t.position.x))
        sqlite3_bind_double(stmt, 3, Double(t.position.y))
        sqlite3_bind_double(stmt, 4, Double(t.position.z))
        sqlite3_bind_double(stmt, 5, Double(height))
        t.embedding.withUnsafeBytes { sqlite3_bind_blob(stmt, 6, $0.baseAddress, Int32($0.count), Self.transient) }
        sqlite3_bind_int(stmt, 7, Int32(t.embedding.count))
        sqlite3_bind_text(stmt, 8, iso, -1, Self.transient)
        sqlite3_bind_int(stmt, 9, Int32(t.sightings))
        sqlite3_bind_double(stmt, 10, Double(t.persistence))
        guard sqlite3_step(stmt) == SQLITE_DONE else { throw TrackStoreError.sqlite(msg()) }
    }

    private func msg() -> String { db.map { String(cString: sqlite3_errmsg($0)) } ?? "no db" }
    private func exec(_ sql: String) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw TrackStoreError.sqlite(msg()) }
    }
}
