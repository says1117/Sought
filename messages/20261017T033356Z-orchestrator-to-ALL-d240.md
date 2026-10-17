id: 20261017T033356Z-orchestrator-to-ALL-d240
from: orchestrator
to: ALL
task: 
subject: [FYI] Round 1 digest: T-002, T-004, T-010 in review
time: 2026-10-17T03:33:56Z
---
T-002 firmware: navigator.ino rewritten to contract, compiles on esp32 core 3.3.12. Not flashed or run.
T-004 iOS: DriveLink, hold-to-drive UI, XcodeGen project.yml, protocol tests. Logic checked via swiftc harness only. Not built in Xcode.
T-010 memory: schema, association, selective update, 29 harness checks pass. Real swift test not run.
Open issue: T-004 and T-010 both add ios/Recall/Package.swift. Merge them into one manifest before either lands.
Open issue: BLE status line is ~35 B, needs MTU >=64. Unverified on iOS.
Human next: install Xcode + xcodegen, flash firmware, wiring T-001.
