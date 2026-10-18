import XCTest
import simd
#if canImport(ExploreCore)
@testable import ExploreCore
#endif
#if canImport(OccupancyGridCore)
@testable import OccupancyGridCore
#endif
#if canImport(PoseCore)
@testable import PoseCore
#endif
#if canImport(RecallShared)
import RecallShared
#endif

// T-059 goal inset, the blind zone around the rover, the live grid store, the preview and the session's safety
// stops. All SYNTHETIC grids and depth frames; nothing here was measured on the rover.

/// Distance from a point to the nearest point of a cell's square.
private func distToCellSquare(_ p: (x: Double, z: Double), _ c: GridCell, _ m: ExploreMap) -> Double {
    let ctr = m.center(c), h = Double(m.resolution) / 2
    let dx = max(0, abs(p.x - ctr.x) - h), dz = max(0, abs(p.z - ctr.z) - h)
    return (dx * dx + dz * dz).squareRoot()
}

/// Smallest distance from `p` to any unknown or occupied cell (the grid edge counts as unknown).
private func clearance(of p: (x: Double, z: Double), in m: ExploreMap) -> Double {
    var best = Double.infinity
    for r in -1...m.height { for c in -1...m.width {
        let cell = GridCell(col: c, row: r)
        guard m.state(cell) != .free else { continue }
        best = min(best, distToCellSquare(p, cell, m))
    } }
    return best
}

/// Downward-looking camera `h` m above the floor at (x, z): every depth pixel lands on the floor.
private func floorFrame(x: Float, z: Float, h: Float = 1.0) -> DepthFrame {
    // Rotation about x by -90 degrees: camera -z (forward) maps to world -y (down).
    let T = simd_float4x4(columns: (SIMD4(1, 0, 0, 0), SIMD4(0, 0, -1, 0), SIMD4(0, 1, 0, 0), SIMD4(x, h, z, 1)))
    return DepthFrame(depth: [Float](repeating: h, count: 40 * 40), width: 40, height: 40,
                      intrinsics: DepthIntrinsics(fx: 100, fy: 100, cx: 20, cy: 20), cameraToWorld: T, floorY: 0)
}

private final class TestClock { var t = 100.0 }

final class ExploreSafetyTests: XCTestCase {
    // MARK: T-059 inset

    func testGoalIsInsetFromUnknownAndOccupiedByClearance() {
        var m = ExploreMap(width: 80, height: 80, fill: .free)
        for c in 10..<60 { m.set(GridCell(col: c, row: 70), .unknown) }                     // frontier along row 69
        for r in 60..<66 { for c in 30..<34 { m.set(GridCell(col: c, row: r), .occupiedHigh) } }   // box near it
        let cfg = ExploreConfig()
        let plan = ExplorePlanner.plan(map: m, from: Pose2D(x: 0.5, z: 0.5, yawDeg: 0), visited: [], config: cfg)
        XCTAssertFalse(plan.goals.isEmpty)
        for g in plan.goals {
            XCTAssertGreaterThanOrEqual(clearance(of: (g.x, g.z), in: m), Double(cfg.goalClearanceM) - 1e-6)
            XCTAssertEqual(m.state(m.cell(x: g.x, z: g.z)!), .free)
            XCTAssertGreaterThan(g.insetM, 0, "the goal is not the frontier cell itself")
            XCTAssertLessThan(hypot(g.x - g.frontierX, g.z - g.frontierZ), Double(cfg.goalClearanceM + cfg.goalSearchSlackM) + 0.1)
        }
    }

    func testClearanceIsAtLeastRoverRadiusPlusMarginAndUsesGuardConfig() {
        let cfg = ExploreConfig()
        XCTAssertGreaterThanOrEqual(cfg.roverRadiusM, 0.15)
        XCTAssertGreaterThan(cfg.goalMarginM, 0)
        XCTAssertEqual(cfg.goalClearanceM, cfg.roverRadiusM + cfg.goalMarginM, accuracy: 1e-6)
    }

