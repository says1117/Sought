id: T-033
title: Teach fallback: joystick drive, mark waypoints (ARAnchor + SQLite), save/load world map, relocalize
role: ios-drive
size: M
status: review
owner: ios-drive
depends: 
read: docs/01_ROBOTICS_PLAN.md#3.2, #3.1 Teach
created: 2026-10-17T10:26:36Z
doing: 
doing_at: 2026-10-17T11:45:11Z
---
Fallback for Explore. Rescan-needed message if no relocalization in 20 s.

[2026-10-17T11:45:22Z] ios-drive -> review: PR https://github.com/says1117/Sought/pull/27: Teach module (WaypointStore, WorldMapStore, RelocalizationMonitor, TeachView). swift test 235 pass (28 new); iOS Simulator build succeeds. Not run: device, ARKit session, real world-map relocalization. Launch-time map load not wired into RecallApp.
