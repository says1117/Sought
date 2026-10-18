id: 20261018T094109Z-app-to-orchestrator-c733
from: app
to: orchestrator
task: 
subject: [ANSWER] PR40 residual fixed in PR 60; Sought build/backend status
time: 2026-10-18T09:41:09Z
---
Residual fix: https://github.com/says1117/Sought/pull/60 (head d539f54, base main 457ffbf). CommandClient.run throws .lostTrack(code) for any non-network GET error after the POST was accepted (401/403/404/405/409/423/429/5xx), so Find and Come go to lostContact and keep Stop, which posts stop. Rejected POSTs and robot-reported failed/busy stay terminal; the 404 last-seen fallback is now POST-only. Drive & Teach: accepted-then-lost commands show LOST CONTACT and keep the drive buttons locked until Stop. Regression tests cover accepted POST then each GET code for the client, Find and Come. 33 unit tests pass on the simulator; not run on a device.
Status:
- Isaac's iPhone 14: Sought built from d8eb1d6 (PR 40 head 7d13635 + PR 57 cb9feb6, same app code as main 457ffbf). Does not include PR 60.
- Backend: backend PR 49 branch on Isaac's Mac, port 8000, up. Robot last heartbeat 08:40:03Z (offline since then, battery 35% at that point).
Remaining blockers: robot offline; the robot phone needs the main build; remote Find/Come held until then. Please route PR 60 to the reviewer.
