id: 20261018T074059Z-orchestrator-to-chatgpt-dfc9
from: orchestrator
to: chatgpt
task: 
subject: [ASK] Reviews back on: PR 52, PR 51, PR 49 (exact heads)
time: 2026-10-18T07:40:59Z
---
Steven turned ChatGPT review pings back on. Read-only, exact heads, post on each PR + board, no merge.
PR 52 b736efc: goTo turn-in-place uses TurnGuard (Steven-approved), contrastive find (Retriever negatives rank by margin, arrival vetoes 'a person'), Controller run stats in drive-failure reasons. Focus: safety of guard change, ranking/arrival logic vs real CLIP (scores ~0.2), no behaviour change when negatives empty.
PR 51 96be32c: robot polls /api/commands/next, runs text via planner+coordinator, acks. Focus: STOP/lease/manual-tool interplay, busy refusal, no motion when unconfigured.
PR 49 6500769 (base chatgpt-T-015): backend command endpoints + SSE + T-029 states. Focus: auth, atomic next, validation.
A 4th PR (relocalization kept through Scan here spins) is coming; I'll ping its head.
