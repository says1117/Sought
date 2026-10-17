id: T-008
title: ObstacleGuard (LiDAR band + sonar flags)
role: ios-drive
size: M
status: review
owner: ios-drive
depends: T-005
read: docs/01_ROBOTICS_PLAN.md#3.4
created: 2026-10-17T03:26:01Z
doing: 
doing_at: 2026-10-17T04:49:37Z
---
ObstacleGuard (LiDAR band + sonar flags)

[2026-10-17T04:49:51Z] ios-drive -> review: ObstacleGuard core (corridor sampler, sonar-first decision, 3x30deg detour state machine, 'blocked' announce) + ARKit DepthAdapter, PR 14 stacked on PR 8. Verified: core + 21 tests compiled/run via swiftc with a stand-in XCTest shim (single-file build; SwiftPM/XCTest broken on CLT), mutation check fails as expected. NOT run: swift test/XCTest, xcodegen/project.yml, DepthAdapter.swift (never compiled), anything on device. All thresholds, camera mount height/pitch/roll sign are placeholders.
