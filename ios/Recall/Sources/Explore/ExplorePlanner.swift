import Foundation
#if canImport(PoseCore)
import PoseCore
#endif
#if canImport(ObstacleGuardCore)
import ObstacleGuardCore
#endif

// ALL NUMBERS ARE PLACEHOLDERS: nothing here has been tuned or run on the rover. The rover size comes from
// GuardConfig.roverWidthM / corridorMarginM, which are themselves unmeasured placeholders.
struct ExploreConfig {
    /// Half the chassis width, at least 15 cm. Paths keep this far from occupied and unknown cells.
    var roverRadiusM: Float = max(0.15, GuardConfig.roverWidthM / 2)
    /// T-059: extra distance between a goal and unknown/occupied space, on top of `roverRadiusM`.
    var goalMarginM: Float = GuardConfig.corridorMarginM
    /// How far beyond the goal clearance to search back from a frontier for a safe goal cell.
    var goalSearchSlackM: Float = 0.5
    var minClusterM: Double = 0.3
    var minGoalSeparationM: Double = 0.5
    var visitedRadiusM: Double = 1.0
    var visitedPenalty: Double = 3.0
    var sizeBonusPerM: Double = 1.0
    var sizeBonusCapM: Double = 2.0
    /// Goals closer than this to an already scanned stop are not offered again (guarantees progress).
    var visitedExcludeRadiusM: Double = 0.5
    /// A frontier lying entirely this close to a scan stop is the floor right around the rover that the
    /// mounted camera cannot see. It is skipped instead of driving a few centimetres to look at it.
    var blindRadiusM: Double = 0.6
    var waypointStopDistanceM: Double = 0.15
    var goalStopDistanceM: Double = 0.1
    var timeCapS: Double = 300
    /// Total distance the rover may drive in one run (pose-measured, plus the next goal's planned path).
    var maxDistanceM: Double = 15

    /// Minimum distance between a goal and any unknown or occupied cell (T-059).
    var goalClearanceM: Float { roverRadiusM + goalMarginM }
}

struct ExploreGoal {
    var x: Double
    var z: Double
    var score: Double
    var pathLengthM: Double
    var clusterSizeM: Double
    var path: [(x: Double, z: Double)]   // simplified straight-segment waypoints, last = goal
    /// Frontier cell this goal looks at, and the goal's distance back from it.
    var frontierX: Double
    var frontierZ: Double
    var insetM: Double
}

/// Everything one planning pass decided, so the preview can say why there is (or is not) a goal.
struct ExplorePlan {
    var goals: [ExploreGoal] = []
    var clusters = 0
    var skippedVisited = 0
    var skippedUnreachable = 0
    var skippedNoClearance = 0
    var startOutsideMap = false

    /// One sentence for the preview / speech when there is no goal.
    var noGoalReason: String {
        if startOutsideMap { return "The rover is outside the map." }
        if clusters == 0 { return "No frontier: no edge between seen floor and unseen space." }
        var parts: [String] = []
        if skippedNoClearance > 0 { parts.append("\(skippedNoClearance) without room for the rover") }
        if skippedUnreachable > 0 { parts.append("\(skippedUnreachable) not reachable") }
        if skippedVisited > 0 { parts.append("\(skippedVisited) already visited") }
        return "\(clusters) frontier area\(clusters == 1 ? "" : "s"), none usable: " + parts.joined(separator: ", ") + "."
    }
}

enum ExplorePlanner {
    /// Ranked goals, best (lowest score) first, at least `minGoalSeparationM` apart.
    /// score = path distance + visited penalty - size bonus.
    static func rankedGoals(map: ExploreMap, from pose: Pose2D, visited: [(x: Double, z: Double)],
                            excluded: [(x: Double, z: Double)] = [], config: ExploreConfig = ExploreConfig()) -> [ExploreGoal] {
        plan(map: map, from: pose, visited: visited, excluded: excluded, config: config).goals
    }

