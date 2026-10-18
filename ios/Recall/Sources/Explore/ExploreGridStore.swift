import Foundation
#if canImport(OccupancyGridCore)
import OccupancyGridCore
#endif

/// Live occupancy grid for Explore, filled from LiDAR depth frames (see ExploreDepthFeeder.swift for the ARKit side).
/// Thread-safe: frames are integrated on a background queue, the planner reads snapshots from the coordinator's task.
///
/// The grid is created on the first frame, centred on the camera, in the current ARKit session frame. If ARKit
/// relocalizes and the world frame jumps, the grid is wrong until `reset()` (Robot tools > Explore > Reset map).
/// ALL NUMBERS ARE PLACEHOLDERS: nothing here has been tuned on the rover.
final class ExploreGridStore: ExploreGridSource {
    struct Settings {
        var sizeM: Float = 10            // square grid side
        var resolution: Float = 0.05
        /// No integrated frame for this long = stale. Frames are skipped while tracking is not normal or the
        /// floor is unknown, so a stale grid also means "not seeing reliably".
        var staleAfterS: Double = 2.0
        /// Fewer free cells than this = empty (not enough floor seen to plan anything).
        var minFreeCells = 40
        /// Floor under the rover marked free each frame (the camera cannot see it). About half the chassis width.
        var footprintClearM: Float = 0.15
    }

    let settings: Settings
    private let now: () -> Double
    private let lock = NSLock()
    private var grid: OccupancyGrid?
    private var lastUpdate: Double?
    private var frames = 0

    init(settings: Settings = Settings(), now: @escaping () -> Double = { ProcessInfo.processInfo.systemUptime }) {
        self.settings = settings
        self.now = now
    }

    struct Stats: Equatable {
        var frames: Int
        var free: Int
        var occupied: Int
        var unknown: Int
        var ageS: Double?
    }

    /// Integrates one frame. `robot` is the rover's x/z (its footprint is marked free); nil skips that step.
    func integrate(_ frame: DepthFrame, robot: (x: Float, z: Float)?) {
        lock.lock(); defer { lock.unlock() }
        if grid == nil {
            var cfg = OccupancyGridConfig()
            let cells = max(1, Int((settings.sizeM / settings.resolution).rounded()))
            cfg.resolution = settings.resolution
            cfg.width = cells; cfg.height = cells
            let cam = frame.cameraToWorld.columns.3
            cfg.originX = cam.x - settings.sizeM / 2
            cfg.originZ = cam.z - settings.sizeM / 2
            grid = OccupancyGrid(config: cfg)
        }
        grid?.integrate(frame)
        if let robot { grid?.markTraversed(x: robot.x, z: robot.z, radius: settings.footprintClearM) }
        frames += 1
        lastUpdate = now()
    }

    func reset() {
        lock.lock(); grid = nil; lastUpdate = nil; frames = 0; lock.unlock()
    }

    func currentMap() -> ExploreMap {
        lock.lock(); defer { lock.unlock() }
        guard let grid else { return ExploreMap(width: 1, height: 1) }
        return ExploreMap(grid: grid)
    }

    func stats() -> Stats {
        let map = currentMap()
        lock.lock(); let f = frames, t = lastUpdate; lock.unlock()
        var free = 0, occ = 0, unk = 0
        for s in map.cells {
            switch s {
            case .free: free += 1
            case .unknown: unk += 1
            case .occupiedLow, .occupiedHigh: occ += 1
            }
        }
        return Stats(frames: f, free: free, occupied: occ, unknown: unk, ageS: t.map { now() - $0 })
    }

    /// nil when the grid is fresh and has enough floor to plan on; otherwise why not, as a short sentence.
    func readiness() -> String? {
        let s = stats()
        guard s.frames > 0, let age = s.ageS else { return "The map is empty: no depth frames yet." }
        if age > settings.staleAfterS {
            return String(format: "The map stopped updating %.0f seconds ago.", age)
        }
        if s.free < settings.minFreeCells { return "The map is nearly empty: not enough floor seen yet." }
        return nil
    }
}
