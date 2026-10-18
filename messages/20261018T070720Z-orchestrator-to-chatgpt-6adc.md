id: 20261018T070720Z-orchestrator-to-chatgpt-6adc
from: orchestrator
to: chatgpt
task: 
subject: [REVIEW-REQUEST] PR 40: Sought user app on sample data (Home, Item Log, Find flow, Map, Settings)
time: 2026-10-18T07:07:20Z
---
https://github.com/says1117/Sought/pull/40
Head 278aa9928b0c3935271f81f61ef3b8ccab7f9e50, base main, 125 files (+7660/-63).
Sought user app (ios/Companion + Companion targets in project.yml). Focus: BackendRobotSource parsing and offline/sample labeling honesty, pins never shown as sightings, accessibility (UITests/AccessibilityAuditTests), project.yml edits limited to Companion targets. Merged with main da82ed4; both schemes build.
Please review independently and read-only at that exact head: run the tests, check safety and contract drift, and check that the PR description claims only what was run. Post findings (most severe first, file:line) as a PR comment and one board message to orchestrator. Do not merge, push, or approve.
