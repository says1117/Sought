import XCTest
#if canImport(ExploreCore)
@testable import ExploreCore
#endif
#if canImport(OccupancyGridCore)
@testable import OccupancyGridCore
#endif
#if canImport(PoseCore)
@testable import PoseCore
#endif

// Everything here runs on SYNTHETIC grids with a fake rover that teleports to goals and "senses" by ray casting.
// Nothing is a measurement of a real robot or a real room.

/// Ground-truth world + revealed map + fakes for every ExploreSession protocol.
final class SimWorld: ExploreDrive, ScanHook, ExploreClock, ExplorePoseSource, ExploreGridSource, WaypointSink {
    let truth: ExploreMap
    var known: ExploreMap
    var pose: Pose2D
    var tracking: TrackingKind = .normal
    var senseRadiusM: Float = 1.5
    var reveals = true
    var t = 0.0
    var goToCost = 5.0
    var goToResults: [DriveResult] = []     // consumed front to back; default .reached
    var onGoTo: ((Int) -> Void)?
    var positions: [(x: Double, z: Double)] = []
    var goToCount = 0
    var rotations: [Double] = []
    var captures: [(Int, Int)] = []
    var added: [(name: String, x: Double, z: Double)] = []
    var stopCalls = 0
    var sleeps: [Double] = []

    init(truth: ExploreMap, start: (Double, Double)) {
        self.truth = truth
        known = ExploreMap(width: truth.width, height: truth.height, resolution: truth.resolution,
                           originX: truth.originX, originZ: truth.originZ)
        pose = Pose2D(x: start.0, z: start.1, yawDeg: 0)
        positions.append(start)
    }

    func sense() {
        guard reveals else { return }
        let res = Double(truth.resolution)
        let maxR = Double(senseRadiusM)
        var a = 0.0
        while a < 360 {
            let dx = cos(a * .pi / 180), dz = sin(a * .pi / 180)
            var d = 0.0
            while d <= maxR {
                guard let c = truth.cell(x: pose.x + dx * d, z: pose.z + dz * d) else { break }
                let s = truth.state(c)
                known.set(c, s)
                if s == .occupiedHigh || s == .occupiedLow { break }
                d += res * 0.5
            }
            a += 0.25
        }
    }

    // ExploreDrive
    func goTo(x: Double, z: Double, stopDistance: Double) async -> DriveResult {
        goToCount += 1
        t += goToCost
        onGoTo?(goToCount)
        let r = goToResults.isEmpty ? DriveResult.reached : goToResults.removeFirst()
        if r == .reached {
            pose = Pose2D(x: x, z: z, yawDeg: pose.yawDeg)
            positions.append((x, z))
            sense()
        }
        return r
    }
    func rotateBy(_ deg: Double) async -> DriveResult {
        rotations.append(deg)
        pose.yawDeg = PoseMath.normalizeDegrees(pose.yawDeg + deg)
        return .reached
    }
    func stop() { stopCalls += 1 }
    // ScanHook
    func captureKeyframe(stopIndex: Int, headingIndex: Int) async {
        captures.append((stopIndex, headingIndex))
        sense()
    }
    // ExploreClock
    func now() -> Double { t }
    func sleep(_ seconds: Double) async { t += seconds; sleeps.append(seconds) }
    // ExplorePoseSource
    func latest() -> (pose: Pose2D?, tracking: TrackingKind) { (tracking == .normal ? pose : nil, tracking) }
    // ExploreGridSource
    func currentMap() -> ExploreMap { known }
    // WaypointSink
    func addWaypoint(name: String, x: Double, z: Double, yawDeg: Double) { added.append((name, x, z)) }
}

/// Room of `w` x `h` cells with a 2-cell occupied border, free inside. Origin at (0,0), 5 cm cells.
func makeRoom(w: Int, h: Int, obstacle: (cols: Range<Int>, rows: Range<Int>)? = nil) -> ExploreMap {
    var m = ExploreMap(width: w, height: h, fill: .free)
    for r in 0..<h { for c in 0..<w where r < 2 || c < 2 || r >= h - 2 || c >= w - 2 { m.set(GridCell(col: c, row: r), .occupiedHigh) } }
    if let o = obstacle { for r in o.rows { for c in o.cols { m.set(GridCell(col: c, row: r), .occupiedHigh) } } }
    return m
}

