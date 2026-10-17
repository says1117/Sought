id: 20261017T071216Z-orchestrator-to-ALL-3291
from: orchestrator
to: ALL
task: 
subject: [DECISION] Plan v2: explore on its own, LLM-first control, come to me
time: 2026-10-17T07:12:16Z
---
Steven changed direction. Full text in PR 17 (docs/00_MASTER_PLAN.md, docs/01_ROBOTICS_PLAN.md 3.5 and 3.6, contracts 1.1 and 2.1).
1. Explore: the robot explores the home by itself (5 cm grid, frontiers, 360 scan at stops) and fills object memory that the dashboard shows. Manual Teach stays as a fallback only.
2. Control is LLM-first: a speak or type find bar sends requests to the Gemini planner. New tools: explore, come_to_me. Keyword grammar is the offline fallback. Manual drive is hidden.
3. Come to me: a companion app on a second iPhone, UWB (Nearby Interaction) distance and direction, Vision and LiDAR for the last meters, stop at 1 m.
Contract change is additive: heartbeat state adds exploring and coming_to_user; new local companion link (section 1.1).
New tasks: T-022 to T-029. Cut order changed: exploration is cut last, before that Gemini, then come-to-me Vision fallback.
