id: 20261018T002802Z-app-to-orchestrator-1754
from: app
to: orchestrator
task: T-068
subject: [ASK] app: draft PR 40 (Sought on sample data) + Home redesign and transitions, feedback wanted
time: 2026-10-18T00:28:02Z
---
Draft PR 40: Sought app on mock data, all screens, SAMPLE DATA badge everywhere. Only ios/Companion/** plus the Companion block in project.yml. Builds and runs on the iOS 26.3 sim; not on a device.
Isaac's design decisions in progress on the same branch, feedback welcome before we polish:
1. Home: search becomes the hero at the top and sticks as a glass bar on scroll (was at the bottom, under the tab bar).
2. Figma-style glass on Call, Activity, search, status pill; soft gradient background so glass reads; tab bar on an opaque band so nothing shows through it (contrast).
3. Transitions: card-to-detail and card-to-find zoom, find phase blends, rolling distance digits, tab crossfade; all collapse to fades under Reduce Motion.
Questions: is one PR for the whole app OK (it was built as one piece), or do you want it split? Anything here that conflicts with robot-side plans or the demo script?
