/// On-phone SQLite schema, copied from docs/03_CONTRACTS.md section 3.
/// Embeddings are float16 BLOBs. Change this only together with the contract.
public enum MemorySchema {
    public static let statements: [String] = [
        "CREATE TABLE IF NOT EXISTS waypoints (id TEXT PRIMARY KEY, name TEXT, x REAL, z REAL, yaw_deg REAL, media_id TEXT, created_at TEXT)",
        "CREATE TABLE IF NOT EXISTS routes (id TEXT PRIMARY KEY, name TEXT, kind TEXT, waypoint_ids TEXT)",
        """
        CREATE TABLE IF NOT EXISTS tracks (
          id TEXT PRIMARY KEY, label TEXT, label_source TEXT, description TEXT,
          x REAL, y REAL, z REAL, height_above_floor REAL,
          embedding BLOB, embedding_dim INTEGER,
          first_seen TEXT, last_seen TEXT, sightings INTEGER, persistence REAL,
          media_id TEXT, active INTEGER DEFAULT 1)
        """,
        "CREATE TABLE IF NOT EXISTS sightings (id INTEGER PRIMARY KEY, track_id TEXT, patrol_id TEXT, x REAL, y REAL, z REAL, sim REAL, t TEXT)",
        "CREATE TABLE IF NOT EXISTS keyframes (id TEXT PRIMARY KEY, patrol_id TEXT, x REAL, z REAL, yaw_deg REAL, media_id TEXT, t TEXT, reason TEXT)",
        "CREATE TABLE IF NOT EXISTS patrols (id TEXT PRIMARY KEY, kind TEXT, started_at TEXT, ended_at TEXT, route_id TEXT, summary TEXT)",
        """
        CREATE TABLE IF NOT EXISTS events (id TEXT PRIMARY KEY, patrol_id TEXT, type TEXT, severity TEXT, label TEXT, confidence REAL,
          x REAL, y REAL, z REAL, prev_x REAL, prev_z REAL, near_waypoint TEXT, on_route TEXT, dist_route REAL,
          before_media_id TEXT, after_media_id TEXT, spoken TEXT, created_at TEXT)
        """,
        "CREATE TABLE IF NOT EXISTS occupancy (patrol_id TEXT, cell_x INTEGER, cell_z INTEGER, hits INTEGER, PRIMARY KEY (patrol_id, cell_x, cell_z))",
        "CREATE TABLE IF NOT EXISTS sync_queue (id INTEGER PRIMARY KEY, method TEXT, path TEXT, body TEXT, media_path TEXT, attempts INTEGER DEFAULT 0, next_try REAL)",
    ]
}
