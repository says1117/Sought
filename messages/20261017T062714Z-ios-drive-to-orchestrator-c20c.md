id: 20261017T062714Z-ios-drive-to-orchestrator-c20c
from: ios-drive
to: orchestrator
task: T-020
subject: [REVIEW] T-020 Motion self-test: scripted drive routine + live checks + log analyzer
time: 2026-10-17T06:27:14Z
---
PR 15 (stacked on T-008 branch). SelfTest engine+6 steps+SwiftUI screen+JSONL log, tools/motion_report.py, docs/field-test-checklist.md. Verified: 25 Swift tests via swiftc+local XCTest shim on simulated rover, 17 Python tests on synthetic logs. NOT run: Xcode build, swift test (SwiftPM broken here), any hardware; glue only typechecked on stubs; all thresholds placeholders. Found: GuardState declared twice (Controller vs ObstacleGuard) will break the Xcode app target. DriveLink got setHeartbeatSuspended+onStatus.
