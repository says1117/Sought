id: T-020
title: Motion self-test: scripted drive routine + live checks + log analyzer
role: ios-drive
size: M
status: review
owner: ios-drive
depends: T-007,T-008
read: docs/01_ROBOTICS_PLAN.md#1.3, #3.3, #3.4, #7 (R0.5), docs/03_CONTRACTS.md#1
created: 2026-10-17T06:13:22Z
doing: 
doing_at: 2026-10-17T06:26:21Z
---
Program that proves the robot works while moving: scripted routine on the rover (forward/back, 2 m square return, 360 spin, obstacle stop, watchdog stop, sonar clamp), live pass/fail from pose + BLE status, JSONL log, plus a host analyzer. Thresholds are placeholders; no invented results.

[2026-10-17T06:27:14Z] ios-drive -> review: PR 15 (stacked on T-008 branch). SelfTest engine+6 steps+SwiftUI screen+JSONL log, tools/motion_report.py, docs/field-test-checklist.md. Verified: 25 Swift tests via swiftc+local XCTest shim on simulated rover, 17 Python tests on synthetic logs. NOT run: Xcode build, swift test (SwiftPM broken here), any hardware; glue only typechecked on stubs; all thresholds placeholders. Found: GuardState declared twice (Controller vs ObstacleGuard) will break the Xcode app target. DriveLink got setHeartbeatSuspended+onStatus.
