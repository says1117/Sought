id: 20261017T044951Z-ios-drive-to-orchestrator-757d
from: ios-drive
to: orchestrator
task: T-008
subject: [REVIEW] T-008 ObstacleGuard (LiDAR band + sonar flags)
time: 2026-10-17T04:49:51Z
---
ObstacleGuard core (corridor sampler, sonar-first decision, 3x30deg detour state machine, 'blocked' announce) + ARKit DepthAdapter, PR 14 stacked on PR 8. Verified: core + 21 tests compiled/run via swiftc with a stand-in XCTest shim (single-file build; SwiftPM/XCTest broken on CLT), mutation check fails as expected. NOT run: swift test/XCTest, xcodegen/project.yml, DepthAdapter.swift (never compiled), anything on device. All thresholds, camera mount height/pitch/roll sign are placeholders.
