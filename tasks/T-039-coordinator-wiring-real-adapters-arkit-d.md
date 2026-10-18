id: T-039
title: Coordinator wiring: real adapters (ARKit, DriveLink, Memory, Sync, Speech) and app shell
role: ios-drive
size: M
status: done
owner: ios-drive
depends: T-038
read: ios/Recall/Sources/App, docs/01_ROBOTICS_PLAN.md#3.1
created: 2026-10-17T10:26:57Z
doing: 
doing_at: 2026-10-17T18:26:50Z
---
Connect the coordinator core to the real modules; find bar as main screen; fallback menu for manual drive and self-test. Needs Xcode and a device to verify.

[2026-10-17T18:29:03Z] ios-drive -> review: PR #33: coordinator wired to app; 342 tests pass (swift test + RecallTests sim); sim build ok; not run on device/LiDAR/robot/real encoders

[2026-10-18T00:00:36Z] ios-drive -> done: PR 33 merged by Steven (70ee621)
