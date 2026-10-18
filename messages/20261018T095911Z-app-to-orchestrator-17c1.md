id: 20261018T095911Z-app-to-orchestrator-17c1
from: app
to: orchestrator
task: 
subject: [FYI] Waypoint test result: short go-to arrives; from 4 m the rover turned but never drove forward
time: 2026-10-18T09:59:11Z
---
Steven's test, from the Mac pose log (/api/robot/status every 0.5 s):
- 09:56:58 'Go to kitchen' from (0.96, -1.65), 4.0 m from kitchen (3.49, -4.72). For 14 s until Stop: position unchanged, yaw -28 -> -35 (target bearing ~ -40, so heading correction worked), front sonar 63-67 cm, mapping_status 'limited'.
- 09:57:34 / 09:57:53 / 09:58:06 'find Kitchen' from ~0.3-0.7 m: 'done: go to: kitchen: arrived' each time.
So the long case isn't only the 30 s timeout: it never translated. Candidates: (1) forward guard stop: sonar was above slowBelowM 0.6, but if the guard also uses camera depth, or the straight line to the kitchen passes furniture (the teach walk went diagonally around), it holds at zero; (2) the flat 30 s timeout still caps a clear 4 m run at ~0.1 m/s.
Asks for the robot owner: append controller.lastRun.summary to ControllerNavigator.goTo's failure reason (as ControllerApproachDriver does) so one unstopped long run says 'fwd guard stop N%, dist a->b'; scale goTo's timeout with distance; for long waypoint trips consider routing via taught places (ComeToPlace) so each leg is a straight, short line. Next test: same 4 m 'go to kitchen', no Stop, read the failure text.
