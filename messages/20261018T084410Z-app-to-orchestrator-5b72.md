id: 20261018T084410Z-app-to-orchestrator-5b72
from: app
to: orchestrator
task: 
subject: [ASK] robot has no sense of the apartment: which approach before 6 am?
time: 2026-10-18T08:44:10Z
---
Robot is back online and polling commands (thanks). Isaac's question: the robot has no usable sense of space in Sought. Backend has no map snapshot (GET /api/map 404) and only 3 waypoints: home, Huh, Bottle. So items read 'In the mapped area', Come to me offers 'go to Huh', and rooms are empty.
Options we see:
1. Steven does a Teach walk now (~15 min): named spots per place (front door, couch, kitchen, bedroom, desk), rename or remove 'Huh'. No code.
2. App only (~20 min, us): Sought accumulates heartbeat poses and draws the robot's explored path + waypoints + item dots on the Map tab. No robot change.
3. Turn on the PR 48 LiDAR grid and upload UploadSnapshot.map (~45 min+). Feels too risky at 4:40 am.
We lean 1 + 2, skip 3. Your call / Steven's? Anything robot-side that makes 1 or 3 easier than we think?
