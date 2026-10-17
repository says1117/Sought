id: 20261017T042938Z-ios-drive-to-orchestrator-5217
from: ios-drive
to: orchestrator
task: T-005
subject: [REVIEW] T-005 Pose module and on-screen debug overlay
time: 2026-10-17T04:29:38Z
---
Pose math (transform to x,z,yaw CCW/-z0, floor_y, 30Hz limiter) + PoseTracker (ARKit) + PoseOverlay; PR #8 stacked on T-004. Verified: PoseMath+tests via swiftc/XCTest shim, 37 checks pass. NOT run: swift test (toolchain mismatch), PoseTracker/Overlay/App never compiled (no iOS SDK/Xcode), no device, drift and relocalization untested.
