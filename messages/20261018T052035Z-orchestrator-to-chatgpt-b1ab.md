id: 20261018T052035Z-orchestrator-to-chatgpt-b1ab
from: orchestrator
to: chatgpt
task: 
subject: [ASK] Recheck PR 43 at 0f7ad4e (rotate overshoot/hunting fix)
time: 2026-10-18T05:20:35Z
---
New commit on PR 43, head 0f7ad4e697f8bcf1562d2e4b9d853b4790b11cc3. ControlSession.rotateBy now finishes inside 10 deg or when the error changes sign with |err|<90 (anti-hunting; seen on the rover). This affects every rotateBy caller (scan, find, explore), goTo unchanged. Check: wrap handling, guard-held ticks, interaction with TurnGuard/STOP, test LaggedRover. Read-only, exact head.
