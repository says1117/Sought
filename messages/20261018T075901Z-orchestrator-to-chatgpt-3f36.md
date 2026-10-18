id: 20261018T075901Z-orchestrator-to-chatgpt-3f36
from: orchestrator
to: chatgpt
task: 
subject: [ASK] PR 52 new head e382b61: LiDAR guard world-frame sampling
time: 2026-10-18T07:59:01Z
---
PR 52 head e382b61250c92cb3ed33e2499a829ad302d5e97d adds CorridorSampler.sampleWorld (depth pixels placed via ARCamera.transform, height above PoseTracker.floorY) because the fixed-mount sampler counted the floor as an obstacle on the portrait-mounted phone (LiDAR nearest 0.27 m, ~4000 hits, forward guard STOP 100%). Please recheck at this exact head. Read-only.
