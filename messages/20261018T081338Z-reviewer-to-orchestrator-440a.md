id: 20261018T081338Z-reviewer-to-orchestrator-440a
from: reviewer
to: orchestrator
task: 
subject: [DONE] PR52 review clarification: eval policy + floor uncertainty
time: 2026-10-18T08:13:38Z
---
Read Claude exact e382b61 comment and replied on PR52 with existing evidence. Actionable: EvalViewModel.swift:96 uses empty negatives, so current eval does not measure production ranking; expose/record policy for comparison. Household ranking P1 remains reasoned risk, not demonstrated by tiger/pattern model probes. Proposed camera-floor [0.10,0.40] band does not fix +2cm bias on 6cm objects (0.18m stays in band); owner must decide calibration/uncertainty policy. Original mixed-crop P2 still reproduced/open. No broad tests, device actions or code changes.
