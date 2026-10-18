import Foundation
import Security
import UIKit

// Real data from the Recall backend (docs/03_CONTRACTS.md section 2; routes in backend PR 12):
//   GET /api/robot/status   heartbeat + "online"           every 2 s
//   GET /api/objects        object tracks                   every 10 s
//   GET /api/waypoints      taught places (names rooms)     every 10 s
//   GET /api/map            occupancy snapshot              every 10 s
//   GET /api/metadata       {"mock": true} when the server is serving seed data -> SAMPLE DATA badge stays on
//   GET /media/{id}.jpg     thumbnails (public, no token)
// Read-only. The app cannot start a find or come-to-me through the backend yet (no command route), so a find shows
// where Soughtbot last saw the item instead of pretending the robot is driving.

struct BackendConfig: Equatable {
    var baseURL: URL
    var token: String

    /// Settings first (typed in on the phone), then Info.plist (filled from the gitignored Secrets.xcconfig, the same
    /// keys the robot app uses). Placeholders count as not configured.
    static func current() -> BackendConfig? {
        let typed = UserDefaults.standard.string(forKey: "backendURL")
        let info = Bundle.main.infoDictionary ?? [:]
        let urlString = (typed?.isEmpty == false ? typed : info["BACKEND_BASE_URL"] as? String) ?? ""
        // Launch argument `-backendToken` is for simulator testing only (argument values are never saved).
        let token = Keychain.read("backendToken") ?? UserDefaults.standard.string(forKey: "backendToken")
            ?? (info["RECALL_TOKEN"] as? String) ?? ""
        guard let url = clean(urlString), !token.isEmpty, token != "change-me", !token.hasPrefix("$(") else { return nil }
        return BackendConfig(baseURL: url, token: token)
    }

    static func clean(_ s: String) -> URL? {
        let t = s.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty, !t.contains("example.com"), let u = URL(string: t),
              let scheme = u.scheme, scheme == "https" || scheme == "http", u.host != nil else { return nil }
        return u
    }
}

/// Tiny Keychain wrapper for the backend token.
enum Keychain {
    static func read(_ key: String) -> String? {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrAccount as String: key,
                                kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data else { return nil }
        return String(data: d, encoding: .utf8)
    }

    static func write(_ key: String, _ value: String) {
        let base: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrAccount as String: key]
        SecItemDelete(base as CFDictionary)
        guard !value.isEmpty else { return }
        var add = base
        add[kSecValueData as String] = Data(value.utf8)
        SecItemAdd(add as CFDictionary, nil)
    }
}

@MainActor
final class BackendRobotSource: RobotSource {
    let config: BackendConfig
    /// Shown in Settings when the server cannot be reached or rejects the token.
    @Published var connectionProblem: String?
    @Published private(set) var serverIsMock = false
    /// The server has no items yet (robot uploads, T-071): show the sample catalog, clearly labeled, with live status.
    @Published private(set) var itemsAreSample = false
    private lazy var sample = MockRobotSource(seedOnly: true)

    override var isSample: Bool { serverIsMock || itemsAreSample }
    override var sampleLabel: String { itemsAreSample && !serverIsMock ? "SAMPLE ITEMS" : "SAMPLE DATA" }
    override var sampleSpoken: String {
        itemsAreSample && !serverIsMock ? "Items are sample data. Soughtbot\u{2019}s status is live." : super.sampleSpoken
    }
    override var showsSamplePlanWithLivePose: Bool { itemsAreSample && !serverIsMock }
    override var sourceName: String {
        serverIsMock ? "Soughtbot server (sample data)" : itemsAreSample ? "Soughtbot server (live status, sample items)" : "Soughtbot server"
    }
    override var canComeToMe: Bool { false }   // needs POST /api/commands (board task T-070)

    private var loop: Task<Void, Never>?
    private var photos: [String: Data] = [:]
    private var photoRequests: Set<String> = []
    private var waypoints: [Waypoint] = []

    init(config: BackendConfig) {
        self.config = config
        super.init()
        isLoading = true
    }

