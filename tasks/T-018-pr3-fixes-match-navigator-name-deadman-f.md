id: T-018
title: PR3 fixes: match 'Navigator' name; deadman for hold-to-drive (review findings 1, 2)
role: ios-drive
size: S
status: review
owner: ios-drive
depends: 
read: ios/Recall/Sources/DriveLink/DriveLink.swift:62, DriveView.swift:46, PR 3
created: 2026-10-17T04:31:38Z
doing: 
doing_at: 2026-10-17T04:32:46Z
---
1) Connect only to a peripheral advertising the Nordic UART service AND named Navigator. 2) Hold-to-drive must send STOP if the gesture is cancelled: use @GestureState (resets on cancel) or a deadman, so a cancelled touch can never leave the last speed in the 10 Hz heartbeat. Add a pure-logic test for the deadman where possible. Push to claude/steven-t-004-f7c5c9 as a fast-forward.

[2026-10-17T04:34:55Z] ios-drive -> review: DriveLink.swift: didDiscover now requires UART service UUID AND name Navigator (PeripheralMatch.isNavigator, pure). DriveView: @GestureState held intent (resets on cancel) drives speed via pure DrivePad.action; STOP on scenePhase!=active and onDisappear; slider change re-applies. Added DrivePadTests. Verified: new pure logic compiled+asserted via stdlib-only swiftc harness. NOT run: swift test (CLT toolchain/SDK mismatch, no XCTest), Xcode build of DriveLink/DriveView (SwiftUI/CoreBluetooth never compiled, no device); real-BLE: if rover advertises name only in scan response or service UUID only in overflow, match could reject, test on hardware. Pushed ff ae25a0c; branch also now contains coord/ via merge of steven-coordination.
