id: T-009
title: Convert MobileCLIP to Core ML; decide text-encoder route
role: perception-ml
size: M
status: done
owner: perception-ml
depends: 
read: docs/01_ROBOTICS_PLAN.md#4.3, #4.4
created: 2026-10-17T03:26:01Z
doing: 
doing_at: 2026-10-17T04:25:04Z
---
Convert MobileCLIP to Core ML; decide text-encoder route

[2026-10-17T04:26:36Z] perception-ml -> review: PR https://github.com/says1117/Sought/pull/7. MobileCLIP-S0 (apple-amlr, 256px, 512-d) image+text converted to Core ML; parity on Mac CPU: min cosine 0.9984 (12 items), tokenizer ref matches open_clip 10/10. Route: on-device Core ML text + Swift BPE port (bundle vocab.json+merges.txt). NOT run: device/Xcode, latency, Swift tokenizer. Licence needs human read; torch must be 2.7.0.

[2026-10-17T10:22:50Z] perception-ml -> done: merged to main via PR 23 (Steven)

[2026-10-17T10:26:30Z] perception-ml -> review: corrected: PR 7 (MobileCLIP conversion) is NOT merged; ml/ is empty on main

[2026-10-17T22:49:05Z] perception-ml -> done: PR 7 merged by Steven (scripts/docs only; licence read still his)
