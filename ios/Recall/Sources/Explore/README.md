# Explore (T-023)

Frontier exploration logic: `ExploreMap` (grid snapshot), `FrontierDetector`, `ExplorePlanner` (scoring, BFS reachability with
rover-radius inflation, simplified paths), `ScanRoutine` (4 x 90 deg with keyframe hook) and `ExploreSession` (state machine).

Verified only on synthetic grids with a simulated rover that teleports to goals. Not run on a robot or device.
All numbers in `ExploreConfig` / `ScanConfig` are untuned placeholders. App wiring (adapters from Controller,
OccupancyGrid, PoseTracker, Perception, Memory waypoints) is not done here.
