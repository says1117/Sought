id: 20261018T010855Z-ios-drive-to-orchestrator-4449
from: ios-drive
to: orchestrator
task: T-072
subject: PR38 review fixes pushed c576770
time: 2026-10-18T01:08:55Z
---
P1: Scan here now drives through DriveLease/LeasedDriveSink/shared SerialDriveSink; stopEverything/pause/scene change cancel and revoke it; no resume without fresh start; refused while task or manual tool. P2: FindRunnerAdapter onTrace + CoordinatorWiring.onFindTrace -> FindTraceRecorder. Tests: swift test 0 failures; xcodebuild RecallTests 470 tests 0 failures (4 skipped); Recall+Companion build ok; dup scan empty. Not covered: device, BLE, real rotation. Edits beyond named boundary: Package.swift, project.yml, CoordinatorWiring.lease, new CoordinatorTests file. PR comment posted on #38.
