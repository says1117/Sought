# Pose (T-005)

- `PoseMath.swift`: pure math (camera transform to x, z, yaw_deg; floor_y from planes; 30 Hz rate limiter). No ARKit. Unit tests in `Tests/PoseTests`.
- `PoseTracker.swift`: ARKit session wrapper (`ARWorldTrackingConfiguration`, sceneDepth + smoothedSceneDepth, horizontal planes, optional `initialWorldMap`). Publishes pose, tracking, mapping, `floorY`.
- `PoseOverlay.swift`: debug HUD, shown top right in `RecallApp`.

Frame: ARKit world, meters, y up. Forward is -z of the camera transform. Yaw is degrees, CCW positive from above, 0 deg = -z. Heading is camera forward projected onto the horizontal plane; if the phone looks nearly straight up or down it falls back to the phone's up axis.

Known gaps: `start()` after returning to foreground restarts the config without `resetTracking`, so ARKit resumes the same world; relocalization against a saved map is only plumbed through `initialWorldMap`, not exercised. Timeout "Rescan needed" UI (plan 3.2) belongs to Teach.
