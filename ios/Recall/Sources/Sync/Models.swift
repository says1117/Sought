import Foundation

// Codable models for docs/03_CONTRACTS.md section 2 (schema_version 1).
// Every contract field is encoded, nullable ones as explicit `null`: the backend models
// declare them without defaults, so omitting a key is a 422. Hence the hand-written encode(to:).
// Timestamps are ISO 8601 UTC strings ("2026-10-17T14:03:22Z"); use SyncTime to make them.

public enum SyncTime {
    public static func string(from date: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        f.timeZone = TimeZone(identifier: "UTC")
        return f.string(from: date)
    }
}

public struct WirePose: Codable, Equatable {
    public var x: Double, z: Double, yawDeg: Double
    public init(x: Double, z: Double, yawDeg: Double) { self.x = x; self.z = z; self.yawDeg = yawDeg }
    enum CodingKeys: String, CodingKey { case x, z, yawDeg = "yaw_deg" }
}

public struct WirePosition: Codable, Equatable {
    public var x: Double, y: Double, z: Double
    public init(x: Double, y: Double, z: Double) { self.x = x; self.y = y; self.z = z }
}

public enum WireHeartbeatState: String, Codable, CaseIterable {
    case idle, exploring, teaching, finding
    case comingToUser = "coming_to_user"
    case patrolling
    case checkingRoute = "checking_route"
    case blocked, error
}
public enum WireTrackingState: String, Codable { case normal, limited, notAvailable = "not_available" }
public enum WireMappingStatus: String, Codable { case mapped, limited, extending, notAvailable = "not_available" }

public struct WireHeartbeat: Codable, Equatable {
    public var t: String
    public var state: WireHeartbeatState
    public var task: String
    public var tracking: WireTrackingState
    public var mappingStatus: WireMappingStatus
    public var pose: WirePose
    public var frontCm: Double
    public var rearCm: Double
    public var phoneBattery: Double
    public var firmwareLink: Bool
    public init(t: String, state: WireHeartbeatState, task: String, tracking: WireTrackingState,
                mappingStatus: WireMappingStatus, pose: WirePose, frontCm: Double, rearCm: Double,
                phoneBattery: Double, firmwareLink: Bool) {
        self.t = t; self.state = state; self.task = task; self.tracking = tracking
        self.mappingStatus = mappingStatus; self.pose = pose; self.frontCm = frontCm
        self.rearCm = rearCm; self.phoneBattery = phoneBattery; self.firmwareLink = firmwareLink
    }
    enum CodingKeys: String, CodingKey {
        case t, state, task, tracking, pose
        case mappingStatus = "mapping_status", frontCm = "front_cm", rearCm = "rear_cm"
        case phoneBattery = "phone_battery", firmwareLink = "firmware_link"
    }
}

public struct WireWaypoint: Codable, Equatable {
    public var id: String, name: String
    public var pose: WirePose
    public var createdAt: String
    public var mediaId: String?
    public init(id: String, name: String, pose: WirePose, createdAt: String, mediaId: String?) {
        self.id = id; self.name = name; self.pose = pose; self.createdAt = createdAt; self.mediaId = mediaId
    }
    enum CodingKeys: String, CodingKey { case id, name, pose, createdAt = "created_at", mediaId = "media_id" }
    public func encode(to e: Encoder) throws {
        var c = e.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id); try c.encode(name, forKey: .name); try c.encode(pose, forKey: .pose)
        try c.encode(createdAt, forKey: .createdAt); try c.encode(mediaId, forKey: .mediaId)
    }
}

public enum WireRouteKind: String, Codable { case patrol, userPath = "user_path" }

public struct WireRoute: Codable, Equatable {
    public var id: String, name: String
    public var waypointIds: [String]
    public var kind: WireRouteKind
    public init(id: String, name: String, waypointIds: [String], kind: WireRouteKind) {
        self.id = id; self.name = name; self.waypointIds = waypointIds; self.kind = kind
    }
    enum CodingKeys: String, CodingKey { case id, name, waypointIds = "waypoint_ids", kind }
}

public enum WireLabelSource: String, Codable { case detector, user, none }