final class ExploreTests: XCTestCase {
    // MARK: pure logic

    func testFrontierCellsAndSmallClusterDropped() {
        var m = ExploreMap(width: 40, height: 40)
        // 10-cell free strip (0.5 m) bordering unknown, and a 3-cell strip (0.15 m) elsewhere.
        for c in 5..<15 { m.set(GridCell(col: c, row: 5), .free) }
        for c in 25..<28 { m.set(GridCell(col: c, row: 30), .free) }
        XCTAssertEqual(FrontierDetector.frontierCells(in: m).count, 13)
        let cl = FrontierDetector.clusters(in: m, minSizeM: 0.3)
        XCTAssertEqual(cl.count, 1)
        XCTAssertEqual(cl[0].cells.count, 10)
        XCTAssertEqual(cl[0].sizeM, 0.5, accuracy: 1e-6)
    }

    func testFullyKnownRoomHasNoFrontier() {
        XCTAssertTrue(FrontierDetector.frontierCells(in: makeRoom(w: 40, h: 40)).isEmpty)
    }

    func testPathIsSimplifiedInOpenSpace() {
        var m = ExploreMap(width: 80, height: 80, fill: .free)
        for c in 10..<60 { m.set(GridCell(col: c, row: 70), .unknown) }   // frontier strip along row 69
        let goals = ExplorePlanner.rankedGoals(map: m, from: Pose2D(x: 0.5, z: 0.5, yawDeg: 0), visited: [])
        XCTAssertFalse(goals.isEmpty)
        XCTAssertLessThanOrEqual(goals[0].path.count, 2, "open space collapses to straight segments")
        let last = goals[0].path.last!
        XCTAssertEqual(last.x, goals[0].x, accuracy: 1e-9)
    }

    func testScoringPrefersNearerAndPenalizesVisited() {
        var m = ExploreMap(width: 120, height: 40, fill: .free)
        // Two equal unknown strips: near (left) and far (right) along the top.
        for c in 5..<25 { m.set(GridCell(col: c, row: 0), .unknown) }
        for c in 90..<110 { m.set(GridCell(col: c, row: 0), .unknown) }
        let me = Pose2D(x: 1.5, z: 1.0, yawDeg: 0)
        var goals = ExplorePlanner.rankedGoals(map: m, from: me, visited: [])
        XCTAssertEqual(goals.count, 2)
        XCTAssertLessThan(goals[0].x, goals[1].x)
        XCTAssertGreaterThanOrEqual(hypot(goals[0].x - goals[1].x, goals[0].z - goals[1].z), 0.5)
        // Visited penalty (inside 1 m but outside the 0.5 m exclusion) pushes the near goal down.
        var cfg = ExploreConfig(); cfg.visitedPenalty = 50
        let nearGoal = goals[0]
        goals = ExplorePlanner.rankedGoals(map: m, from: me, visited: [(nearGoal.x + 0.7, nearGoal.z)], config: cfg)
        XCTAssertEqual(goals.count, 2)
        XCTAssertGreaterThan(goals[0].x, nearGoal.x + 1.0)
    }

    func testGoalsAreAtLeastHalfMeterApart() {
        var m = ExploreMap(width: 120, height: 40, fill: .free)
        for c in 5..<115 { m.set(GridCell(col: c, row: 0), .unknown) }
        // Break the strip into pieces 0.4 m apart so clusters are separate but goals would be close.
        for c in stride(from: 15, to: 115, by: 16) { m.set(GridCell(col: c, row: 0), .free); m.set(GridCell(col: c, row: 1), .free) }
        let goals = ExplorePlanner.rankedGoals(map: m, from: Pose2D(x: 3, z: 1.5, yawDeg: 0), visited: [])
        for i in 0..<goals.count { for j in (i + 1)..<goals.count {
            XCTAssertGreaterThanOrEqual(hypot(goals[i].x - goals[j].x, goals[i].z - goals[j].z), 0.5)
        } }
    }

