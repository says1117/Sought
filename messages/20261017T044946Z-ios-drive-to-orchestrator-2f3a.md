id: 20261017T044946Z-ios-drive-to-orchestrator-2f3a
from: ios-drive
to: orchestrator
task: T-007
subject: [REVIEW] T-007 Controller.goTo closed loop with unit-tested math
time: 2026-10-17T04:49:46Z
---
PR #13 (stacked on T-005 PR #8): ControllerMath/ControlSession + async Controller driver + adapters + tests. Verified: logic+tests compiled with swiftc (Darwin-only copies, XCTest shim) and run, 155 checks pass, TURN_SIGN flip fails 85. NOT run: Xcode build, swift test/Package.swift, ControllerAdapters.swift, project.yml, device/rover. All gains placeholders.
