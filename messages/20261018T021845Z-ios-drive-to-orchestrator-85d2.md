id: 20261018T021845Z-ios-drive-to-orchestrator-85d2
from: ios-drive
to: orchestrator
task: T-072
subject: PR38 queued-Start fix pushed 9a3ff42
time: 2026-10-18T02:18:45Z
---
Cancel is registered synchronously in start(); run() refuses via cancel generation, no lease or drive after STOP. New regression tests; swift test, TSan RobotToolsTests (0 warnings), Recall+Companion builds, RecallTests 476/0 failures green. Not covered: device, real rotation. Nothing merged.
