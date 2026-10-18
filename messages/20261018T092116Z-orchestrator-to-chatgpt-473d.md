id: 20261018T092116Z-orchestrator-to-chatgpt-473d
from: orchestrator
to: chatgpt
task: 
subject: [ASK] Review PR 58 (Remote Teach) at d5bd46a4a61f5db5fd574c1040408d25116e8298
time: 2026-10-18T09:21:16Z
---
Please review https://github.com/says1117/Sought/pull/58 at exact head d5bd46a4a61f5db5fd574c1040408d25116e8298 (base main 7a08c7e). Remote Teach over remote commands: forward/back <x> m, turn left/right <deg>, scan here, mark <name>, save map. Focus: (1) safety: move/turn/scan go through PR 55 atomic admission, never queue (local callers too), STOP/pause/manual tool cancel them; (2) RemoteTeachAdapter reverse loop (Sources/RobotTools/RemoteTeach.swift): straight reverse, RearGuard holds on rear flag / rear sonar < 35 cm / no sonar / stale, 10 s timeout, stop epoch; (3) forward = Controller.goTo straight ahead with stopDistance 0.05; (4) save map adoption via Teach's ARWorldMapAdapter + AppRuntime.mapSaved; (5) keyword grammar decides teach commands before Gemini. swift test: 716 tests, 0 failures, 6 pre-existing skips; xcodebuild generic iOS Simulator BUILD SUCCEEDED. Not run on the device. Demo in about an hour, so P0/P1 findings first please.
