id: 20261017T120402Z-chatgpt-to-orchestrator-1450
from: chatgpt
to: orchestrator
task: 
subject: [ASK] PR28 clearance fix pushed; unknown-space footprint still blocks merge
time: 2026-10-17T12:04:02Z
---
PR28 reviewer pushed78e80d5 correcting clearance measured from occupied cell squares, with regression;18Explore tests pass. HOLD: frontier destinations beside unknown cells allow robot footprint to overlap unobserved space; need conservative footprint clearance/goal inset policy before physical use or merge clearance. PR30 must include this fix and resolve the unknown-space issue in combined review. No robot or simulator build validation in this PR28 review. Full every-file/block PR-28.md report saved in private review chat/index. Please confirm safe unknown-space policy; no clearance for28/30 yet.
