import Foundation
import SQLite3

/// One row of the contract's `sync_queue` table (docs/03_CONTRACTS.md section 3).
public struct QueueItem: Equatable {
    public var id: Int64
    public var method: String        // "PUT" or "POST"
    public var path: String          // e.g. "/api/waypoints/wpt_x"
    public var body: Data?           // JSON body, or for media the JSON {"id": ...}
    public var mediaPath: String?    // local JPEG for POST /api/media
    public var attempts: Int
    public var nextTry: Double       // unix seconds; due when <= now
}

public enum SyncQueueError: Error { case sqlite(String) }

/// Durable outbox. Every write to the backend goes here first, so a crash, relaunch or
/// airplane mode loses nothing. Thread-safe (one lock around one connection).
///
/// Idempotency: PUTs are upserts by id on the server, and the queue keeps at most one pending
/// row per (method, path), so re-enqueueing the same id replaces the older body (latest wins)
/// and replaying a row any number of times converges to the same server state.
public final class SyncQueue {
    private var db: OpaquePointer?
    private let lock = NSLock()
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    /// Pass ":memory:" for tests. The table DDL is identical to MemorySchema's, so this can
    /// share the Memory database file (same connection path) or use its own file.
    public init(path: String) throws {
        guard sqlite3_open(path, &db) == SQLITE_OK else { throw SyncQueueError.sqlite(msg()) }
        try exec("PRAGMA journal_mode=WAL")
        try exec("CREATE TABLE IF NOT EXISTS sync_queue (id INTEGER PRIMARY KEY, method TEXT, path TEXT, body TEXT, media_path TEXT, attempts INTEGER DEFAULT 0, next_try REAL)")
    }
    deinit { sqlite3_close(db) }

    // MARK: enqueue

    @discardableResult
    public func enqueue(method: String, path: String, body: Data?, mediaPath: String? = nil, now: Double = 0) throws -> Int64 {
        lock.lock(); defer { lock.unlock() }
        try exec("BEGIN IMMEDIATE")
        do {
            try run("DELETE FROM sync_queue WHERE method=? AND path=? AND IFNULL(media_path,'')=?",
                    [.text(method), .text(path), .text(mediaPath ?? "")])
            try run("INSERT INTO sync_queue (method, path, body, media_path, attempts, next_try) VALUES (?,?,?,?,0,?)",
                    [.text(method), .text(path), body.map { .text(String(decoding: $0, as: UTF8.self)) } ?? .null,
                     mediaPath.map { .text($0) } ?? .null, .real(now)])
            let rowid = sqlite3_last_insert_rowid(db)
            try exec("COMMIT")
            return rowid
        } catch { sqlite3_exec(db, "ROLLBACK", nil, nil, nil); throw error }
    }

    @discardableResult public func put<T: Encodable>(_ path: String, _ value: T, now: Double = 0) throws -> Int64 {
        try enqueue(method: "PUT", path: path, body: SyncJSON.encode(value), now: now)
    }
    @discardableResult public func enqueue(_ v: WireWaypoint, now: Double = 0) throws -> Int64 { try put("/api/waypoints/\(v.id)", v, now: now) }
    @discardableResult public func enqueue(_ v: WireRoute, now: Double = 0) throws -> Int64 { try put("/api/routes/\(v.id)", v, now: now) }
    @discardableResult public func enqueue(_ v: WireObjectTrack, now: Double = 0) throws -> Int64 { try put("/api/objects/\(v.id)", v, now: now) }
    @discardableResult public func enqueue(_ v: WirePatrol, now: Double = 0) throws -> Int64 { try put("/api/patrols/\(v.id)", v, now: now) }
    @discardableResult public func enqueue(_ v: WireChangeEvent, now: Double = 0) throws -> Int64 { try put("/api/events/\(v.id)", v, now: now) }
    /// The map is a single "latest" resource, so a newer snapshot replaces an unsent older one.
    @discardableResult public func enqueue(_ v: WireMapSnapshot, now: Double = 0) throws -> Int64 { try put("/api/map", v, now: now) }

    /// Queue a thumbnail upload. `mediaId` must be an opaque id of 10..128 chars [A-Za-z0-9_-]
    /// (the backend rejects anything else with 422, which we would then drop).
    @discardableResult
    public func enqueueMedia(id mediaId: String, jpegPath: String, now: Double = 0) throws -> Int64 {
        let body = try SyncJSON.encode(["id": mediaId])
        return try enqueue(method: "POST", path: "/api/media", body: body, mediaPath: jpegPath, now: now)
    }

