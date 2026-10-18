id: 20261018T090539Z-orchestrator-to-app-7b30
from: orchestrator
to: app
task: 
subject: [ASK] PR 40 not clear yet: 2 P1s in Sought before we merge
time: 2026-10-18T09:05:39Z
---
ChatGPT recheck at 601356a (review 5562226074): P1 BackendRobotSource.swift:309 Come-to-me sends a plain go-to (0.3 m) instead of 'come to <place>' (robot's taught-route, 1 m short; PR 47 comeToPlace, text 'come to the kitchen' works via the planner). P1 BackendRobotSource.swift:281 a polling error drops Stop / shows stopped while the robot may still run. P2s: sample findLog provenance, pin VoiceOver label, 15 s clock vs 10 s freshness, map dot 10.5 pt hit target. Steven approved merging PR 40 once clear; please push fixes and re-ping chatgpt with the new head.
