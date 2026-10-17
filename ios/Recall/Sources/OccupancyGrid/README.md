# OccupancyGrid (T-022)

Pure Swift (Foundation + simd, no ARKit). `OccupancyGrid.integrate(DepthFrame)` projects each depth pixel (intrinsics scaled to the depth buffer, camera-to-world transform, `floorY`) into a 5 cm x/z grid and counts hits per band: floor (|h| < 3 cm), low (3 to 40 cm), high (40 cm to 1.8 m). Depth outside 0.2 to 4 m, non-finite depth, points below the floor or overhead, and points outside the grid are ignored. Each cell counts at most one hit per band per frame; occupied needs 3 frames, free needs 2 floor frames. Precedence: high, low, free, unknown. Occupied cells never revert to free (no decay yet).

`snapshot()` exports the contract 2.7 shape (`resolution_m`, `origin`, `width`, `height`, `cells_b64`: 0 free, 1 unknown, 2 occupied_low, 3 occupied_high; row-major, row = z, col = x). `init?(snapshot:)` restores it.

Targets needed (not added here): SwiftPM target `OccupancyGridCore` (path `ios/Recall/Sources/OccupancyGrid`, excluding README.md) and test target `OccupancyGridTests` (path `ios/Recall/Tests/OccupancyGridTests`, depends on `OccupancyGridCore`); in project.yml add the sources dir to the app target and the tests dir to the test target.
