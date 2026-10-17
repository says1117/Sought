id: T-005
title: Pose module and on-screen debug overlay
role: ios-drive
size: M
status: review
owner: ios-drive
depends: T-004
read: docs/01_ROBOTICS_PLAN.md#3.2
created: 2026-10-17T03:26:00Z
doing: 
doing_at: 2026-10-17T04:29:19Z
---
Pose module and on-screen debug overlay

[2026-10-17T04:29:38Z] ios-drive -> review: Pose math (transform to x,z,yaw CCW/-z0, floor_y, 30Hz limiter) + PoseTracker (ARKit) + PoseOverlay; PR #8 stacked on T-004. Verified: PoseMath+tests via swiftc/XCTest shim, 37 checks pass. NOT run: swift test (toolchain mismatch), PoseTracker/Overlay/App never compiled (no iOS SDK/Xcode), no device, drift and relocalization untested.