    func testUnreachableFrontierIsSkipped() {
        // Known room with a wall-sealed free island whose edge borders unknown.
        var m = makeRoom(w: 100, h: 60)
        for r in 20..<30 { for c in 60..<62 { m.set(GridCell(col: c, row: r), .occupiedHigh) } }   // not sealing: placeholder
        // Seal an island: occupied ring around cols 70..90, rows 20..40 with unknown inside strip.
        for r in 18..<44 { for c in 68..<92 { m.set(GridCell(col: c, row: r), .occupiedHigh) } }
        for r in 21..<41 { for c in 71..<89 { m.set(GridCell(col: c, row: r), .free) } }
        for c in 72..<88 { m.set(GridCell(col: c, row: 20 + 1), .unknown) }     // frontier inside the island
        XCTAssertFalse(FrontierDetector.clusters(in: m).isEmpty, "island frontier exists")
        let goals = ExplorePlanner.rankedGoals(map: m, from: Pose2D(x: 1.0, z: 1.5, yawDeg: 0), visited: [])
        XCTAssertTrue(goals.isEmpty, "frontier behind walls is unreachable")
    }

    func testScanRoutineFourQuarterTurnsWithCapture() async {
        let w = SimWorld(truth: makeRoom(w: 60, h: 60), start: (1.5, 1.5))
        let r = await ScanRoutine().run(stopIndex: 3, drive: w, hook: w, clock: w, shouldAbort: { false })
        XCTAssertEqual(r, .reached)
        XCTAssertEqual(w.rotations, [90, 90, 90, 90])
        XCTAssertEqual(w.captures.map { $0.1 }, [0, 1, 2, 3])
        XCTAssertTrue(w.captures.allSatisfy { $0.0 == 3 })
        XCTAssertEqual(w.sleeps.count, 4)
        XCTAssertEqual(w.pose.yawDeg, 0, accuracy: 1e-9)
    }

    // MARK: session on synthetic worlds

    private func session(_ w: SimWorld, config: ExploreConfig = ExploreConfig(), progress: @escaping (ExploreProgress) -> Void = { _ in }) -> ExploreSession {
        ExploreSession(grid: w, drive: w, hook: w, clock: w, poses: w, waypoints: w, config: config, onProgress: progress)
    }

    func testOpenRoomFullyExploredEndsDone() async {
        let w = SimWorld(truth: makeRoom(w: 100, h: 80), start: (2.5, 2.0))    // 5 m x 4 m
        var states: [ExploreProgress] = []
        let rep = await session(w, progress: { states.append($0) }).run()
        XCTAssertEqual(rep.end, .noReachableFrontier)
        XCTAssertGreaterThan(rep.scanStops, 1)
        XCTAssertEqual(states.last, .done)
        XCTAssertEqual(states.first, .exploring)
        XCTAssertEqual(w.added.first?.name, "home")
        XCTAssertEqual(w.added.count, rep.scanStops, "home + one waypoint per later scan stop")
        XCTAssertEqual(w.captures.count, rep.scanStops * 4)
        XCTAssertTrue(FrontierDetector.clusters(in: w.known).isEmpty, "no >=0.3 m frontier left")
        // Nearly all interior floor was seen.
        var seen = 0, total = 0
        for r in 2..<78 { for c in 2..<98 { total += 1; if w.known.state(GridCell(col: c, row: r)) == .free { seen += 1 } } }
        XCTAssertGreaterThan(Double(seen) / Double(total), 0.97)
    }

    func testRoomWithObstacleAvoidsItAndFinishes() async {
        let truth = makeRoom(w: 100, h: 80, obstacle: (cols: 40..<60, rows: 30..<50))   // 1 m block in the middle
        let w = SimWorld(truth: truth, start: (1.0, 1.0))
        let rep = await session(w).run()
        XCTAssertEqual(rep.end, .noReachableFrontier)
        // Every straight leg the fake rover "drove" must stay clear of the real obstacle.
        for (a, b) in zip(w.positions, w.positions.dropFirst()) {
            for i in 0...40 {
                let f = Double(i) / 40
                let c = truth.cell(x: a.x + (b.x - a.x) * f, z: a.z + (b.z - a.z) * f)!
                XCTAssertFalse(truth.isOccupied(c), "leg crossed the obstacle at \(c)")
            }
        }
    }

