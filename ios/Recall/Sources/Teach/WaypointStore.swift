import Foundation
import SQLite3
#if canImport(Memory)
import Memory
#endif
#if canImport(PoseCore)
import PoseCore
#endif

/// A named pose in the Teach world frame (docs/03_CONTRACTS.md section 2.2).
public struct Waypoint: Equatable {
    public var id: String
    public var name: String
    public var x: Double
    public var z: Double
    public var yawDeg: Double
    public var createdAt: String
    public var mediaId: String?

    public var pose: Pose2D { Pose2D(x: x, z: z, yawDeg: yawDeg) }
}

/// An ordered list of waypoint ids (docs/03_CONTRACTS.md section 2.3).
public struct Route: Equatable {
    public var id: String
    public var name: String
    public var kind: String
    public var waypointIds: [String]
}

public enum WaypointStoreError: Error, Equatable {
    case sqlite(String)
    case emptyName
    case duplicateName(String)
    case notFound(String)
    case homeIsProtected
    case unknownWaypoint(String)
}

/// SQLite-backed waypoints and routes. Uses the contract's tables from `MemorySchema`, so it can share
/// the Memory database file (pass the same path) or use its own. One connection, one lock.
public final class WaypointStore {
    public static let homeId = "wpt_home"
    public static let homeName = "home"