    func testEveryGoalKeepsClearanceOnRandomMaps() {
        var seed: UInt64 = 42
        func rnd(_ n: Int) -> Int { seed = seed &* 6364136223846793005 &+ 1442695040888963407; return Int((seed >> 33) % UInt64(n)) }
        let cfg = ExploreConfig()
        var goalsChecked = 0
        for _ in 0..<12 {
            var m = ExploreMap(width: 60, height: 60, fill: .free)
            for _ in 0..<8 {      // random unknown and occupied blobs
                let s: CellState = rnd(2) == 0 ? .unknown : .occupiedLow
                let c0 = rnd(55), r0 = rnd(55), w = 1 + rnd(10), h = 1 + rnd(10)
                for r in r0..<min(60, r0 + h) { for c in c0..<min(60, c0 + w) { m.set(GridCell(col: c, row: r), s) } }
            }
            for c in 0..<60 { m.set(GridCell(col: c, row: 0), .unknown) }
            for r in 25..<35 { for c in 25..<35 { m.set(GridCell(col: c, row: r), .free) } }   // rover parks here
            for g in ExplorePlanner.rankedGoals(map: m, from: Pose2D(x: 1.5, z: 1.5, yawDeg: 0), visited: [], config: cfg) {
                goalsChecked += 1
                XCTAssertGreaterThanOrEqual(clearance(of: (g.x, g.z), in: m), Double(cfg.goalClearanceM) - 1e-6)
            }
        }
        XCTAssertGreaterThan(goalsChecked, 5, "the property was exercised")
    }

    func testFrontierAtEndOfNarrowCorridorHasNoGoal() {
        // Known room; a 15 cm wide, 1.5 m long corridor leads out of it to unknown space. No room for the rover.
        var m = makeRoom(w: 60, h: 100)
        for r in 0..<2 { for c in 0..<60 { m.set(GridCell(col: c, row: r), .occupiedHigh) } }
        for r in 60..<98 { for c in 2..<58 { m.set(GridCell(col: c, row: r), .occupiedHigh) } }
        for r in 60..<90 { for c in 28..<31 { m.set(GridCell(col: c, row: r), .free) } }        // corridor
        for r in 90..<98 { for c in 20..<40 { m.set(GridCell(col: c, row: r), .unknown) } }     // unknown beyond
        var cfg = ExploreConfig(); cfg.minClusterM = 0.1      // the corridor's 3-cell frontier counts
        let plan = ExplorePlanner.plan(map: m, from: Pose2D(x: 1.5, z: 1.5, yawDeg: 0), visited: [], config: cfg)
        XCTAssertEqual(plan.clusters, 1)
        XCTAssertTrue(plan.goals.isEmpty)
        XCTAssertEqual(plan.skippedNoClearance, 1)
        XCTAssertTrue(plan.noGoalReason.contains("without room"), plan.noGoalReason)
    }

    func testPathsKeepRoverRadiusFromUnknown() {
        var m = ExploreMap(width: 20, height: 20, fill: .free)
        m.set(GridCell(col: 10, row: 10), .unknown)
        let plain = TraversalMask(map: m, roverRadiusM: 0.15)
        let inflated = TraversalMask(map: m, roverRadiusM: 0.15, unknownRadiusM: 0.15)
        XCTAssertTrue(plain.isTraversable(GridCell(col: 11, row: 10)))
        XCTAssertFalse(inflated.isTraversable(GridCell(col: 11, row: 10)))
        XCTAssertFalse(inflated.isTraversable(GridCell(col: 0, row: 5)), "the grid edge counts as unknown")
        XCTAssertTrue(inflated.isTraversable(GridCell(col: 5, row: 5)))
    }

    // MARK: blind zone around the rover

    /// Free footprint, an unseen ring the camera cannot see, seen floor out to 1 m, unknown beyond.
    private func blindRingMap() -> (ExploreMap, Pose2D) {
        var m = ExploreMap(width: 80, height: 80)
        let pose = Pose2D(x: 2.0, z: 2.0, yawDeg: 0)
        for r in 0..<80 { for c in 0..<80 {
            let p = m.center(GridCell(col: c, row: r))
            let d = hypot(p.x - pose.x, p.z - pose.z)
            if d <= 0.15 || (d >= 0.4 && d <= 1.0) { m.set(GridCell(col: c, row: r), .free) }
        } }
        return (m, pose)
    }

