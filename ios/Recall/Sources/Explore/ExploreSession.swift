import Foundation
#if canImport(PoseCore)
import PoseCore
#endif

/// Heartbeat state (exploring / blocked / done).
enum ExploreProgress: String, Equatable {
    case exploring, blocked, done
}

enum ExploreEnd: Equatable {
    case noReachableFrontier
    case timeCap
    case trackingLost
    case stopRequested
    case driveCancelled

    var progress: ExploreProgress { self == .trackingLost ? .blocked : .done }
}

struct ExploreReport: Equatable {
    var end: ExploreEnd
    var scanStops: Int
    var skippedGoals: Int
}

final class ExploreSession {
    private let grid: ExploreGridSource
    private let drive: ExploreDrive
    private let hook: ScanHook
    private let clock: ExploreClock
    private let poses: ExplorePoseSource
    private let waypoints: WaypointSink
    private let config: ExploreConfig
    private let scan: ScanRoutine
    private let onProgress: (ExploreProgress) -> Void

    private let lock = NSLock()
    private var stopFlag = false
    private(set) var progress: ExploreProgress = .exploring

    init(grid: ExploreGridSource, drive: ExploreDrive, hook: ScanHook, clock: ExploreClock,
         poses: ExplorePoseSource, waypoints: WaypointSink, config: ExploreConfig = ExploreConfig(),
         scan: ScanRoutine = ScanRoutine(), onProgress: @escaping (ExploreProgress) -> Void = { _ in }) {
        self.grid = grid; self.drive = drive; self.hook = hook; self.clock = clock
        self.poses = poses; self.waypoints = waypoints; self.config = config; self.scan = scan
        self.onProgress = onProgress
    }

    /// Wins over everything else: stops the drive immediately and ends at the next check.
    func requestStop() {
        lock.lock(); stopFlag = true; lock.unlock()
        drive.stop()
    }

    private var stopRequested: Bool { lock.lock(); defer { lock.unlock() }; return stopFlag }

    private func report(_ p: ExploreProgress) {
        progress = p
        onProgress(p)
    }

    func run() async -> ExploreReport {
        let started = clock.now()
        var visited: [(x: Double, z: Double)] = []
        var excluded: [(x: Double, z: Double)] = []
        var stops = 0
        var skipped = 0

        func finish(_ end: ExploreEnd) -> ExploreReport {
            drive.stop()
            report(end.progress)
            return ExploreReport(end: end, scanStops: stops, skippedGoals: skipped)
        }
        /// Returns the reason to stop now, in priority order: stop request, tracking loss, time cap.
        func stopReason() -> ExploreEnd? {
            if stopRequested { return .stopRequested }
            if poses.latest().tracking != .normal || poses.latest().pose == nil { return .trackingLost }
            if clock.now() - started >= config.timeCapS { return .timeCap }
            return nil
        }
        func end(for r: DriveResult) -> ExploreEnd? {
            switch r {
            case .trackingLost: return .trackingLost
            case .cancelled: return stopRequested ? .stopRequested : .driveCancelled
            default: return nil
            }
        }

        report(.exploring)
        if let r = stopReason() { return finish(r) }
        guard let home = poses.latest().pose else { return finish(.trackingLost) }
        waypoints.addWaypoint(name: "home", x: home.x, z: home.z, yawDeg: home.yawDeg)

        // Scan at home first so frontier detection has a 360 degree view.
        visited.append((home.x, home.z))
        let first = await scan.run(stopIndex: stops, drive: drive, hook: hook, clock: clock, shouldAbort: { stopRequested })
        stops += 1
        if let e = stopReason() ?? end(for: first) { return finish(e) }

        while true {
            if let r = stopReason() { return finish(r) }
            guard let pose = poses.latest().pose else { return finish(.trackingLost) }
            let goals = ExplorePlanner.rankedGoals(map: grid.currentMap(), from: pose, visited: visited,
                                                   excluded: excluded, config: config)
            guard let goal = goals.first else { return finish(.noReachableFrontier) }

            report(.exploring)
            var arrived = true
            for (i, wp) in goal.path.enumerated() {
                let last = i == goal.path.count - 1
                let r = await drive.goTo(x: wp.x, z: wp.z,
                                         stopDistance: last ? config.goalStopDistanceM : config.waypointStopDistanceM)
                if let e = stopReason() ?? end(for: r) { return finish(e) }
                if r != .reached { arrived = false; break }
            }
            if !arrived {
                // Drive failed (timeout / obstacle): skip this goal, report blocked, and replan.
                excluded.append((goal.x, goal.z))
                skipped += 1
                report(.blocked)
                continue
            }
            guard let at = poses.latest().pose else { return finish(.trackingLost) }
            visited.append((at.x, at.z))
            waypoints.addWaypoint(name: "scan_\(stops)", x: at.x, z: at.z, yawDeg: at.yawDeg)
            let s = await scan.run(stopIndex: stops, drive: drive, hook: hook, clock: clock, shouldAbort: { stopRequested })
            stops += 1
            if let e = stopReason() ?? end(for: s) { return finish(e) }
            if s == .failed { report(.blocked) }
        }
    }
}
