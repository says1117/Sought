# ObstacleGuard

Phone-side early slowdown and routing. The ESP32 ultrasonic stop is the real last line of defense; sonar flags always win here too.

- `GuardConfig.swift`: thresholds. All PLACEHOLDERS to tune on the robot.
- `CorridorSampler.swift`: pure function, depth `[Float]` + intrinsics + mount -> nearest corridor obstacle. Floor points (below `floorClearanceM`) excluded.
- `ObstacleGuardLogic.swift`: clear / slow (<0.6 m) / stop (<0.35 m), sonar flag precedence, detour state machine (up to 3 x 30 deg rotations, then `gaveUp`).
- `DepthAdapter.swift`: ARKit glue (`ARFrame.sceneDepth`). Device only.

Notes: 999 cm sonar = no echo, never a distance. LiDAR has a minimum range (samples under `lidarMinRangeM` are dropped), so sonar covers close range. A missing or mostly-invalid depth frame is "blind" and yields `slow`, not `clear`. Detour rotations always turn the same way (sign of `detourDegrees`). The controller performs the rotation and calls `detourFinished()`.

Below-minimum-range depth samples do not count as usable measurements when deciding whether a frame is blind. Invalid intrinsics or impossible buffer dimensions also produce a blind result. `ObstacleGuardState` names this module's detour state separately from the controller's input enum, allowing the sources to compile together in the app target.

The guard emits detour events; it does not itself execute rotations. A higher-level coordinator must translate `ObstacleLevel` into the controller's guard input, execute an allowed detour and call `detourFinished()`. A controller configured with its default clear input bypasses this guard. That orchestration and calibration of mount height/pitch/roll require integration and device checks; the module alone is not a demonstrated autonomous obstacle-avoidance system.
