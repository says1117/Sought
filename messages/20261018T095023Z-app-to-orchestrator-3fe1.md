id: 20261018T095023Z-app-to-orchestrator-3fe1
from: app
to: orchestrator
task: 
subject: [FYI] Why 'go to kitchen' fails: likely the 30 s go-to timeout vs ~0.1 m/s (robot side, not backend)
time: 2026-10-18T09:50:23Z
---
Steven asked us to look at waypoint finding. Read-only findings from the backend command log on Isaac's Mac:
- Name resolution works. 'mark kitchen' at 09:42:19 saved wpt kitchen (3.49, -4.72). The planner resolved 'find kitchen' -> 'go to: kitchen' and 'come to the kitchen' -> 'come to: kitchen'. Both were ended by Stop after ~20-25 s ('stop: cancelled ...'). The backend only stores and relays; nothing there decides navigation.
- The waypoint looks right: the completed teach moves dead-reckon to ~4.1 m from the start, and kitchen is ~4.6 m from the 08:40 pose. The robot now reports (0.97, -1.66), ~4 m from kitchen.
- Likely cause: ControllerTuning.timeout = 30 s (ControllerMath.swift) for every goTo. Remote 'forward 1.0 m' took ~11 s per command, so ~0.1 m/s; 4 m plus turning needs more than 30 s. Expect 'I couldn't get there in time' if not stopped by hand.
- Diagnostics gap: ControllerNavigator.goTo (CoordinatorAdapters.swift:93) drops controller.lastRun.summary, unlike ControllerApproachDriver, so a waypoint timeout doesn't say dist start->closest, guard-stop % or turning %.
Suggested robot-side fix (owner's call): scale the goTo timeout with distance (e.g. 15 s + 12 s/m) or fail on no progress for N s instead of a flat 30 s; append lastRun.summary to the go-to timeout reason.
Quick test without code changes: send 'find kitchen' from ~1.5 m away and don't press Stop; then from 4 m. I'm logging /api/robot/status every 0.5 s on the Mac to capture the path of the next attempt.
App bug on our side: typing 'Go to the kitchen' in Sought's search sent 'find Go to the kitchen'. I'll pass go to / come to phrases through unchanged.
