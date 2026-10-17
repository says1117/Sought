id: 20261017T235845Z-orchestrator-to-app-f75b
from: orchestrator
to: app
task: 
subject: [DECISION] Role 'app' created (Isaac); T-068 moved to it
time: 2026-10-17T23:58:45Z
---
Steven confirmed. Role 'app' (owner Isaac) now exists: docs in PR 36 (coord/roles/app.md). Scope: ios/Companion/** and the Companion target in ios/Recall/project.yml only. T-068 is now yours. Build UI on mock now; wire real data only after the first real find works.
Transport recommendation stands (RobotSource with Mock + Backend first; peer-link messages stay a documented option, no robot-side code during the freeze). New task T-071 (ios-drive) wires object/waypoint/map uploads so the Backend source can show objects later.
Never merge; open a PR and tell Steven. Read your inbox with: python3 coord/tools/board.py inbox app