    static func plan(map: ExploreMap, from pose: Pose2D, visited: [(x: Double, z: Double)],
                     excluded: [(x: Double, z: Double)] = [], config: ExploreConfig = ExploreConfig()) -> ExplorePlan {
        var out = ExplorePlan()
        guard let start = map.cell(x: pose.x, z: pose.z) else { out.startOutsideMap = true; return out }
        // Paths keep the rover radius from occupied AND unknown space; goals keep radius + margin (T-059).
        let mask = TraversalMask(map: map, roverRadiusM: config.roverRadiusM, unknownRadiusM: config.roverRadiusM)
        let reach = mask.reach(from: start, blindRadiusM: Float(config.blindRadiusM))
        let safe = ClearanceMask(map: map, clearanceM: config.goalClearanceM)
        var goals: [ExploreGoal] = []
        let clusters = FrontierDetector.clusters(in: map, minSizeM: config.minClusterM)
        out.clusters = clusters.count
        for cluster in clusters {
            let centers = cluster.cells.map { map.center($0) }
            if visited.contains(where: { v in centers.allSatisfy { hyp($0.x - v.x, $0.z - v.z) <= config.blindRadiusM } }) {
                out.skippedVisited += 1; continue
            }
            switch insetGoal(for: cluster, map: map, safe: safe, reach: reach, config: config) {
            case .noClearance: out.skippedNoClearance += 1; continue
            case .unreachable: out.skippedUnreachable += 1; continue
            case .found(let goalCell, let frontierCell, let inset):
                guard let dist = reach.distanceM(to: goalCell) else { out.skippedUnreachable += 1; continue }
                let g = map.center(goalCell)
                if excluded.contains(where: { hyp($0.x - g.x, $0.z - g.z) < config.minGoalSeparationM }) {
                    out.skippedUnreachable += 1; continue
                }
                if visited.contains(where: { hyp($0.x - g.x, $0.z - g.z) < config.visitedExcludeRadiusM }) {
                    out.skippedVisited += 1; continue
                }
                let penalty = visited.contains(where: { hyp($0.x - g.x, $0.z - g.z) < config.visitedRadiusM }) ? config.visitedPenalty : 0
                let bonus = min(cluster.sizeM, config.sizeBonusCapM) * config.sizeBonusPerM
                let f = map.center(frontierCell)
                goals.append(ExploreGoal(x: g.x, z: g.z, score: dist + penalty - bonus, pathLengthM: dist,
                                         clusterSizeM: cluster.sizeM,
                                         path: simplifiedPath(reach.path(to: goalCell), mask: mask, reach: reach),
                                         frontierX: f.x, frontierZ: f.z, insetM: inset))
            }
        }
        goals.sort { $0.score < $1.score }
        for g in goals where !out.goals.contains(where: { hyp($0.x - g.x, $0.z - g.z) < config.minGoalSeparationM }) {
            out.goals.append(g)
        }
        return out
    }

    enum InsetResult {
        case found(goal: GridCell, frontier: GridCell, insetM: Double)
        case noClearance      // no free cell with full clearance near this frontier
        case unreachable      // such cells exist but the rover cannot get to any of them
    }

    /// T-059: the goal for a frontier is not the frontier cell itself (it touches unknown space) but the nearest
    /// free cell, walking back through seen floor, that is at least `goalClearanceM` from every unknown or
    /// occupied cell and reachable. Ties go to the cell nearest the cluster centroid.
    static func insetGoal(for cluster: FrontierCluster, map: ExploreMap, safe: ClearanceMask, reach: Reach,
                          config: ExploreConfig) -> InsetResult {
        let maxSteps = Int(((config.goalClearanceM + config.goalSearchSlackM) / map.resolution).rounded(.up))
        var seen = Set(cluster.cells)
        var source: [GridCell: GridCell] = [:]
        for c in cluster.cells { source[c] = c }
        var layer = cluster.cells
        var sawSafe = false
        for step in 0...maxSteps {
            var candidates: [GridCell] = []
            for c in layer where safe.isSafe(c) {
                sawSafe = true
                if reach.isReached(c) { candidates.append(c) }
            }
            if let best = candidates.min(by: { sq(map.center($0), cluster.centroid) < sq(map.center($1), cluster.centroid) }) {
                return .found(goal: best, frontier: source[best] ?? best, insetM: Double(step) * Double(map.resolution))
            }
            var next: [GridCell] = []
            for c in layer {
                for (dc, dr) in ExploreMap.neighbors4 {
                    let n = GridCell(col: c.col + dc, row: c.row + dr)
                    guard map.state(n) == .free, !seen.contains(n) else { continue }
                    seen.insert(n); source[n] = source[c]; next.append(n)
                }
            }
            if next.isEmpty { break }
            layer = next
        }
        return sawSafe ? .unreachable : .noClearance
    }

    /// Greedy line-of-sight simplification: keep only the cells where the straight line to the next kept cell breaks.
    /// The first cell (robot position) is dropped; the last is the goal.
    static func simplifiedPath(_ cells: [GridCell], mask: TraversalMask, reach: Reach) -> [(x: Double, z: Double)] {
        guard cells.count > 1 else { return cells.map { mask.map.center($0) } }
        var out: [GridCell] = []
        var anchor = 0
        while anchor < cells.count - 1 {
            var far = cells.count - 1
            while far > anchor + 1 && !mask.lineClear(cells[anchor], cells[far], reach: reach) { far -= 1 }
            out.append(cells[far])
            anchor = far
        }
        return out.map { mask.map.center($0) }
    }

    private static func hyp(_ a: Double, _ b: Double) -> Double { (a * a + b * b).squareRoot() }
    private static func sq(_ a: (x: Double, z: Double), _ b: (x: Double, z: Double)) -> Double {
        (a.x - b.x) * (a.x - b.x) + (a.z - b.z) * (a.z - b.z)
    }
}
