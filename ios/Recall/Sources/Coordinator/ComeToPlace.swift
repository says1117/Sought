import Foundation
#if canImport(PoseCore)
import PoseCore
#endif
#if canImport(ControllerCore)
@testable import ControllerCore
#endif
#if canImport(TeachCore)
import TeachCore
#endif

// Come to me v2 (board T-066, docs/COME_TO_ME_PLAN.md on the plan-v2 branch): drive to a taught place along the
// taught routes and stop about 1 m short. The waypoint version is the one in use; the pose version is accepted only
// when the caller's map id is the map this phone is relocalized against. Hardware safety stays in the ESP32 and the
// obstacle guard: every leg is a plain Controller.goTo with the full forward guard, under the coordinator's lease.

/// Where come-to-me is asked to go.
enum ComeToMeTarget: Equatable {
    /// A Teach waypoint id (`wpt_...`), as a remote `come_to_me` command carries it.
    case waypointId(String)
    /// A waypoint name, as the planner resolves it from speech ("come to the kitchen").
    case waypointName(String)
    /// The user phone's position in a saved world map (pose version, depends on experiment T-064).
    case pose(x: Double, z: Double, mapId: String)
}

/// A taught waypoint as come-to-me sees it.
struct TaughtPlace: Equatable {
    var id: String
    var name: String
    var x: Double
    var z: Double
    /// True when recorded in the coordinate frame in use right now (see `CoordinatorWaypoint.inCurrentFrame`).
    var inCurrentFrame: Bool
}

/// The taught waypoints and routes. Routes are ordered waypoint id lists; consecutive ids are drivable legs.
protocol CoordinatorTaughtPlaces: AnyObject {
    func places() -> [TaughtPlace]
    func routes() -> [[String]]
}

/// Drives one leg of a come-to-me path. Same runner lifetime contract as the other motion protocols.
protocol CoordinatorLegDriving: AnyObject {
    /// The robot's current x/z, or nil without a normal-tracking pose.
    func position() -> (x: Double, z: Double)?
    func drive(x: Double, z: Double, stopDistance: Double) async throws -> CoordinatorTaskResult
    func cancel()
}

/// Tunables. Placeholders until measured on the floor.
struct ComeToMeSettings: Equatable {
    /// How far short of the target the robot stops.
    var stopShortM: Double = 1.0
    /// How close the robot gets to each intermediate route waypoint before heading for the next one.
    var viaStopM: Double = 0.3
    /// A pose target must be this close to some taught waypoint, so the robot only heads into space it has driven.
    var poseMaxFromPlaceM: Double = 2.5
}

struct ComeToPlaceLeg: Equatable {
    var x: Double
    var z: Double
    var stopDistance: Double
    var label: String
}

struct ComeToPlacePlan: Equatable {
    var legs: [ComeToPlaceLeg]
    /// Waypoint names the route passes through (start and target included), nil when driving direct.
    var route: [String]?
}

/// Pure path choice. Taught routes form an undirected graph (each consecutive pair is an edge). If a path connects
/// the waypoint nearest the robot to the target waypoint, the robot drives it waypoint by waypoint; otherwise it
/// drives straight at the target. The last leg always stops `stopShortM` short of the target point.
enum ComeToPlacePlanner {
    static func plan(from here: (x: Double, z: Double), targetPlaceId: String, goal: (x: Double, z: Double, label: String),
                     places: [TaughtPlace], routes: [[String]], settings: ComeToMeSettings) -> ComeToPlacePlan {
        let final = ComeToPlaceLeg(x: goal.x, z: goal.z, stopDistance: settings.stopShortM, label: goal.label)
        let byId = Dictionary(places.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        guard byId[targetPlaceId] != nil,
              let start = places.min(by: { dist($0, here) < dist($1, here) }),
              start.id != targetPlaceId,
              let path = shortestPath(from: start.id, to: targetPlaceId, byId: byId, routes: routes)
        else { return ComeToPlacePlan(legs: [final], route: nil) }

        var legs: [ComeToPlaceLeg] = []
        // Intermediate waypoints only (the target is the final leg). Once one is already inside the stop radius
        // of the goal, driving further along the route would only overshoot, so the path ends there.
        for id in path.dropLast() {
            guard let p = byId[id] else { continue }
            if dist(p, (goal.x, goal.z)) <= settings.stopShortM { break }
            legs.append(ComeToPlaceLeg(x: p.x, z: p.z, stopDistance: settings.viaStopM, label: p.name))
        }
        legs.append(final)
        return ComeToPlacePlan(legs: legs, route: path.compactMap { byId[$0]?.name })
    }

    /// Fewest metres over route edges; nil when the two ids are not connected. Ids not in `byId` are skipped.
    static func shortestPath(from a: String, to b: String, byId: [String: TaughtPlace], routes: [[String]]) -> [String]? {
        var adj: [String: Set<String>] = [:]
        for r in routes {
            let ids = r.filter { byId[$0] != nil }
            for (u, v) in zip(ids, ids.dropFirst()) where u != v {
                adj[u, default: []].insert(v); adj[v, default: []].insert(u)
            }
        }
        var best: [String: Double] = [a: 0]
        var prev: [String: String] = [:]
        var open: Set<String> = [a]
        var done: Set<String> = []
        while let u = open.min(by: { best[$0]! < best[$1]! }) {
            if u == b { break }
            open.remove(u); done.insert(u)
            guard let pu = byId[u] else { continue }
            for v in adj[u] ?? [] where !done.contains(v) {
                guard let pv = byId[v] else { continue }
                let d = best[u]! + dist(pu, (pv.x, pv.z))
                if d < best[v] ?? .infinity { best[v] = d; prev[v] = u; open.insert(v) }
            }
        }
        guard best[b] != nil else { return nil }
        var path = [b]
        while let p = prev[path[0]] { path.insert(p, at: 0) }
        return path.first == a ? path : nil
    }

    static func dist(_ p: TaughtPlace, _ q: (x: Double, z: Double)) -> Double { hypot(p.x - q.x, p.z - q.z) }
}

// MARK: - Adapters

/// Teach `WaypointStore` rows and routes for come-to-me.
final class StoreTaughtPlacesAdapter: CoordinatorTaughtPlaces {
    private let store: WaypointStore
    private let frame: CoordinatorFrameValidity
    init(store: WaypointStore, frame: CoordinatorFrameValidity) { self.store = store; self.frame = frame }

