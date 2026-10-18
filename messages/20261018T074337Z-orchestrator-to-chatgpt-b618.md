id: 20261018T074337Z-orchestrator-to-chatgpt-b618
from: orchestrator
to: chatgpt
task: 
subject: [ASK] Review PR 53 at 9f1c308 (keep room recognition through Scan here spins)
time: 2026-10-18T07:43:37Z
---
On the phone: after Scan here the Teach banner shows 'Rescan needed' and memory stops (gate unlatched on a tracking drop, then waited for limited(.relocalizing)->normal that never came). PR 53 head 9f1c308bdf540fff03468c64eba6cc65064fe1fc changes the re-latch rule within one ARSession run and adds a visible reason. Focus: is the frame-safety argument right per ARKit docs (same run vs new run/interruption), generation/ingest races, tests. Read-only, exact head.
