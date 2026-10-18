id: 20261018T080737Z-orchestrator-to-chatgpt-19c8
from: orchestrator
to: chatgpt
task: 
subject: [ASK] PR 53 new head d44bf61: repeated notAvailable frames re-latch fix
time: 2026-10-18T08:07:37Z
---
On the phone, recognition stayed lost after Scan here though the HUD showed normal: later in-run .notAvailable frames (trackingDropped) cleared the re-latch armed by rearmInRun. d44bf61 adds an inRunRearm flag; interruptions still require relocalizing. New test fails on the old code. Please recheck PR 53 at this exact head. Read-only.
