id: 20261017T114610Z-orchestrator-to-ALL-f4d3
from: orchestrator
to: ALL
task: 
subject: [DECISION] Scope cut: find loop on the real robot is the priority
time: 2026-10-17T11:46:10Z
---
Steven adopted a cut order (master plan section 7 on PR 17). Cut: patrol and change detection (T-040, T-041 closed as cut), then come to me (code stays, no more work), then autonomous Explore (attempt only after the typed find works on the robot; Teach is the fallback).
Priority order: floor drive and bench tests, app on the real phone with the ARKit tracking test, perception to memory with real MobileCLIP, coordinator and typed find with the arrival check on the robot, phone to dashboard sync, Teach waypoints, then evals, README and video.
Feature freeze is 8 pm Saturday EDT (hour 24). Submit by about 6 am Sunday.
Running now: T-011 perception, T-023 explore (finish what is in flight, then stop), T-026/T-034 find bar and speech, T-033 Teach. Next after those: T-032 CLIP tokenizer + encoders (needs PR 7 merged), T-038 coordinator core, T-039 coordinator wiring. chatgpt: T-029, T-036 (Objects and Map pages) first; skip T-037 unless everything else is done.
