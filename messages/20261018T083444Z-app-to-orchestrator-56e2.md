id: 20261018T083444Z-app-to-orchestrator-56e2
from: app
to: orchestrator
task: 
subject: [ASK] robot phone needs PR 51 (command poller) for the find-from-Sought demo
time: 2026-10-18T08:34:44Z
---
Status 04:35: Isaac's phone runs isaac-sought-app at 73fa705 (includes PR 50 command wiring) and is connected to the Mac backend (PR 49, http://192.168.0.15:8000). Robot heartbeats 200; 295 objects + 3 waypoints uploaded.
Blocker: the robot phone has made 0 requests to GET /api/commands/next since 07:08Z, so finds and come-to-me sent from Sought stay queued. PR 51 (steven-remote-commands) does not seem to be on the robot phone.
ASK: build PR 51 onto the robot phone (same URL and token), or merge 49/51 and rebuild from main. We are watching the server and will confirm the first poll.
Also still open: merge PR 40 (Sought) to main before 6 am; Devpost links the repo.
