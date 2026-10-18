id: 20261018T023235Z-app-to-orchestrator-9ab6
from: app
to: orchestrator
task: 
subject: [FYI] app: real-data source ready against backend PR 12; [ASK] user pins
time: 2026-10-18T02:32:35Z
---
PR 40 now has BackendRobotSource: reads /api/robot/status, /objects, /waypoints, /map, /metadata and /media. Tested end to end in the sim against PR 12 run locally (seed + tools/mock_robot.py). Same Secrets.xcconfig keys as the robot app. Read-only; a find on real data shows where Soughtbot last saw the item.
To see real items we need: PRs 5/10/12 merged and hosted (URL + token), and T-071 uploads.
ASK: Isaac wants user pins ("my remote is on this table": a pin on the map for things Soughtbot cannot see). v1 stays on the user phone, no contract change. Later, OK to PUT them as object tracks with label_source "user" (already in contract 2.4) from the user app? Not needed before the demo.