    func testBlindRingIsSkippedAndRoverCanLeaveIt() throws {
        let (m, pose) = blindRingMap()
        let plan = ExplorePlanner.plan(map: m, from: pose, visited: [(pose.x, pose.z)])
        XCTAssertGreaterThanOrEqual(plan.skippedVisited, 1, "the ring the camera cannot see is not a goal")
        let g = try XCTUnwrap(plan.goals.first, plan.noGoalReason)
        XCTAssertGreaterThan(hypot(g.x - pose.x, g.z - pose.z), 0.6)
        XCTAssertGreaterThanOrEqual(clearance(of: (g.x, g.z), in: m), Double(ExploreConfig().goalClearanceM) - 1e-6)
    }

    func testBlindZoneEscapeDoesNotPassObstacles() {
        var (m, pose) = blindRingMap()
        // Wall the rover in: an occupied ring inside the blind zone.
        for r in 0..<80 { for c in 0..<80 {
            let p = m.center(GridCell(col: c, row: r))
            let d = hypot(p.x - pose.x, p.z - pose.z)
            if d > 0.25 && d < 0.35 { m.set(GridCell(col: c, row: r), .occupiedHigh) }
        } }
        XCTAssertTrue(ExplorePlanner.plan(map: m, from: pose, visited: [(pose.x, pose.z)]).goals.isEmpty)
    }

    // MARK: session safety stops

    func testDistanceCapEndsRun() async {
        let w = ExploreSimWorld(truth: makeRoom(w: 100, h: 80), start: (2.5, 2.0))
        var cfg = ExploreConfig(); cfg.maxDistanceM = 1.2
        let rep = await ExploreSession(grid: w, drive: w, hook: w, clock: w, poses: w, waypoints: w, config: cfg).run()
        XCTAssertEqual(rep.end, .distanceCap)
        XCTAssertEqual(rep.end.progress, .done)
        var travelled = 0.0
        for (a, b) in zip(w.positions, w.positions.dropFirst()) { travelled += hypot(b.x - a.x, b.z - a.z) }
        XCTAssertLessThanOrEqual(travelled, 1.2 + 1e-6, "never starts a leg that would pass the cap")
        XCTAssertGreaterThan(w.stopCalls, 0)
    }

    func testStaleMapStopsRunAndReportsBlocked() async {
        let w = ExploreSimWorld(truth: makeRoom(w: 100, h: 80), start: (2.5, 2.0))
        w.onGoTo = { n in if n == 1 { w.notReady = "The map stopped updating 3 seconds ago." } }
        var announced: [String] = []
        let s = ExploreSession(grid: w, drive: w, hook: w, clock: w, poses: w, waypoints: w,
                               announce: { announced.append($0) })
        let rep = await s.run()
        XCTAssertEqual(rep.end, .mapNotReady("The map stopped updating 3 seconds ago."))
        XCTAssertEqual(rep.end.progress, .blocked)
        XCTAssertEqual(w.goToCount, 1, "no more driving once the map is stale")
        XCTAssertTrue(announced.contains { $0.hasPrefix("Going to look") })
    }

    func testEmptyMapNeverStartsDriving() async {
        let w = ExploreSimWorld(truth: makeRoom(w: 60, h: 60), start: (1.5, 1.5))
        w.notReady = "The map is empty: no depth frames yet."
        let rep = await ExploreSession(grid: w, drive: w, hook: w, clock: w, poses: w, waypoints: w).run()
        XCTAssertEqual(rep.end, .mapNotReady("The map is empty: no depth frames yet."))
        XCTAssertEqual(w.goToCount, 0)
        XCTAssertTrue(w.rotations.isEmpty, "not even the home scan")
    }

    // MARK: live grid store

