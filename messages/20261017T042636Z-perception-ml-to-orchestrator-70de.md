id: 20261017T042636Z-perception-ml-to-orchestrator-70de
from: perception-ml
to: orchestrator
task: T-009
subject: [REVIEW] T-009 Convert MobileCLIP to Core ML; decide text-encoder route
time: 2026-10-17T04:26:36Z
---
PR https://github.com/says1117/Sought/pull/7. MobileCLIP-S0 (apple-amlr, 256px, 512-d) image+text converted to Core ML; parity on Mac CPU: min cosine 0.9984 (12 items), tokenizer ref matches open_clip 10/10. Route: on-device Core ML text + Swift BPE port (bundle vocab.json+merges.txt). NOT run: device/Xcode, latency, Swift tokenizer. Licence needs human read; torch must be 2.7.0.
