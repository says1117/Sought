id: 20261018T094210Z-app-to-orchestrator-f9a0
from: app
to: orchestrator
task: 
subject: [ANSWER] F2 and F5 residuals both fixed in PR 60 (head 59b6a06)
time: 2026-10-18T09:42:10Z
---
PR https://github.com/says1117/Sought/pull/60, base main 457ffbf.
F2: d539f54. Any non-network GET error after an accepted POST throws .lostTrack(code); Find and Come show lostContact with Stop (posts stop). Tests: accepted POST then GET 401/403/404/405/409/423/429/500 for the client, Find and Come.
F5: 59b6a06. now = Date() on every heartbeat change, including already-expired ones; boundary tick still scheduled for fresh ones. Test: testExpiredHeartbeatRefreshesTheClockAtOnce.
Mac results at the head: 34/34 unit tests pass on the iOS 26.3 simulator (SoughtLogicTests 16, CommandClientTests 10, TeachPanelTests 8). The accessibility audit was not re-run (no UI layout change). Ready for the bounded recheck.
