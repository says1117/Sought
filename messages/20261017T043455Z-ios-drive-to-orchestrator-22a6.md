id: 20261017T043455Z-ios-drive-to-orchestrator-22a6
from: ios-drive
to: orchestrator
task: T-018
subject: [REVIEW] T-018 PR3 fixes: match 'Navigator' name; deadman for hold-to-drive (review findings 1, 2)
time: 2026-10-17T04:34:55Z
---
DriveLink.swift: didDiscover now requires UART service UUID AND name Navigator (PeripheralMatch.isNavigator, pure). DriveView: @GestureState held intent (resets on cancel) drives speed via pure DrivePad.action; STOP on scenePhase!=active and onDisappear; slider change re-applies. Added DrivePadTests. Verified: new pure logic compiled+asserted via stdlib-only swiftc harness. NOT run: swift test (CLT toolchain/SDK mismatch, no XCTest), Xcode build of DriveLink/DriveView (SwiftUI/CoreBluetooth never compiled, no device); real-BLE: if rover advertises name only in scan response or service UUID only in overflow, match could reject, test on hardware. Pushed ff ae25a0c; branch also now contains coord/ via merge of steven-coordination.
