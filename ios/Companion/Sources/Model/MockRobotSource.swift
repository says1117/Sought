import Foundation
import UIKit

// SAMPLE DATA. Objects, photos and times come from the Figma Item Log so the app matches the design.
// A fake heartbeat ticks every 2 s and walks the robot through the rooms so the status line and map are visibly alive.
// isSample is always true here, which shows the SAMPLE DATA banner on every screen.

@MainActor
final class MockRobotSource: RobotSource {
    override var isSample: Bool { true }
    override var sourceName: String { "Sample data (no robot)" }
    override var canComeToMe: Bool { true }

    private var heartbeat: Timer?
    private var findTask: Task<Void, Never>?
    private var comeTask: Task<Void, Never>?
    private var routeIndex = 0
    private var routeT = 0.0
    private var battery = 0.82
    private var stateClock = 0

    // A loop through the sample flat, in world meters (x right, z down on screen).
    private let route: [(Double, Double)] = [(-3.0, -1.0), (-1.0, -2.6), (0.6, -1.4), (2.4, -2.8), (3.6, -1.2), (3.8, 1.0), (1.8, 1.2), (-0.4, 0.2)]

    override init() {
        super.init()
        let now = Date()
        func ago(_ m: Double) -> Date { now.addingTimeInterval(-m * 60) }
        func obj(_ id: String, _ label: String, _ photo: String, _ whereText: String, _ room: String, _ x: Double, _ z: Double,
                 _ minAgo: Double, essential: Bool = false, sought: Int = 0, movedFrom: (Double, Double, Double)? = nil) -> TrackedObject {
            var history = [HistoryPoint(t: ago(minAgo), x: x, z: z)]
            if let m = movedFrom { history.insert(HistoryPoint(t: ago(m.2), x: m.0, z: m.1), at: 0) }
            return TrackedObject(id: id, label: label, description: nil, x: x, z: z, firstSeen: ago(max(minAgo, movedFrom?.2 ?? 0) + 30),
                                 lastSeen: ago(minAgo), sightings: 3 + sought, history: history, whereText: whereText, room: room,
                                 photo: .asset("photo_\(photo)"), isEssential: essential, timesSought: sought)
        }
        objects = [
            // The sandals' last move is 2 hours old, matching "Slippers moved to front door · 2 hours ago" on Home.
            { var o = obj("obj_sample0001", "Brown Sandals", "sandals", "By the front door", "Hallway", 4.2, 1.4, 12, sought: 4,
                          movedFrom: (-2.0, -0.5, 150)); o.history[1].t = Date().addingTimeInterval(-120 * 60); return o }(),
            obj("obj_sample0002", "White Chair", "chair", "In the kitchen", "Kitchen", 2.2, -1.6, 15),
            obj("obj_sample0003", "Laundry Basket", "laundry", "In the living room", "Living Room", -3.2, -3.0, 20),
            obj("obj_sample0004", "Metal Water Bottle", "bottle", "Under the table", "Kitchen", 2.0, -0.9, 13, essential: true,
                movedFrom: (-1.5, -2.2, 95)),
            obj("obj_sample0005", "Router", "router", "By the sofa", "Living Room", -2.6, -3.4, 16, essential: true),
            obj("obj_sample0006", "Trash Can", "trash", "In the kitchen", "Kitchen", 4.4, -3.4, 19, essential: true),
            obj("obj_sample0007", "Red Umbrella", "umbrella", "In the living room", "Living Room", -0.6, -0.6, 15, sought: 5),
            obj("obj_sample0008", "Fridge", "fridge", "In the kitchen", "Kitchen", 4.5, -2.4, 18, sought: 3),
            obj("obj_sample0009", "Fan", "fan", "In the kitchen", "Kitchen", 1.5, -3.5, 41, sought: 2),
            obj("obj_sample0010", "Sofa", "sofa", "In the living room", "Living Room", -2.0, -3.5, 17),
            obj("obj_sample0011", "Lamp", "lamp", "In the living room", "Living Room", -3.6, -1.8, 21),
            obj("obj_sample0012", "Coffee Table", "coffeetable", "In the living room", "Living Room", -1.8, -2.0, 31),
        ]
        map = MapSnapshot(
            rooms: [Room(name: "Living Room", minX: -4, minZ: -4, maxX: 1, maxZ: 0.6),
                    Room(name: "Kitchen", minX: 1, minZ: -4, maxX: 5, maxZ: -0.2),
                    Room(name: "Hallway", minX: 1, minZ: -0.2, maxX: 5, maxZ: 2),
                    Room(name: "Bedroom", minX: -4, minZ: 0.6, maxX: 1, maxZ: 2)],
            waypoints: [Waypoint(id: "wpt_sample_door", name: "front door", x: 4.4, z: 1.5),
                        Waypoint(id: "wpt_sample_sofa", name: "sofa", x: -2.2, z: -3.0),
                        Waypoint(id: "wpt_sample_table", name: "kitchen table", x: 2.1, z: -1.0),
                        Waypoint(id: "wpt_sample_kitchen", name: "kitchen", x: 3.2, z: -2.2)],
            grid: nil, trail: [], updatedAt: now)
        liveFrame = UIImage(named: "photo_liveview")   // SAMPLE frame from the Figma
        status = RobotStatus(state: .exploring, task: nil, battery: battery, pose: Pose2D(x: route[0].0, z: route[0].1, yawDeg: 0),
                             lastHeartbeat: now)
    }

