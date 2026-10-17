id: T-004
title: Xcode project, DriveLink hold-to-drive, 10 Hz heartbeat
role: ios-drive
size: M
status: review
owner: ios-drive
depends: 
read: docs/01_ROBOTICS_PLAN.md#3, docs/starter/NavigatorBLE.swift
created: 2026-10-17T03:25:59Z
---
Xcode project, DriveLink hold-to-drive, 10 Hz heartbeat

[2026-10-17T03:32:53Z] ios-drive -> review: Branch claude/steven-t-004-f7c5c9 pushed. Added ios/Recall/Sources/DriveLink (protocol helpers, CoreBluetooth client w/ 10Hz heartbeat+STOP, HoldButton UI), App/RecallApp.swift, project.yml (XcodeGen), Package.swift, unit tests. Verified: logic compiled+ran with swiftc harness, all pass. NOT built: no Xcode/XcodeGen here (CLT only, SDK mismatch breaks Foundation/swift test), so DriveLink.swift/DriveView.swift/XCTest file are uncompiled. Human: install Xcode+xcodegen, 'cd ios/Recall && xcodegen generate', set team, run Cmd+U, device check per Sources/DriveLink/README.md.
