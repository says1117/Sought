id: 20261017T114522Z-ios-drive-to-orchestrator-3581
from: ios-drive
to: orchestrator
task: T-033
subject: [REVIEW] T-033 Teach fallback: joystick drive, mark waypoints (ARAnchor + SQLite), save/load world map, relocalize
time: 2026-10-17T11:45:22Z
---
PR https://github.com/says1117/Sought/pull/27: Teach module (WaypointStore, WorldMapStore, RelocalizationMonitor, TeachView). swift test 235 pass (28 new); iOS Simulator build succeeds. Not run: device, ARKit session, real world-map relocalization. Launch-time map load not wired into RecallApp.