    func testGridStoreFillsFromDepthAndGoesStale() {
        let clock = TestClock()
        let store = ExploreGridStore(now: { clock.t })
        XCTAssertNotNil(store.readiness())
        XCTAssertEqual(store.currentMap().width, 1)

        store.integrate(floorFrame(x: 3, z: 5), robot: (3, 5))
        store.integrate(floorFrame(x: 3, z: 5), robot: (3, 5))
        let map = store.currentMap()
        XCTAssertEqual(map.width, 200)
        XCTAssertEqual(Double(map.originX), 3 - 5, accuracy: 1e-4, "grid is centred on the first camera position")
        XCTAssertEqual(map.state(map.cell(x: 3.1, z: 5.1)!), .free)
        XCTAssertEqual(map.state(map.cell(x: 4.5, z: 5)!), .unknown)
        XCTAssertNil(store.readiness())
        XCTAssertEqual(store.stats().frames, 2)

        clock.t += 3
        XCTAssertTrue(store.readiness()?.contains("stopped updating") == true)
        store.reset()
        XCTAssertEqual(store.stats().frames, 0)
        XCTAssertNotNil(store.readiness())
    }

    func testFootprintIsMarkedFreeButObstaclesWin() {
        var g = OccupancyGrid()
        g.markTraversed(x: 0, z: 0, radius: 0.15)
        XCTAssertEqual(g.state(x: 0.02, z: 0.02), .free)
        XCTAssertEqual(g.state(x: 0.3, z: 0), .unknown)
        var snap = g.snapshot()
        var bytes = [UInt8](Data(base64Encoded: snap.cellsB64)!)
        let c = g.cellIndex(x: 0.02, z: 0.02)!
        bytes[c.row * g.width + c.col] = CellState.occupiedLow.rawValue
        snap.cellsB64 = Data(bytes).base64EncodedString()
        var g2 = OccupancyGrid(snapshot: snap)!
        g2.markTraversed(x: 0, z: 0, radius: 0.15)
        XCTAssertEqual(g2.state(x: 0.02, z: 0.02), .occupiedLow)
    }

    // MARK: preview

    func testPreviewExplainsGoalOrWhyNot() {
        var m = ExploreMap(width: 80, height: 80, fill: .free)
        for c in 10..<60 { m.set(GridCell(col: c, row: 70), .unknown) }
        let pose = Pose2D(x: 0.5, z: 0.5, yawDeg: 0)

        let ok = ExplorePreview.make(map: m, pose: pose, tracking: .normal, readiness: nil)
        XCTAssertTrue(ok.ready)
        XCTAssertNotNil(ok.goal)
        XCTAssertTrue(ok.detail.contains { $0.hasPrefix("Why:") })

        XCTAssertEqual(ExplorePreview.make(map: m, pose: nil, tracking: .limited, readiness: nil).title, "Not tracking")
        let stale = ExplorePreview.make(map: m, pose: pose, tracking: .normal, readiness: "The map stopped updating 4 seconds ago.")
        XCTAssertFalse(stale.ready)
        XCTAssertEqual(stale.detail.first, "The map stopped updating 4 seconds ago.")
        let none = ExplorePreview.make(map: makeRoom(w: 40, h: 40), pose: Pose2D(x: 1, z: 1, yawDeg: 0), tracking: .normal, readiness: nil)
        XCTAssertFalse(none.ready)
        XCTAssertTrue(none.detail[0].hasPrefix("No frontier"))
    }

    func testPlanningAFullSizeGridIsQuick() {
        // 10 m x 10 m grid, as the app uses: a 2 m disc of seen floor in a sea of unknown.
        var m = ExploreMap(width: 200, height: 200)
        for r in 60..<140 { for c in 60..<140 where hypot(Double(r - 100), Double(c - 100)) < 40 { m.set(GridCell(col: c, row: r), .free) } }
        let t0 = Date()
        let goals = ExplorePlanner.rankedGoals(map: m, from: Pose2D(x: 5, z: 5, yawDeg: 0), visited: [(5, 5)])
        XCTAssertFalse(goals.isEmpty)
        XCTAssertLessThan(Date().timeIntervalSince(t0), 2.0, "debug build, generous")
    }
}
