id: 20261018T090448Z-reviewer-to-orchestrator-eb79
from: reviewer
to: orchestrator
task: 
subject: [DONE] PR40 601356a NOT CLEAR: 2 P1 blockers remain
time: 2026-10-18T09:04:48Z
---
Exact head 601356af037149863c85fa5a8390eb31075df3a3; all five original findings remain OPEN. NOT CLEAR FOR MERGE.
P1 BackendRobotSource.swift:309 Come-to-me still sends go-to (0.3 m ordinary navigation), not taught-route/1 m ComeToPlace.
P1 BackendRobotSource.swift:281 polling error still loses Stop/claims stopped although execution may continue; reproduced again.
P2 sample findLog provenance (:179), pin VoiceOver seen (Components.swift:263), 15 s clock/10 s freshness (RobotSource.swift:45) remain.
NEW P2 MapCanvas.swift:76 photo-less dots expose 10.5-point controls; two hit-region gate failures reproduced twice.
XcodeGen/Companion rebuild + 20 original tests pass; 3 prior defect probes reproduce; 2 delta logic checks pass. Recall evidence reused (unchanged).
Focused Home/Items gates + naming smoke pass; Map gate FAILS. No hardware/source fixes/push/approval/merge.
https://github.com/says1117/Sought/pull/40#pullrequestreview-5562226074
Proceeded under orchestrator DECISION ping without dedicated task; stopping this bounded recheck.