    override func start() {
        guard loop == nil else { return }
        loop = Task { [weak self] in
            var tick = 0
            while !Task.isCancelled {
                guard let self else { return }
                await self.refreshStatus()
                if tick % 5 == 0 { await self.refreshWorld() }
                tick += 1
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }
    }

    override func stop() { super.stop(); loop?.cancel(); loop = nil }

    // MARK: Fetching

    private func get<T: Decodable>(_ path: String, as: T.Type) async throws -> T {
        var req = URLRequest(url: config.baseURL.appending(path: path))
        req.setValue("Bearer \(config.token)", forHTTPHeaderField: "Authorization")
        req.timeoutInterval = 5
        let (data, resp) = try await URLSession.shared.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        if code == 401 { throw BackendError.unauthorized }
        if code == 404 { throw BackendError.notYet }
        guard (200..<300).contains(code) else { throw BackendError.http(code) }
        return try Self.decoder.decode(T.self, from: data)
    }

    enum BackendError: Error { case unauthorized, notYet, http(Int) }

    private func refreshStatus() async {
        do {
            let hb = try await get("api/robot/status", as: HeartbeatDTO.self)
            var s = status
            s.state = RobotState(rawValue: hb.state) ?? .idle
            s.task = hb.task
            s.battery = hb.phone_battery
            s.pose = hb.pose.map { Pose2D(x: $0.x, z: $0.z, yawDeg: $0.yaw_deg ?? 0) }
            // The server says whether the last heartbeat is under 10 s old; keep its time so "last seen" is honest.
            s.lastHeartbeat = hb.online ? Date() : (hb.t ?? s.lastHeartbeat)
            status = s
            if let p = s.pose, var m = map {
                if m.trail.last != p { m.trail.append(p); if m.trail.count > 14 { m.trail.removeFirst(m.trail.count - 14) } }
                map = m
            }
            connectionProblem = nil
        } catch BackendError.notYet {
            connectionProblem = "Connected. Soughtbot has not checked in yet."
        } catch {
            note(error)
        }
    }

    private func refreshWorld() async {
        if let meta = try? await get("api/metadata", as: MetadataDTO.self) { serverIsMock = meta.mock ?? false }
        do {
            let wps = (try? await get("api/waypoints", as: [WaypointDTO].self)) ?? []
            waypoints = wps.map { Waypoint(id: $0.id, name: $0.name, x: $0.pose.x, z: $0.pose.z) }
            var snapshot = map ?? MapSnapshot(rooms: [], waypoints: [], grid: nil, trail: [], updatedAt: Date())
            if let m = try? await get("api/map", as: MapDTO.self) {
                snapshot.grid = m.grid
                snapshot.updatedAt = m.updated_at ?? snapshot.updatedAt
            }
            snapshot.waypoints = waypoints
            map = (snapshot.grid != nil || !waypoints.isEmpty) ? snapshot : nil

            let tracks = try await get("api/objects", as: [ObjectDTO].self)
            if tracks.isEmpty && !serverIsMock {
                // Nothing uploaded yet: keep the live status, borrow the labeled sample catalog and floor plan.
                if !itemsAreSample {
                    itemsAreSample = true
                    objects = sample.objects
                    findLog = sample.findLog
                }
                if snapshot.grid == nil {
                    var plan = sample.map ?? snapshot
                    plan.trail = map?.trail ?? []
                    plan.waypoints = waypoints.isEmpty ? plan.waypoints : waypoints
                    map = plan
                }
                isLoading = false
                if connectionProblem?.hasPrefix("Connected") != true { connectionProblem = nil }
                return
            }
            itemsAreSample = false
            let previous = Dictionary(uniqueKeysWithValues: objects.map { ($0.id, $0) })
            objects = tracks.map { t in
                let near = snapshot.nearestWaypoint(x: t.position.x, z: t.position.z)
                let nearName = near.flatMap { hypot($0.x - t.position.x, $0.z - t.position.z) < 2.5 ? $0.name : nil }
                var o = TrackedObject(
                    id: t.id, label: t.label.capitalizedFirst, description: t.description,
                    x: t.position.x, z: t.position.z, firstSeen: t.first_seen ?? Date(), lastSeen: t.last_seen ?? Date(),
                    sightings: t.sightings ?? 1, persistence: t.persistence,
                    history: (t.history ?? []).compactMap { h in h.t.map { HistoryPoint(t: $0, x: h.x, z: h.z) } },
                    whereText: nearName.map { "Near the \($0.lowercased())" } ?? "Seen by Soughtbot",
                    room: nearName?.capitalized,
                    photo: t.media_id.flatMap { photos[$0] }.map { .jpeg($0) } ?? .none)
                // User choices live on the phone.
                if let old = previous[t.id] { o.isEssential = old.isEssential; o.timesSought = old.timesSought }
                return o
            }
            for t in tracks { if let id = t.media_id, photos[id] == nil { fetchPhoto(id, for: t.id) } }
            isLoading = false
            if connectionProblem?.hasPrefix("Connected") != true { connectionProblem = nil }
        } catch {
            note(error)
            isLoading = false
        }
    }

    private func fetchPhoto(_ mediaId: String, for objectId: String) {
        guard !photoRequests.contains(mediaId) else { return }
        photoRequests.insert(mediaId)
        Task { [weak self] in
            guard let self else { return }
            let url = self.config.baseURL.appending(path: "media/\(mediaId).jpg")
            guard let (data, resp) = try? await URLSession.shared.data(from: url),
                  (resp as? HTTPURLResponse)?.statusCode == 200, UIImage(data: data) != nil else {
                self.photoRequests.remove(mediaId); return
            }
            self.photos[mediaId] = data
            if let i = self.objects.firstIndex(where: { $0.id == objectId }) { self.objects[i].photo = .jpeg(data) }
        }
    }

    private func note(_ error: Error) {
        switch error {
        case BackendError.unauthorized: connectionProblem = "The server refused the token. Check it in Settings."
        case BackendError.http(let c): connectionProblem = "The server answered with an error (\(c))."
        default: connectionProblem = "Can\u{2019}t reach Soughtbot\u{2019}s server."
        }
    }

    // MARK: Commands

    /// No command route yet: show where Soughtbot last saw it, honestly, instead of a fake drive.
    override func startFind(_ query: String, match: TrackedObject?) {
        find = FindProgress(id: "cmd_local_\(Int(Date().timeIntervalSince1970))", query: query,
                            phase: match == nil ? .notFound : .remembered, match: match)
    }

    override func cancelFind() { super.cancelFind() }

    // MARK: Decoding

    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        let frac = ISO8601DateFormatter(); frac.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let plain = ISO8601DateFormatter()
        d.dateDecodingStrategy = .custom { dec in
            let s = try dec.singleValueContainer().decode(String.self)
            if let x = frac.date(from: s) ?? plain.date(from: s) { return x }
            throw DecodingError.dataCorrupted(.init(codingPath: dec.codingPath, debugDescription: "bad date \(s)"))
        }
        return d
    }()
}

