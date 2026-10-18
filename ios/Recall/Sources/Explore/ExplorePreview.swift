import Foundation
#if canImport(PoseCore)
import PoseCore
#endif

/// What Explore would do next from here, without driving. Robot tools > Explore shows it so the goal can be
/// sanity-checked before letting the rover move. Same planner and config the real run uses; the current pose
/// counts as already scanned, as it will be after the run's first 360 degree scan.
struct ExplorePreview {
    var ready: Bool
    var title: String
    var detail: [String]
    var goal: ExploreGoal?
    var robot: (x: Double, z: Double)?

    static func make(map: ExploreMap, pose: Pose2D?, tracking: TrackingKind, readiness: String?,
                     config: ExploreConfig = ExploreConfig()) -> ExplorePreview {
        guard tracking == .normal, let pose else {
            return ExplorePreview(ready: false, title: "Not tracking", detail: ["Explore needs normal ARKit tracking."],
                                  goal: nil, robot: nil)
        }
        let here = (x: pose.x, z: pose.z)
        if let why = readiness {
            return ExplorePreview(ready: false, title: "Map not ready", detail: [why], goal: nil, robot: here)
        }
        let plan = ExplorePlanner.plan(map: map, from: pose, visited: [here], config: config)
        let clearance = String(format: "%.2f", config.goalClearanceM)
        guard let g = plan.goals.first else {
            return ExplorePreview(ready: false, title: "No goal", detail: [plan.noGoalReason,
                                  "Goals must be \(clearance) m from unknown or occupied space."], goal: nil, robot: here)
        }
        let dx = g.x - pose.x, dz = g.z - pose.z
        var lines = [
            String(format: "Goal x %.2f, z %.2f: %.2f m straight, %.2f m by path, %d leg%@.",
                   g.x, g.z, (dx * dx + dz * dz).squareRoot(), g.pathLengthM, g.path.count, g.path.count == 1 ? "" : "s"),
            String(format: "Why: nearest open edge (frontier %.1f m wide) at x %.2f, z %.2f; goal set %.2f m back so the rover stays %@ m from unseen space.",
                   g.clusterSizeM, g.frontierX, g.frontierZ, g.insetM, clearance),
        ]
        if plan.goals.count > 1 { lines.append("\(plan.goals.count - 1) other candidate\(plan.goals.count == 2 ? "" : "s").") }
        let skipped = plan.skippedNoClearance + plan.skippedUnreachable + plan.skippedVisited
        if skipped > 0 {
            lines.append("Skipped: \(plan.skippedNoClearance) no room, \(plan.skippedUnreachable) unreachable, \(plan.skippedVisited) already seen.")
        }
        return ExplorePreview(ready: true, title: "Next goal", detail: lines, goal: g, robot: here)
    }
}
