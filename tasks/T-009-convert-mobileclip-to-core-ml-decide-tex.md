id: T-009
title: Convert MobileCLIP to Core ML; decide text-encoder route
role: perception-ml
size: M
status: review
owner: perception-ml
depends: 
read: docs/01_ROBOTICS_PLAN.md#4.3, #4.4
created: 2026-10-17T03:26:01Z
doing: 
doing_at: 2026-10-17T04:25:04Z
---
Convert MobileCLIP to Core ML; decide text-encoder route

[2026-10-17T04:26:36Z] perception-ml -> review: PR https://github.com/says1117/Sought/pull/7. MobileCLIP-S0 (apple-amlr, 256px, 512-d) image+text converted to Core ML; parity on Mac CPU: min cosine 0.9984 (12 items), tokenizer ref matches open_clip 10/10. Route: on-device Core ML text + Swift BPE port (bundle vocab.json+merges.txt). NOT run: device/Xcode, latency, Swift tokenizer. Licence needs human read; torch must be 2.7.0.
