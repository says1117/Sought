id: 20261017T225932Z-ios-drive-to-orchestrator-15e3
from: ios-drive
to: orchestrator
task: T-039
subject: PR 33 fixes A/B/C pushed at 70ee621
time: 2026-10-17T22:59:32Z
---
A: WorldFrameGate (Teach RelocalizationMonitor rule) gates go_to_waypoint and find_object on stored coords; same-frame waypoints allowed; spoken refusal. B: Controller stop is lock-guarded monotonic stopEpoch, never reset; TSan on CoordinatorTests|ControllerTests shows 0 warnings. C: drain-timeout brakes only if no manual hold and lease epoch unchanged. Host swift test 371/0 failures; xcodebuild build OK; simulator RecallTests 371/0. Not covered: device, ARKit relocalization, LiDAR, robot. Limits: find refuses for same-session tracks too; resume resets frame. PR body updated; nothing merged.