    override func start() {
        guard heartbeat == nil else { return }
        heartbeat = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    private func tick() {
        stateClock += 1
        battery = max(0.15, battery - 0.0005)
        var s = status
        s.lastHeartbeat = Date()
        s.battery = battery
        // Only wander when no find or come-to-me owns the robot.
        if find == nil || find.map({ if case .driving = $0.phase { return false }; return true }) == true,
           s.state == .exploring || s.state == .idle {
            s.state = (stateClock % 20) < 15 ? .exploring : .idle
            if s.state == .exploring { advance(&s) }
        }
        status = s
    }

    private func advance(_ s: inout RobotStatus) {
        routeT += 0.25
        if routeT >= 1 { routeT = 0; routeIndex = (routeIndex + 1) % route.count }
        let a = route[routeIndex], b = route[(routeIndex + 1) % route.count]
        let p = Pose2D(x: a.0 + (b.0 - a.0) * routeT, z: a.1 + (b.1 - a.1) * routeT,
                       yawDeg: atan2(-(b.0 - a.0), -(b.1 - a.1)) * 180 / .pi)
        s.pose = p
        if var m = map {
            m.trail.append(p)
            if m.trail.count > 14 { m.trail.removeFirst(m.trail.count - 14) }
            map = m
        }
    }

    // MARK: Find (mock walk through the states)

    override func startFind(_ query: String, match: TrackedObject?) {
        findTask?.cancel()
        let id = "cmd_sample\(Int.random(in: 100_000...999_999))"
        find = FindProgress(id: id, query: query, phase: .searching, match: match)
        status.state = .finding
        status.task = "find: \(match?.label.lowercased() ?? query)"
        findTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard let self, !Task.isCancelled else { return }
            guard let match else {
                self.find?.phase = .notFound; self.status.state = .idle; self.status.task = nil; return
            }
            if let i = self.objects.firstIndex(where: { $0.id == match.id }) { self.objects[i].timesSought += 1 }
            var d = 3.4
            while d > 1.0 {
                self.find?.phase = .driving(distanceM: d)
                self.status.pose = Pose2D(x: match.x + d * 0.6, z: match.z + d * 0.8, yawDeg: 0)
                try? await Task.sleep(nanoseconds: 700_000_000)
                if Task.isCancelled { return }
                d = max(1.0, ((d - 0.3) * 10).rounded() / 10)   // 0.3 m per step, stops 1 m short
            }
            self.find?.phase = .arrived
            self.status.state = .idle
            self.status.task = nil
        }
    }

    override func cancelFind() {
        findTask?.cancel()
        super.cancelFind()
        status.state = .idle
        status.task = nil
    }

    override func comeToMe() {
        comeTask?.cancel()
        status.state = .comingToUser
        comeTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 8_000_000_000)
            guard let self, !Task.isCancelled else { return }
            if self.status.state == .comingToUser { self.status.state = .idle }
        }
    }
}