public struct WireSighting: Codable, Equatable {
    public var t: String
    public var x: Double, z: Double
    public init(t: String, x: Double, z: Double) { self.t = t; self.x = x; self.z = z }
}

/// Embeddings stay on the phone and are deliberately not a field here.
public struct WireObjectTrack: Codable, Equatable {
    public var id: String, label: String
    public var labelSource: WireLabelSource
    public var description: String
    public var position: WirePosition
    public var heightAboveFloorM: Double
    public var firstSeen: String, lastSeen: String
    public var sightings: Int
    public var persistence: Double
    public var mediaId: String?
    public var history: [WireSighting]
    public init(id: String, label: String, labelSource: WireLabelSource, description: String, position: WirePosition,
                heightAboveFloorM: Double, firstSeen: String, lastSeen: String, sightings: Int,
                persistence: Double, mediaId: String?, history: [WireSighting]) {
        self.id = id; self.label = label; self.labelSource = labelSource; self.description = description
        self.position = position; self.heightAboveFloorM = heightAboveFloorM; self.firstSeen = firstSeen
        self.lastSeen = lastSeen; self.sightings = sightings; self.persistence = persistence
        self.mediaId = mediaId; self.history = history
    }
    enum CodingKeys: String, CodingKey {
        case id, label, description, position, sightings, persistence, history
        case labelSource = "label_source", heightAboveFloorM = "height_above_floor_m"
        case firstSeen = "first_seen", lastSeen = "last_seen", mediaId = "media_id"
    }
    public func encode(to e: Encoder) throws {
        var c = e.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id); try c.encode(label, forKey: .label)
        try c.encode(labelSource, forKey: .labelSource); try c.encode(description, forKey: .description)
        try c.encode(position, forKey: .position); try c.encode(heightAboveFloorM, forKey: .heightAboveFloorM)
        try c.encode(firstSeen, forKey: .firstSeen); try c.encode(lastSeen, forKey: .lastSeen)
        try c.encode(sightings, forKey: .sightings); try c.encode(persistence, forKey: .persistence)
        try c.encode(mediaId, forKey: .mediaId); try c.encode(history, forKey: .history)
    }
}

public enum WireEventType: String, Codable {
    case appeared, disappeared, moved
    case newObstacle = "new_obstacle", pathBlocked = "path_blocked", doorChanged = "door_changed"
}
public enum WireSeverity: String, Codable { case info, warning, hazard }

public struct WireChangeEvent: Codable, Equatable {
    public var id: String
    public var patrolId: String?
    public var type: WireEventType
    public var severity: WireSeverity
    public var label: String
    public var confidence: Double
    public var position: WirePosition
    public var previousPosition: WirePosition?
    public var nearWaypoint: String?
    public var onRoute: String?
    public var distanceToRouteM: Double?
    public var beforeMediaId: String?
    public var afterMediaId: String?
    public var spoken: String
    public var createdAt: String
    public init(id: String, patrolId: String?, type: WireEventType, severity: WireSeverity, label: String,
                confidence: Double, position: WirePosition, previousPosition: WirePosition?, nearWaypoint: String?,
                onRoute: String?, distanceToRouteM: Double?, beforeMediaId: String?, afterMediaId: String?,
                spoken: String, createdAt: String) {
        self.id = id; self.patrolId = patrolId; self.type = type; self.severity = severity; self.label = label
        self.confidence = confidence; self.position = position; self.previousPosition = previousPosition
        self.nearWaypoint = nearWaypoint; self.onRoute = onRoute; self.distanceToRouteM = distanceToRouteM
        self.beforeMediaId = beforeMediaId; self.afterMediaId = afterMediaId; self.spoken = spoken
        self.createdAt = createdAt
    }
    enum CodingKeys: String, CodingKey {
        case id, type, severity, label, confidence, position, spoken
        case patrolId = "patrol_id", previousPosition = "previous_position", nearWaypoint = "near_waypoint"
        case onRoute = "on_route", distanceToRouteM = "distance_to_route_m"
        case beforeMediaId = "before_media_id", afterMediaId = "after_media_id", createdAt = "created_at"
    }
    public func encode(to e: Encoder) throws {
        var c = e.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id); try c.encode(patrolId, forKey: .patrolId)
        try c.encode(type, forKey: .type); try c.encode(severity, forKey: .severity)
        try c.encode(label, forKey: .label); try c.encode(confidence, forKey: .confidence)
        try c.encode(position, forKey: .position); try c.encode(previousPosition, forKey: .previousPosition)
        try c.encode(nearWaypoint, forKey: .nearWaypoint); try c.encode(onRoute, forKey: .onRoute)
        try c.encode(distanceToRouteM, forKey: .distanceToRouteM)
        try c.encode(beforeMediaId, forKey: .beforeMediaId); try c.encode(afterMediaId, forKey: .afterMediaId)
        try c.encode(spoken, forKey: .spoken); try c.encode(createdAt, forKey: .createdAt)
    }
}

