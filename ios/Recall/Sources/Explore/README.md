# Explore (T-023, wired in the explore-wire branch)

Frontier exploration: `ExploreMap` (grid snapshot, traversal and clearance masks), `FrontierDetector`, `ExplorePlanner`
(scoring, BFS reachability, T-059 goal inset, simplified paths), `ScanRoutine` (4 x 90 deg) and `ExploreSession`
(state machine with time, distance, tracking and map-freshness stops).

Live wiring, all behind `RecallFeatureFlags.exploreEnabled` (OFF by default):
- `ExploreGridStore`: thread-safe `OccupancyGrid` (10 m square, 5 cm) centred on the first camera position.
- `ExploreDepthFeeder.swift` (app only, ARKit): `ExploreRuntime` copies `ARFrame.sceneDepth` (medium+ confidence) at 2 Hz on
  the main thread and integrates it on a utility queue with `PoseTracker.floorY`. Skips frames while tracking is not
  normal or the floor is unknown, so the map goes stale instead of absorbing bad depth.
- `ExploreRunner.swift` (SwiftPM target `ExploreLive`): the coordinator's `CoordinatorExploring`, driving the coordinator's
  own Controller under its drive lease. Refuses unless tracking is normal and the map is ready; speaks progress.
- `ExplorePreview` + `ExplorePreviewView.swift` (app only): Robot tools > Explore shows the next goal and why, without driving.

T-059: goals are free cells at least `roverRadiusM + goalMarginM` (from `GuardConfig.roverWidthM / 2`, min 0.15 m, plus
`GuardConfig.corridorMarginM`) from every unknown cell, occupied cell and the grid edge. Paths keep `roverRadiusM` from
occupied and unknown cells, except unseen floor within `blindRadiusM` of the start (the camera cannot see the floor right
around the rover; the forward obstacle guard covers it).

Verified only with `swift test` on synthetic grids, fake depth frames and fake drives. Not run on the rover or a device.
All numbers in `ExploreConfig`, `ExploreRunner.Limits`, `ExploreGridStore.Settings` and `ScanConfig` are placeholders.
