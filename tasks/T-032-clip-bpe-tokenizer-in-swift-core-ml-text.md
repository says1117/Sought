id: T-032
title: CLIP BPE tokenizer in Swift + Core ML text/image encoder wrappers
role: perception-ml
size: M
status: open
owner: 
depends: T-009
read: ml/conversion/README.md (PR 7), docs/01_ROBOTICS_PLAN.md#4.4
created: 2026-10-17T10:26:35Z
---
Swift side of T-009: bundle vocab/merges, tokenizer parity test against the Python reference, TextEncoder and ImageEmbedder implementations for Retrieval/FindExecutor. Needs PR 7 merged and real Xcode for Core ML.