public struct WirePathPoint: Codable, Equatable {
    public var t: Double, x: Double, z: Double
    public init(t: Double, x: Double, z: Double) { self.t = t; self.x = x; self.z = z }
}

public struct WirePatrolStats: Codable, Equatable {
    public var distanceM: Double
    public var keyframes: Int, stops: Int
    public init(distanceM: Double, keyframes: Int, stops: Int) {
        self.distanceM = distanceM; self.keyframes = keyframes; self.stops = stops
    }
    enum CodingKeys: String, CodingKey { case distanceM = "distance_m", keyframes, stops }
}

/// `path` must already be down-sampled to at most 1 point per second (the backend rejects denser paths).
public struct WirePatrol: Codable, Equatable {
    public var id: String
    public var startedAt: String
    public var endedAt: String?
    public var routeId: String
    public var path: [WirePathPoint]
    public var eventIds: [String]
    public var summary: String
    public var stats: WirePatrolStats
    public init(id: String, startedAt: String, endedAt: String?, routeId: String, path: [WirePathPoint],
                eventIds: [String], summary: String, stats: WirePatrolStats) {
        self.id = id; self.startedAt = startedAt; self.endedAt = endedAt; self.routeId = routeId
        self.path = path; self.eventIds = eventIds; self.summary = summary; self.stats = stats
    }
    enum CodingKeys: String, CodingKey {
        case id, path, summary, stats
        case startedAt = "started_at", endedAt = "ended_at", routeId = "route_id", eventIds = "event_ids"
    }
    public func encode(to e: Encoder) throws {
        var c = e.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id); try c.encode(startedAt, forKey: .startedAt)
        try c.encode(endedAt, forKey: .endedAt); try c.encode(routeId, forKey: .routeId)
        try c.encode(path, forKey: .path); try c.encode(eventIds, forKey: .eventIds)
        try c.encode(summary, forKey: .summary); try c.encode(stats, forKey: .stats)
    }
}

public struct WireMapOrigin: Codable, Equatable {
    public var x: Double, z: Double
    public init(x: Double, z: Double) { self.x = x; self.z = z }
}

/// cells_b64: base64 of width*height uint8, row-major; 0 free, 1 unknown, 2 occupied_low, 3 occupied_high.
public struct WireMapSnapshot: Codable, Equatable {
    public var resolutionM: Double
    public var origin: WireMapOrigin
    public var width: Int, height: Int
    public var cellsB64: String
    public var updatedAt: String
    public init(resolutionM: Double, origin: WireMapOrigin, width: Int, height: Int, cellsB64: String, updatedAt: String) {
        self.resolutionM = resolutionM; self.origin = origin; self.width = width; self.height = height
        self.cellsB64 = cellsB64; self.updatedAt = updatedAt
    }
    public init(resolutionM: Double, origin: WireMapOrigin, width: Int, height: Int, cells: [UInt8], updatedAt: String) {
        self.init(resolutionM: resolutionM, origin: origin, width: width, height: height,
                  cellsB64: Data(cells).base64EncodedString(), updatedAt: updatedAt)
    }
    enum CodingKeys: String, CodingKey {
        case origin, width, height
        case resolutionM = "resolution_m", cellsB64 = "cells_b64", updatedAt = "updated_at"
    }
}

public enum SyncJSON {
    /// Stable key order and unescaped slashes so queued bodies are byte-identical on replay.
    public static func encode<T: Encodable>(_ value: T) throws -> Data {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try e.encode(value)
    }
}
