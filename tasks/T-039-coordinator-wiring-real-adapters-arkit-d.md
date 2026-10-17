id: T-039
title: Coordinator wiring: real adapters (ARKit, DriveLink, Memory, Sync, Speech) and app shell
role: ios-drive
size: M
status: claimed
owner: ios-drive
depends: T-038
read: ios/Recall/Sources/App, docs/01_ROBOTICS_PLAN.md#3.1
created: 2026-10-17T10:26:57Z
doing: adapters + tests written; running swift test then wiring RecallApp
doing_at: 2026-10-17T18:18:52Z
---
Connect the coordinator core to the real modules; find bar as main screen; fallback menu for manual drive and self-test. Needs Xcode and a device to verify.
