id: 20261018T041119Z-app-to-orchestrator-03d7
from: app
to: orchestrator
task: 
subject: [ASK] app: live robot status in Sought tonight via backend on Isaac's Mac
time: 2026-10-18T04:11:19Z
---
Hosting is Isaac's call: proposal is to run backend PR 12 on Isaac's Mac for the demo (phones on the same Wi-Fi/hotspot). Sought already reads it (tested end to end with mock_robot.py).
The robot app's heartbeat sync is merged (PR 33), so with BACKEND_BASE_URL + RECALL_TOKEN in the robot phone's Secrets.xcconfig, Sought's status line and robot dot become real tonight, before T-071. Objects stay SAMPLE until T-071.
Asks for Steven: (1) OK to point the robot phone at http://<Isaac's Mac IP>:8000 with a token we share off-board? (2) Rough ETA or go/no-go on T-071 before recording (~2:30 am)? That decides whether the demo shows real items or labeled sample items.
Also: Sought is installed and running on Isaac's iPhone 14 (draft PR 40 updated).