    func places() -> [TaughtPlace] {
        ((try? store.waypoints()) ?? []).map {
            TaughtPlace(id: $0.id, name: $0.name, x: $0.x, z: $0.z, inCurrentFrame: frame.isInCurrentFrame(createdAt: $0.createdAt))
        }
    }
    func routes() -> [[String]] { ((try? store.routes()) ?? []).map(\.waypointIds) }
}

/// One come-to-me leg: Controller.goTo with the full forward guard, stopping `stopDistance` short.
final class ControllerLegDriver: CoordinatorLegDriving {
    private let controller: Controller
    private let poses: PoseSource
    init(controller: Controller, poses: PoseSource) { self.controller = controller; self.poses = poses }

    func position() -> (x: Double, z: Double)? {
        let s = poses.latest()
        guard s.tracking == .normal, let p = s.pose else { return nil }
        return (p.x, p.z)
    }

    func drive(x: Double, z: Double, stopDistance: Double) async throws -> CoordinatorTaskResult {
        let epoch = controller.stopEpoch   // a cancel() from here on cancels this leg even if it lands before the loop starts
        try Task.checkCancellation()
        let status = await controller.goTo(x: x, z: z, stopDistance: stopDistance, since: epoch)
        return ControllerResultMapper.result(status, stats: controller.lastRun)
    }
    func cancel() { controller.stop() }
}

/// Keeps `CoordinatorDependencies` total for callers that do not wire come-to-me.
final class NoTaughtPlaces: CoordinatorTaughtPlaces {
    func places() -> [TaughtPlace] { [] }
    func routes() -> [[String]] { [] }
}
final class UnwiredLegDriver: CoordinatorLegDriving {
    func position() -> (x: Double, z: Double)? { nil }
    func drive(x: Double, z: Double, stopDistance: Double) async throws -> CoordinatorTaskResult {
        .refused(spoken: "Coming to you is not wired up in this build.")
    }
    func cancel() {}
}

// MARK: - Runner

enum ComeToPlaceRunner {
    /// Plans at run time (the robot may have moved while the request was queued), then drives leg by leg.
    static func run(targetId: String, goal: (x: Double, z: Double, label: String), deps: CoordinatorDependencies,
                    settings: ComeToMeSettings) async throws -> CoordinatorTaskResult {
        try Task.checkCancellation()
        guard let here = deps.legs.position() else { return .blocked(reason: CoordinatorConfig.rescanReason) }
        // Only waypoints valid in the current frame may become legs (the target was checked before submitting).
        let usable = deps.taught.places().filter { $0.inCurrentFrame || deps.frame.relocalized }
        guard usable.contains(where: { $0.id == targetId }) else { return .refused(spoken: CoordinatorConfig.notRecognisedSpoken) }
        let plan = ComeToPlacePlanner.plan(from: here, targetPlaceId: targetId, goal: goal, places: usable,
                                           routes: deps.taught.routes(), settings: settings)
        for leg in plan.legs {
            try Task.checkCancellation()
            let r = try await deps.legs.drive(x: leg.x, z: leg.z, stopDistance: leg.stopDistance)
            guard case .completed = r else { return r }
        }
        try Task.checkCancellation()
        deps.speaker.say(goal.label == ComeToPlaceRunner.userLabel ? "I'm here." : "I'm here, near the \(goal.label).")
        let how = plan.route.map { "route " + $0.joined(separator: " > ") } ?? "direct"
        return .completed(summary: "arrived \(settings.stopShortM) m short via \(how)")
    }

    static let userLabel = "you"
    static let mapMismatchSpoken = "Your phone's map does not match mine, so I can't come to you."
    static let poseOutsideSpoken = "That spot is outside the places I know, so I won't drive there."
}
