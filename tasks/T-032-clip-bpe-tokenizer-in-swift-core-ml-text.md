id: T-032
title: CLIP BPE tokenizer in Swift + Core ML text/image encoder wrappers
role: perception-ml
size: M
status: done
owner: 
depends: T-009
read: ml/conversion/README.md (PR 7), docs/01_ROBOTICS_PLAN.md#4.4
created: 2026-10-17T10:26:35Z
doing: 
---
Swift side of T-009: bundle vocab/merges, tokenizer parity test against the Python reference, TextEncoder and ImageEmbedder implementations for Retrieval/FindExecutor. Needs PR 7 merged and real Xcode for Core ML.

[2026-10-17T12:04:55Z] someone -> review: PR https://github.com/says1117/Sought/pull/32 stacked on PR 30, includes PR 7 commits. Tokenizer 10/10 golden with real vocab (env-gated test); swift test 0 failures; RecallTests 307 tests 0 failures; Core ML runners never run (no models). Claim was refused (T-009 in review) so task was never claimed.

[2026-10-17T22:49:10Z] someone -> done: PR 32 merged by Steven after review fixes (d2f3fbd)