// Wire shapes (snake_case as sent). Optional where the contract allows the field to be missing.
private struct PoseDTO: Decodable { var x: Double; var z: Double; var yaw_deg: Double? }
private struct HeartbeatDTO: Decodable {
    var t: Date?; var state: String; var task: String?; var pose: PoseDTO?; var phone_battery: Double?; var online: Bool
}
private struct MetadataDTO: Decodable { var mock: Bool? }
private struct WaypointDTO: Decodable { var id: String; var name: String; var pose: PoseDTO }
private struct PositionDTO: Decodable { var x: Double; var y: Double?; var z: Double }
private struct HistoryDTO: Decodable { var t: Date?; var x: Double; var z: Double }
private struct ObjectDTO: Decodable {
    var id: String; var label: String; var description: String?; var position: PositionDTO
    var first_seen: Date?; var last_seen: Date?; var sightings: Int?; var persistence: Double?
    var media_id: String?; var history: [HistoryDTO]?
}
private struct MapDTO: Decodable {
    struct Origin: Decodable { var x: Double; var z: Double }
    var resolution_m: Double; var origin: Origin; var width: Int; var height: Int; var cells_b64: String; var updated_at: Date?
    var grid: OccupancyGrid? {
        guard let d = Data(base64Encoded: cells_b64), d.count == width * height else { return nil }
        return OccupancyGrid(resolution: resolution_m, originX: origin.x, originZ: origin.z, width: width, height: height, cells: [UInt8](d))
    }
}
