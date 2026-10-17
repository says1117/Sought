id: T-020
title: Motion self-test: scripted drive routine + live checks + log analyzer
role: ios-drive
size: M
status: claimed
owner: ios-drive
depends: T-007,T-008
read: docs/01_ROBOTICS_PLAN.md#1.3, #3.3, #3.4, #7 (R0.5), docs/03_CONTRACTS.md#1
created: 2026-10-17T06:13:22Z
doing: reading plan and DriveLink/Pose/Controller APIs
doing_at: 2026-10-17T06:13:49Z
---
Program that proves the robot works while moving: scripted routine on the rover (forward/back, 2 m square return, 360 spin, obstacle stop, watchdog stop, sonar clamp), live pass/fail from pose + BLE status, JSONL log, plus a host analyzer. Thresholds are placeholders; no invented results.
