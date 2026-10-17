import Foundation
#if canImport(PoseCore)
import PoseCore
#endif

// ALL NUMBERS ARE PLACEHOLDERS: nothing here has been tuned or run on the rover.
struct ExploreConfig {
    var roverRadiusM: Float = 0.15
    var minClusterM: Double = 0.3
    var minGoalSeparationM: Double = 0.5
    var visitedRadiusM: Double = 1.0
    var visitedPenalty: Double = 3.0
    var sizeBonusPerM: Double = 1.0
    var sizeBonusCapM: Double = 2.0
    /// Goals closer than this to an already scanned stop are not offered again (guarantees progress).
    var visitedExcludeRadiusM: Double = 0.5
    var waypointStopDistanceM: Double = 0.15
    var goalStopDistanceM: Double = 0.1
    var timeCapS: Double = 300
}

struct ExploreGoal {
    var x: Double
    var z: Double
    var score: Double
    var pathLengthM: Double
    var clusterSizeM: Double
    var path: [(x: Double, z: Double)]   // simplified straight-segment waypoints, last = goal
}

enum ExplorePlanner {
    /// Ranked goals, best (lowest score) first, at least `minGoalSeparationM` apart.
    /// score = path distance + visited penalty - size bonus.
    static func rankedGoals(map: ExploreMap, from pose: Pose2D, visited: [(x: Double, z: Double)],
                            excluded: [(x: Double, z: Double)] = [], config: ExploreConfig = ExploreConfig()) -> [ExploreGoal] {
        guard let start = map.cell(x: pose.x, z: pose.z) else { return [] }
        let mask = TraversalMask(map: map, roverRadiusM: config.roverRadiusM)
        let reach = mask.reach(from: start)
        var goals: [ExploreGoal] = []
        for cluster in FrontierDetector.clusters(in: map, minSizeM: config.minClusterM) {
            // Reachable frontier cell nearest the centroid; clusters with none reachable are skipped.
            let reachable = cluster.cells.filter { reach.isReached($0) }
            guard let goalCell = reachable.min(by: {
                sq(map.center($0), cluster.centroid) < sq(map.center($1), cluster.centroid)
            }), let dist = reach.distanceM(to: goalCell) else { continue }
            let g = map.center(goalCell)
            if excluded.contains(where: { hyp($0.x - g.x, $0.z - g.z) < config.minGoalSeparationM }) { continue }
            if visited.contains(where: { hyp($0.x - g.x, $0.z - g.z) < config.visitedExcludeRadiusM }) { continue }
            let penalty = visited.contains(where: { hyp($0.x - g.x, $0.z - g.z) < config.visitedRadiusM }) ? config.visitedPenalty : 0
            let bonus = min(cluster.sizeM, config.sizeBonusCapM) * config.sizeBonusPerM
            goals.append(ExploreGoal(x: g.x, z: g.z, score: dist + penalty - bonus, pathLengthM: dist,
                                     clusterSizeM: cluster.sizeM,
                                     path: simplifiedPath(reach.path(to: goalCell), mask: mask, reach: reach)))
        }
        goals.sort { $0.score < $1.score }
        var chosen: [ExploreGoal] = []
        for g in goals where !chosen.contains(where: { hyp($0.x - g.x, $0.z - g.z) < config.minGoalSeparationM }) {
            chosen.append(g)
        }
        return chosen
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