    private var db: OpaquePointer?
    private let lock = NSLock()
    private let now: () -> Date
    private let makeId: (String) -> String
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    /// Pass ":memory:" for tests.
    public init(path: String,
                now: @escaping () -> Date = Date.init,
                makeId: @escaping (String) -> String = WaypointStore.randomId) throws {
        self.now = now
        self.makeId = makeId
        if path != ":memory:" {
            try FileManager.default.createDirectory(at: URL(fileURLWithPath: path).deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
        }
        guard sqlite3_open(path, &db) == SQLITE_OK else {
            let error = WaypointStoreError.sqlite(msg())
            sqlite3_close(db); db = nil
            throw error
        }
        for s in MemorySchema.statements where s.contains("waypoints") || s.contains("routes") {
            try exec(s)
        }
    }
    deinit { sqlite3_close(db) }

    public static func randomId(prefix: String) -> String {
        let alphabet = Array("abcdefghijklmnopqrstuvwxyz0123456789")
        return prefix + "_" + String((0..<10).map { _ in alphabet.randomElement()! })
    }

    // MARK: waypoints

    /// Creates the `home` waypoint at the Teach origin if it does not exist yet. Idempotent.
    @discardableResult
    public func ensureHome(at pose: Pose2D) throws -> Waypoint {
        lock.lock(); defer { lock.unlock() }
        if let existing = try fetchWaypoint(id: Self.homeId) { return existing }
        let w = Waypoint(id: Self.homeId, name: Self.homeName, x: pose.x, z: pose.z, yawDeg: pose.yawDeg,
                         createdAt: Self.iso(now()), mediaId: nil)
        try insert(w)
        return w
    }

    /// Names are trimmed and unique ignoring case.
    @discardableResult
    public func addWaypoint(name: String, pose: Pose2D, mediaId: String? = nil) throws -> Waypoint {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { throw WaypointStoreError.emptyName }
        lock.lock(); defer { lock.unlock() }
        guard try fetchWaypoint(named: clean) == nil else { throw WaypointStoreError.duplicateName(clean) }
        let w = Waypoint(id: makeId("wpt"), name: clean, x: pose.x, z: pose.z, yawDeg: pose.yawDeg,
                         createdAt: Self.iso(now()), mediaId: mediaId)
        try insert(w)
        return w
    }

    public func waypoint(id: String) throws -> Waypoint? {
        lock.lock(); defer { lock.unlock() }
        return try fetchWaypoint(id: id)
    }

    public func waypoint(named name: String) throws -> Waypoint? {
        lock.lock(); defer { lock.unlock() }
        return try fetchWaypoint(named: name.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// Oldest first; `home` is always first when present.
    public func waypoints() throws -> [Waypoint] {
        lock.lock(); defer { lock.unlock() }
        return try query("SELECT id,name,x,z,yaw_deg,media_id,created_at FROM waypoints ORDER BY (id = ?) DESC, created_at, rowid",
                         [.text(Self.homeId)], Self.waypoint)
    }

    @discardableResult
    public func rename(id: String, to name: String) throws -> Waypoint {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { throw WaypointStoreError.emptyName }
        lock.lock(); defer { lock.unlock() }
        guard var w = try fetchWaypoint(id: id) else { throw WaypointStoreError.notFound(id) }
        if id == Self.homeId { throw WaypointStoreError.homeIsProtected }
        if let other = try fetchWaypoint(named: clean), other.id != id { throw WaypointStoreError.duplicateName(clean) }
        try run("UPDATE waypoints SET name=? WHERE id=?", [.text(clean), .text(id)])
        w.name = clean
        return w
    }

    public func setMedia(id: String, mediaId: String?) throws {
        lock.lock(); defer { lock.unlock() }
        guard try fetchWaypoint(id: id) != nil else { throw WaypointStoreError.notFound(id) }
        try run("UPDATE waypoints SET media_id=? WHERE id=?", [mediaId.map { .text($0) } ?? .null, .text(id)])
    }

    /// Deletes the waypoint and removes it from every route. `home` cannot be deleted.
    public func deleteWaypoint(id: String) throws {
        lock.lock(); defer { lock.unlock() }
        if id == Self.homeId { throw WaypointStoreError.homeIsProtected }
        guard try fetchWaypoint(id: id) != nil else { throw WaypointStoreError.notFound(id) }
        try exec("BEGIN IMMEDIATE")
        do {
            try run("DELETE FROM waypoints WHERE id=?", [.text(id)])
            for r in try fetchRoutes() where r.waypointIds.contains(id) {
                try run("UPDATE routes SET waypoint_ids=? WHERE id=?",
                        [.text(Self.encode(r.waypointIds.filter { $0 != id })), .text(r.id)])
            }
            try exec("COMMIT")
        } catch { sqlite3_exec(db, "ROLLBACK", nil, nil, nil); throw error }
    }

    // MARK: routes

    @discardableResult
    public func addRoute(name: String, kind: String = "user_path", waypointIds: [String]) throws -> Route {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { throw WaypointStoreError.emptyName }
        lock.lock(); defer { lock.unlock() }
        for id in waypointIds where try fetchWaypoint(id: id) == nil { throw WaypointStoreError.unknownWaypoint(id) }
        guard try fetchRoutes().first(where: { $0.name.caseInsensitiveCompare(clean) == .orderedSame }) == nil
        else { throw WaypointStoreError.duplicateName(clean) }
        let r = Route(id: makeId("rte"), name: clean, kind: kind, waypointIds: waypointIds)
        try run("INSERT INTO routes (id,name,kind,waypoint_ids) VALUES (?,?,?,?)",
                [.text(r.id), .text(r.name), .text(r.kind), .text(Self.encode(r.waypointIds))])
        return r
    }

    public func routes() throws -> [Route] {
        lock.lock(); defer { lock.unlock() }
        return try fetchRoutes()
    }

    public func deleteRoute(id: String) throws {
        lock.lock(); defer { lock.unlock() }
        guard try fetchRoutes().contains(where: { $0.id == id }) else { throw WaypointStoreError.notFound(id) }
        try run("DELETE FROM routes WHERE id=?", [.text(id)])
    }

    // MARK: internals (callers hold the lock)

    private func insert(_ w: Waypoint) throws {
        try run("INSERT INTO waypoints (id,name,x,z,yaw_deg,media_id,created_at) VALUES (?,?,?,?,?,?,?)",
                [.text(w.id), .text(w.name), .real(w.x), .real(w.z), .real(w.yawDeg),
                 w.mediaId.map { .text($0) } ?? .null, .text(w.createdAt)])
    }

    private func fetchWaypoint(id: String) throws -> Waypoint? {
        try query("SELECT id,name,x,z,yaw_deg,media_id,created_at FROM waypoints WHERE id=?", [.text(id)], Self.waypoint).first
    }

    private func fetchWaypoint(named name: String) throws -> Waypoint? {
        try query("SELECT id,name,x,z,yaw_deg,media_id,created_at FROM waypoints WHERE name=? COLLATE NOCASE", [.text(name)], Self.waypoint).first
    }

    private func fetchRoutes() throws -> [Route] {
        try query("SELECT id,name,kind,waypoint_ids FROM routes ORDER BY rowid", []) { s in
            Route(id: Self.col(s, 0) ?? "", name: Self.col(s, 1) ?? "", kind: Self.col(s, 2) ?? "user_path",
                  waypointIds: Self.decode(Self.col(s, 3)))
        }
    }

    private static func waypoint(_ s: OpaquePointer) -> Waypoint {
        Waypoint(id: col(s, 0) ?? "", name: col(s, 1) ?? "", x: sqlite3_column_double(s, 2), z: sqlite3_column_double(s, 3),
                 yawDeg: sqlite3_column_double(s, 4), createdAt: col(s, 6) ?? "", mediaId: col(s, 5))
    }

    private static func col(_ s: OpaquePointer, _ i: Int32) -> String? {
        sqlite3_column_type(s, i) == SQLITE_NULL ? nil : sqlite3_column_text(s, i).map { String(cString: $0) }
    }

    private static func encode(_ ids: [String]) -> String {
        (try? JSONEncoder().encode(ids)).map { String(decoding: $0, as: UTF8.self) } ?? "[]"
    }

    private static func decode(_ text: String?) -> [String] {
        guard let d = text?.data(using: .utf8), let ids = try? JSONDecoder().decode([String].self, from: d) else { return [] }
        return ids
    }

    static func iso(_ d: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f.string(from: d)
    }

    private enum Bind { case text(String), real(Double), null }

    private func msg() -> String { db.map { String(cString: sqlite3_errmsg($0)) } ?? "no db" }

    private func exec(_ sql: String) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw WaypointStoreError.sqlite(msg()) }
    }

    private func prepare(_ sql: String, _ binds: [Bind]) throws -> OpaquePointer {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let s = stmt else { throw WaypointStoreError.sqlite(msg()) }
        for (i, b) in binds.enumerated() {
            let idx = Int32(i + 1)
            switch b {
            case .text(let t): sqlite3_bind_text(s, idx, t, -1, Self.transient)
            case .real(let r): sqlite3_bind_double(s, idx, r)
            case .null: sqlite3_bind_null(s, idx)
            }
        }
        return s
    }

    private func run(_ sql: String, _ binds: [Bind]) throws {
        let s = try prepare(sql, binds)
        defer { sqlite3_finalize(s) }
        guard sqlite3_step(s) == SQLITE_DONE else { throw WaypointStoreError.sqlite(msg()) }
    }

    private func query<T>(_ sql: String, _ binds: [Bind], _ row: (OpaquePointer) -> T) throws -> [T] {
        let s = try prepare(sql, binds)
        defer { sqlite3_finalize(s) }
        var out: [T] = []
        while true {
            let rc = sqlite3_step(s)
            if rc == SQLITE_ROW { out.append(row(s)) } else if rc == SQLITE_DONE { break } else { throw WaypointStoreError.sqlite(msg()) }
        }
        return out
    }
}
