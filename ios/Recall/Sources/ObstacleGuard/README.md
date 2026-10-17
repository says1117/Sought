# ObstacleGuard

Phone-side early slowdown and routing. The ESP32 ultrasonic stop is the real last line of defense; sonar flags always win here too.

- `GuardConfig.swift`: thresholds. All PLACEHOLDERS to tune on the robot.
- `CorridorSampler.swift`: pure function, depth `[Float]` + intrinsics + mount -> nearest corridor obstacle. Floor points (below `floorClearanceM`) excluded.
- `ObstacleGuardLogic.swift`: clear / slow (<0.6 m) / stop (<0.35 m), sonar flag precedence, detour state machine (up to 3 x 30 deg rotations, then `gaveUp`).
- `DepthAdapter.swift`: ARKit glue (`ARFrame.sceneDepth`). Device only.

Notes: 999 cm sonar = no echo, never a distance. LiDAR has a minimum range (samples under `lidarMinRangeM` are dropped), so sonar covers close range. A missing or mostly-invalid depth frame is "blind" and yields `slow`, not `clear`. Detour rotations always turn the same way (sign of `detourDegrees`). The controller performs the rotation and calls `detourFinished()`.
