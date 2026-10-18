import Foundation

// App-side models. Field names follow docs/03_CONTRACTS.md section 2 (heartbeat 2.1, waypoint 2.2,
// object track 2.4, map snapshot 2.7). Fields the app derives itself (room, whereText) are marked.

enum RobotState: String, Codable, CaseIterable {
    case idle, teaching, finding, exploring, blocked, error
    case comingToUser = "coming_to_user"
    case patrolling, checkingRoute = "checking_route"   // still in the contract, not produced (cut)
}

struct Pose2D: Codable, Equatable {
    var x: Double
    var z: Double
    var yawDeg: Double

    enum CodingKeys: String, CodingKey { case x, z, yawDeg = "yaw_deg" }
}

struct RobotStatus: Equatable {
    var state: RobotState
    var task: String?            // "find: blue backpack"
    var battery: Double?         // 0...1, robot phone battery
    var pose: Pose2D?
    var lastHeartbeat: Date?     // nil means never heard from it

    static let offlineAfter: TimeInterval = 10

    func isOnline(now: Date = Date()) -> Bool {
        guard let t = lastHeartbeat else { return false }
        return now.timeIntervalSince(t) < Self.offlineAfter
    }
}

struct HistoryPoint: Codable, Equatable {
    var t: Date
    var x: Double
    var z: Double
}

struct TrackedObject: Identifiable, Equatable {
    var id: String
    var label: String
    var description: String?
    var x: Double
    var z: Double
    var firstSeen: Date
    var lastSeen: Date
    var sightings: Int
    var persistence: Double? = nil   // 0...1 from the contract: how reliably it is seen in this spot
    var history: [HistoryPoint]
    // App side, derived or user set
    var whereText: String        // "By the front door"; from the nearest waypoint when real
    var room: String?
    var photo: PhotoRef
    var isEssential = false
    var timesSought = 0
    /// Set when this item is a pin the person left, not something Soughtbot saw.
    var pin: PinInfo? = nil
    /// The robot saw it but has no name for it (label_source "none"); the person names it in Sought.
    var needsName = false
    var isPin: Bool { pin != nil }
}

/// Where a picture comes from. Asset names are the bundled SAMPLE photos from the Figma.
enum PhotoRef: Equatable {
    case asset(String)
    case jpeg(Data)
    case none
}

struct Waypoint: Identifiable, Equatable {
    var id: String
    var name: String
    var x: Double
    var z: Double
}

/// A named room rectangle in world meters. Real maps only have waypoints, so rooms are SAMPLE only for now.
struct Room: Identifiable, Equatable {
    var id: String { name }
    var name: String
    var minX: Double, minZ: Double, maxX: Double, maxZ: Double

    func contains(x: Double, z: Double) -> Bool { x >= minX && x <= maxX && z >= minZ && z <= maxZ }
}

struct OccupancyGrid: Equatable {
    var resolution: Double
    var originX: Double
    var originZ: Double
    var width: Int
    var height: Int
    var cells: [UInt8]   // 0 free, 1 unknown, 2 occupied low, 3 occupied high
}

struct MapSnapshot: Equatable {
    var rooms: [Room]
    var waypoints: [Waypoint]
    var grid: OccupancyGrid?
    var trail: [Pose2D]          // recent robot poses for the dotted path
    /// Every place the robot has reported being, from its heartbeats (no floor plan from the robot yet).
    var explored: [ExploredPoint] = []
    /// Points that must fit on screen (item positions) without drawing anything.
    var anchors: [ExploredPoint] = []
    var updatedAt: Date

    /// World bounds that the map view fits to the screen.
    var bounds: (minX: Double, minZ: Double, maxX: Double, maxZ: Double) {
        if let g = grid {
            return (g.originX, g.originZ, g.originX + Double(g.width) * g.resolution, g.originZ + Double(g.height) * g.resolution)
        }
        let pts = explored + anchors
        let xs = rooms.flatMap { [$0.minX, $0.maxX] } + waypoints.map(\.x) + pts.map(\.x)
        let zs = rooms.flatMap { [$0.minZ, $0.maxZ] } + waypoints.map(\.z) + pts.map(\.z)
        let pad = (rooms.isEmpty && !pts.isEmpty) ? 0.6 : 0   // room around a path with no walls
        return ((xs.min() ?? -1) - pad, (zs.min() ?? -1) - pad, (xs.max() ?? 1) + pad, (zs.max() ?? 1) + pad)
    }

    func room(atX x: Double, z: Double) -> Room? { rooms.first { $0.contains(x: x, z: z) } }

    func nearestWaypoint(x: Double, z: Double) -> Waypoint? {
        waypoints.min { hypot($0.x - x, $0.z - z) < hypot($1.x - x, $1.z - z) }
    }
}

// MARK: - Find

enum FindPhase: Equatable {
    /// Backend source: the command is on the server, waiting for Soughtbot to pick it up (contract 2.9 "queued").
    case queued
    case searching               // robot is checking memory / planning
    case driving(distanceM: Double?)
    case arrived
    /// Backend source: no way to send Soughtbot yet, so the app shows where it last saw the item.
    case remembered
    /// Backend source: the robot finished the command and said this (contract 2.9 "result").
    case reported(result: String)
    case notFound
    case failed(reason: String)
    case cancelled
}

struct FindProgress: Equatable {
    var id: String
    var query: String
    var phase: FindPhase
    var match: TrackedObject?
}

extension TrackedObject {
    /// Plain words for persistence. Nil persistence (not reported) says nothing about certainty.
    var certaintyWord: String {
        if isPin { return "Pinned by you" }
        guard let p = persistence else { return "Seen here" }
        switch p {
        case 0.7...: return "Usually here"
        case 0.4..<0.7: return "Seen here a few times"
        default: return "Recently moved"
        }
    }
}

// MARK: - Come to me (T-068, waypoint version of docs/COME_TO_ME_PLAN.md)

/// Where the person says they are. The waypoint id is what the command will carry (target {waypoint_id}).
struct ComeTarget: Equatable, Codable {
    var waypointId: String?
    var name: String          // "the kitchen table", "the kitchen"
    var x: Double
    var z: Double
}

enum ComePhase: Equatable {
    case going(distanceM: Double?)
    case arrived
    case failed(reason: String)
    case cancelled
}

struct ComeProgress: Equatable {
    var target: ComeTarget
    var phase: ComePhase
    /// Backend source: what the robot said when the command finished.
    var result: String? = nil
}

struct ExploredPoint: Codable, Equatable {
    var x: Double
    var z: Double
}

/// Where the robot has been, kept on this iPhone across launches. A new point every 15 cm of travel; a jump over
/// 1.5 m starts a new stroke (relocalized or a new session) so the map never draws a line through walls.
enum ExploredStore {
    static let minStep = 0.15
    static let maxPoints = 6000
    private static var url: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("explored.json")
    }
    static func load() -> [ExploredPoint] {
        (try? JSONDecoder().decode([ExploredPoint].self, from: Data(contentsOf: url))) ?? []
    }
    static func save(_ pts: [ExploredPoint]) {
        if let d = try? JSONEncoder().encode(pts) { try? d.write(to: url, options: .atomic) }
    }
    static func clear() { try? FileManager.default.removeItem(at: url) }

    /// Adds `p` when it is far enough from the last point; returns true if added.
    static func append(_ p: ExploredPoint, to pts: inout [ExploredPoint]) -> Bool {
        if let last = pts.last, hypot(last.x - p.x, last.z - p.z) < minStep { return false }
        pts.append(p)
        if pts.count > maxPoints { pts.removeFirst(pts.count - maxPoints) }
        return true
    }
}
