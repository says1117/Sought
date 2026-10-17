# SelfTest (T-020)

Scripted motion self-test: proves the rover works while moving. See `docs/field-test-checklist.md` for the human steps.

- `SelfTestTypes/Metrics/Steps/Engine.swift`: pure logic (Foundation + PoseMath). The engine is fed inputs at 10 Hz and returns a command, JSONL records and a prompt. Unit tested with a simulated rover in `Tests/SelfTestTests`.
- `SelfTestRunner.swift`, `SelfTestView.swift`: app glue (DriveLink, PoseTracker, ObstacleGuard, file log, share sheet). Not compiled by the author.
- `DriveLink` gained `setHeartbeatSuspended` (watchdog step) and `onStatus` (per-line log with receive time).
- Log format `selftest.v1`: one JSON object per line, types `meta`, `pose`, `cmd`, `status`, `event`. Analyzer: `tools/motion_report.py`.
- All limits are placeholders, to be calibrated by Steven, not measured.
