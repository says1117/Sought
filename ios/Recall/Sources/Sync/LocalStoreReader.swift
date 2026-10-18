import Foundation
import SQLite3

/// Read-only view of the phone's `waypoints` and `tracks` tables (docs/03_CONTRACTS.md section 3) as contract
/// section 2 bodies. It opens its own read-only connection to the shared database file, so it never takes the
/// stores' locks and never writes. A missing table or column reads as empty (the stores create them on launch).
///
/// MAP IDENTITY: `tracks.map_id` (phone-local column, see TrackStore) says which saved world map a row's x/z belong
/// to. Only rows of the map id passed in are returned; rows of other maps and rows with an unknown map never upload.
/// Rows the backend would reject (non-finite numbers, unparseable timestamps) are skipped here instead of
/// being sent and dropped as 422.
///
/// HEIGHT SANITY: `height_above_floor` is the lifted point's world y minus the floor estimate, so a row far below the
/// floor (or far above any ceiling) has a wrong position too: its keyframe was lifted with a bad pose or bad depth.
/// Such rows are skipped (`plausibleHeight`); a few centimetres under the floor is depth noise and reads as 0.
public final class LocalStoreReader {
    private var db: OpaquePointer?
    private let lock = NSLock()
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    /// nil if the file cannot be opened (no database yet); the caller then uploads nothing.
    public init?(path: String) {
        guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else { sqlite3_close(db); return nil }
        sqlite3_busy_timeout(db, 500)
    }
    deinit { sqlite3_close(db) }

    public func waypoints() -> [WireWaypoint] {
        rows("SELECT id,name,x,z,yaw_deg,media_id,created_at FROM waypoints ORDER BY created_at, rowid", []) { s in
            guard let id = Self.text(s, 0), let created = Self.text(s, 6).flatMap(Self.validTime) else { return nil }
            let x = sqlite3_column_double(s, 2), z = sqlite3_column_double(s, 3), yaw = sqlite3_column_double(s, 4)
            guard x.isFinite, z.isFinite, yaw.isFinite else { return nil }
            return WireWaypoint(id: id, name: Self.text(s, 1) ?? "", pose: WirePose(x: x, z: z, yawDeg: yaw),
                                createdAt: created, mediaId: Self.text(s, 5).flatMap(Self.validMediaId))
        }
    }

    /// Active tracks recorded in map `mapId`, oldest first. `history` is left empty (the caller adds it).
    public func objects(mapId: String) -> [WireObjectTrack] {
        let sql = """
        SELECT id,label,label_source,description,x,y,z,height_above_floor,first_seen,last_seen,sightings,persistence,media_id
        FROM tracks WHERE active = 1 AND map_id = ?1 ORDER BY first_seen, id
        """
        return rows(sql, [mapId]) { s in
            guard let id = Self.text(s, 0), let last = Self.text(s, 9).flatMap(Self.validTime) else { return nil }
            let first = Self.text(s, 8).flatMap(Self.validTime) ?? last
            let x = sqlite3_column_double(s, 4), y = sqlite3_column_double(s, 5), z = sqlite3_column_double(s, 6)
            let h = sqlite3_column_double(s, 7), p = sqlite3_column_double(s, 11)
            guard x.isFinite, y.isFinite, z.isFinite, Self.plausibleHeight.contains(h) else { return nil }
            let source = Self.text(s, 2).flatMap(WireLabelSource.init(rawValue:)) ?? .none
            return WireObjectTrack(id: id, label: Self.text(s, 1) ?? "", labelSource: source,
                                   description: Self.text(s, 3) ?? "", position: WirePosition(x: x, y: y, z: z),
                                   heightAboveFloorM: max(0, h), firstSeen: first, lastSeen: last,
                                   sightings: max(0, Int(sqlite3_column_int(s, 10))),
                                   persistence: p.isFinite ? min(1, max(0, p)) : 0,
                                   mediaId: Self.text(s, 12).flatMap(Self.validMediaId), history: [])
        }
    }

    /// Heights (metres above the floor) a remembered object can really have. Outside this the row is not sent.
    static let plausibleHeight = -0.3...3.5

    // MARK: helpers

    private func rows<T>(_ sql: String, _ args: [String], _ map: (OpaquePointer?) -> T?) -> [T] {
        lock.lock(); defer { lock.unlock() }
        var s: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &s, nil) == SQLITE_OK else { return [] }   // table/column not there yet
        defer { sqlite3_finalize(s) }
        for (i, a) in args.enumerated() { sqlite3_bind_text(s, Int32(i + 1), a, -1, Self.transient) }
        var out: [T] = []
        while sqlite3_step(s) == SQLITE_ROW { if let v = map(s) { out.append(v) } }
        return out
    }
    private static func text(_ s: OpaquePointer?, _ c: Int32) -> String? {
        sqlite3_column_text(s, c).map { String(cString: $0) }
    }
    /// The backend wants timezone-aware ISO 8601; the stores write "2026-10-17T14:03:22Z".
    static func validTime(_ t: String) -> String? {
        let plain = ISO8601DateFormatter()
        let frac = ISO8601DateFormatter(); frac.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return plain.date(from: t) != nil || frac.date(from: t) != nil ? t : nil
    }
    /// Contract ids are 1..128 of [A-Za-z0-9_-]; anything else would 422 the whole body, so send null instead.
    static func validMediaId(_ id: String) -> String? {
        (1...128).contains(id.count) && id.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-") } ? id : nil
    }
}