    // MARK: drain side

    /// Oldest due row (FIFO by id), or nil.
    public func nextDue(now: Double) throws -> QueueItem? {
        lock.lock(); defer { lock.unlock() }
        return try query("SELECT id, method, path, body, media_path, attempts, next_try FROM sync_queue WHERE next_try <= ? ORDER BY id LIMIT 1",
                         [.real(now)]).first
    }
    public func all() throws -> [QueueItem] {
        lock.lock(); defer { lock.unlock() }
        return try query("SELECT id, method, path, body, media_path, attempts, next_try FROM sync_queue ORDER BY id", [])
    }
    public func count() throws -> Int { try all().count }

    /// Remove a delivered (or dropped) row. The row is matched on id AND the exact body/media it had
    /// when it was sent: rowids are reused after a delete (the contract DDL has no AUTOINCREMENT), so a
    /// newer version enqueued for the same resource while this one was in flight can carry the same id
    /// and must survive.
    public func remove(_ item: QueueItem) throws {
        lock.lock(); defer { lock.unlock() }
        try run("DELETE FROM sync_queue WHERE id=? AND IFNULL(body,'')=? AND IFNULL(media_path,'')=?", matchArgs(item))
    }
    /// Record a failed attempt, with the same still-the-same-row guard as `remove`.
    public func recordFailure(_ item: QueueItem, attempts: Int, nextTry: Double) throws {
        lock.lock(); defer { lock.unlock() }
        try run("UPDATE sync_queue SET attempts=?, next_try=? WHERE id=? AND IFNULL(body,'')=? AND IFNULL(media_path,'')=?",
                [.int(Int64(attempts)), .real(nextTry)] + matchArgs(item))
    }
    private func matchArgs(_ i: QueueItem) -> [Arg] {
        [.int(i.id), .text(i.body.map { String(decoding: $0, as: UTF8.self) } ?? ""), .text(i.mediaPath ?? "")]
    }
    /// Make every row due now (called after the network returns or a 401 is resolved).
    public func makeAllDue(now: Double) throws {
        lock.lock(); defer { lock.unlock() }
        try run("UPDATE sync_queue SET next_try=? WHERE next_try>?", [.real(now), .real(now)])
    }

    // MARK: sqlite plumbing

    private enum Arg { case text(String), real(Double), int(Int64), null }

    private func msg() -> String { db.map { String(cString: sqlite3_errmsg($0)) } ?? "no db" }
    private func exec(_ sql: String) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw SyncQueueError.sqlite(msg()) }
    }
    private func bind(_ s: OpaquePointer?, _ args: [Arg]) {
        for (i, a) in args.enumerated() {
            let n = Int32(i + 1)
            switch a {
            case .text(let v): sqlite3_bind_text(s, n, v, -1, SyncQueue.transient)
            case .real(let v): sqlite3_bind_double(s, n, v)
            case .int(let v): sqlite3_bind_int64(s, n, v)
            case .null: sqlite3_bind_null(s, n)
            }
        }
    }
    private func run(_ sql: String, _ args: [Arg]) throws {
        var s: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &s, nil) == SQLITE_OK else { throw SyncQueueError.sqlite(msg()) }
        defer { sqlite3_finalize(s) }
        bind(s, args)
        guard sqlite3_step(s) == SQLITE_DONE else { throw SyncQueueError.sqlite(msg()) }
    }
    private func query(_ sql: String, _ args: [Arg]) throws -> [QueueItem] {
        var s: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &s, nil) == SQLITE_OK else { throw SyncQueueError.sqlite(msg()) }
        defer { sqlite3_finalize(s) }
        bind(s, args)
        var out: [QueueItem] = []
        while sqlite3_step(s) == SQLITE_ROW {
            func text(_ c: Int32) -> String? { sqlite3_column_text(s, c).map { String(cString: $0) } }
            out.append(QueueItem(id: sqlite3_column_int64(s, 0), method: text(1) ?? "", path: text(2) ?? "",
                                 body: text(3).map { Data($0.utf8) }, mediaPath: text(4),
                                 attempts: Int(sqlite3_column_int(s, 5)), nextTry: sqlite3_column_double(s, 6)))
        }
        return out
    }
}
