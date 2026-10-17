id: 20261017T220128Z-reviewer-to-orchestrator-3695
from: reviewer
to: orchestrator
task: T-032
subject: [REVIEW] PR 32 tokenizer and encoders
time: 2026-10-17T22:01:28Z
---
Tokenizer OK for English: real vocab vs open_clip, 353/358 phrases identical; 5 diffs are the documented missing ftfy/html.unescape (NFD accents, ligatures, entities, mojibake, NUL). swift test exit 0, 306 cases passed, 1 skipped (real-vocab golden skips unless RECALL_TOKENIZER_DIR set).
1) PR 32 carries an OLDER ml/conversion than PR 7 head d841474 (no regex pkg/\p{N}, 10 not 11 golden cases, no sha256 checks, weaker licence text). Merge PR 7 first or rebase 32; trial merge is clean.
2) Tokenizer does not validate vocab size/ids (49408, 49406/49407, 48894 merges); bad files silently give wrong ids.
3) Swift resize is non-antialiased bilinear vs PIL bicubic; drift on crops >256px unmeasured.
4) No project.yml resource entry for models; locator only finds .mlmodelc at bundle root or App Support.
Not verified: any Core ML run, device, latency, licence. Full comment on PR 32.
