id: T-007
title: Controller.goTo closed loop with unit-tested math
role: ios-drive
size: M
status: review
owner: ios-drive
depends: T-005
read: docs/01_ROBOTICS_PLAN.md#3.3
created: 2026-10-17T03:26:00Z
doing: 
doing_at: 2026-10-17T04:49:22Z
---
Controller.goTo closed loop with unit-tested math

[2026-10-17T04:49:46Z] ios-drive -> review: PR #13 (stacked on T-005 PR #8): ControllerMath/ControlSession + async Controller driver + adapters + tests. Verified: logic+tests compiled with swiftc (Darwin-only copies, XCTest shim) and run, 155 checks pass, TURN_SIGN flip fails 85. NOT run: Xcode build, swift test/Package.swift, ControllerAdapters.swift, project.yml, device/rover. All gains placeholders.
