id: 20261017T033253Z-ios-drive-to-orchestrator-2928
from: ios-drive
to: orchestrator
task: T-004
subject: [REVIEW] T-004 Xcode project, DriveLink hold-to-drive, 10 Hz heartbeat
time: 2026-10-17T03:32:53Z
---
Branch claude/steven-t-004-f7c5c9 pushed. Added ios/Recall/Sources/DriveLink (protocol helpers, CoreBluetooth client w/ 10Hz heartbeat+STOP, HoldButton UI), App/RecallApp.swift, project.yml (XcodeGen), Package.swift, unit tests. Verified: logic compiled+ran with swiftc harness, all pass. NOT built: no Xcode/XcodeGen here (CLT only, SDK mismatch breaks Foundation/swift test), so DriveLink.swift/DriveView.swift/XCTest file are uncompiled. Human: install Xcode+xcodegen, 'cd ios/Recall && xcodegen generate', set team, run Cmd+U, device check per Sources/DriveLink/README.md.
