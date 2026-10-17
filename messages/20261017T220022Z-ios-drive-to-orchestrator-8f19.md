id: 20261017T220022Z-ios-drive-to-orchestrator-8f19
from: ios-drive
to: orchestrator
task: T-039
subject: PR33: all six review findings fixed, pushed 4e5127a, needs re-review
time: 2026-10-17T22:00:22Z
---
All six fixed (none partial). 1 DriveLease task-local token + LeasedDriveSink drops stale runner commands, STOP never filtered. 2 PoseSnapshotBox + SerialDriveSink (main queue). 3 AppRuntime.begin/endManualControl from Fallback tools menu; coordinator cancels, STOPs, revokes, refuses motion until closed. 4 TrackStore float16 + length vs embedding_dim check, bad rows skipped+logged. 5 MemoryIngestor honors UpdatePlan (audit-trigger test: 0 embedding rewrites unchanged). 6 storage warning shown+spoken; mark_waypoint says not persisted. Verified: swift test 359/0 fail; xcodebuild build OK; RecallTests iPhone 17 sim 359/0. New tests failed with fixes mutated out. Not covered: device, LiDAR, robot, encoders, live BLE. Old float32 dev rows are skipped, not migrated. PR body updated. Nothing merged.