    func testClosedRoomEndsDone() async {
        // Tiny fully known room: no frontier at all, so exploration ends right after the home scan.
        let w = SimWorld(truth: makeRoom(w: 30, h: 30), start: (0.75, 0.75))
        w.known = makeRoom(w: 30, h: 30)
        w.reveals = false
        let rep = await session(w).run()
        XCTAssertEqual(rep.end, .noReachableFrontier)
        XCTAssertEqual(rep.scanStops, 1)
        XCTAssertEqual(w.goToCount, 0)
        XCTAssertEqual(rep.end.progress, .done)
    }

    func testUnreachableFrontierSkippedInSession() async {
        var m = makeRoom(w: 100, h: 60)
        for r in 18..<44 { for c in 68..<92 { m.set(GridCell(col: c, row: r), .occupiedHigh) } }
        for r in 21..<41 { for c in 71..<89 { m.set(GridCell(col: c, row: r), .free) } }
        for c in 72..<88 { m.set(GridCell(col: c, row: 21), .unknown) }
        let w = SimWorld(truth: m, start: (1.0, 1.5))
        w.known = m; w.reveals = false
        let rep = await session(w).run()
        XCTAssertEqual(rep.end, .noReachableFrontier)
        XCTAssertEqual(w.goToCount, 0)
    }

    func testFailedDriveSkipsGoalAndReportsBlocked() async {
        let w = SimWorld(truth: makeRoom(w: 100, h: 80), start: (2.5, 2.0))
        w.goToResults = [.failed]     // first leg fails once
        var states: [ExploreProgress] = []
        let rep = await session(w, progress: { states.append($0) }).run()
        XCTAssertEqual(rep.skippedGoals, 1)
        XCTAssertTrue(states.contains(.blocked))
        XCTAssertEqual(rep.end, .noReachableFrontier)
    }

    func testFiveMinuteCapEndsExploration() async {
        XCTAssertEqual(ExploreConfig().timeCapS, 300)
        let w = SimWorld(truth: makeRoom(w: 240, h: 240), start: (6.0, 6.0))     // 12 m x 12 m, too big for 5 min here
        w.goToCost = 40
        let rep = await session(w).run()
        XCTAssertEqual(rep.end, .timeCap)
        XCTAssertGreaterThanOrEqual(w.t, 300)
        XCTAssertLessThan(w.t, 300 + 40 + 10)
        XCTAssertGreaterThan(w.stopCalls, 0)
    }

    func testTrackingLossStopsAndReportsBlocked() async {
        let w = SimWorld(truth: makeRoom(w: 100, h: 80), start: (2.5, 2.0))
        w.onGoTo = { n in if n == 2 { w.tracking = .limited } }
        var states: [ExploreProgress] = []
        let rep = await session(w, progress: { states.append($0) }).run()
        XCTAssertEqual(rep.end, .trackingLost)
        XCTAssertEqual(states.last, .blocked)
        XCTAssertEqual(w.goToCount, 2, "no more driving after tracking is lost")
        XCTAssertGreaterThan(w.stopCalls, 0)
    }

    func testControllerReportedTrackingLossEnds() async {
        let w = SimWorld(truth: makeRoom(w: 100, h: 80), start: (2.5, 2.0))
        w.goToResults = [.trackingLost]
        let rep = await session(w).run()
        XCTAssertEqual(rep.end, .trackingLost)
    }

    func testStopRequestWinsOverEverything() async {
        let w = SimWorld(truth: makeRoom(w: 100, h: 80), start: (2.5, 2.0))
        var s: ExploreSession!
        s = session(w)
        w.onGoTo = { n in if n == 1 { s.requestStop(); w.t += 1000; w.tracking = .limited } }   // also past the cap and tracking lost
        let rep = await s.run()
        XCTAssertEqual(rep.end, .stopRequested)
        XCTAssertEqual(rep.end.progress, .done)
        XCTAssertEqual(w.goToCount, 1)
        XCTAssertEqual(w.added.first?.name, "home")
    }

    func testStartingWithoutTrackingReportsBlocked() async {
        let w = SimWorld(truth: makeRoom(w: 60, h: 60), start: (1.5, 1.5))
        w.tracking = .notAvailable
        let rep = await session(w).run()
        XCTAssertEqual(rep.end, .trackingLost)
        XCTAssertTrue(w.added.isEmpty)
        XCTAssertEqual(w.goToCount, 0)
    }
}
