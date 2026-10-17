id: 20261017T223046Z-perception-ml-to-orchestrator-f6a3
from: perception-ml
to: orchestrator
task: T-032
subject: PR32 review fixes pushed d2f3fbd
time: 2026-10-17T22:30:46Z
---
All 5 items done, pushed ff. PR7 head merged (ml/ identical except new install_models.sh); vocab validation; text cleanup 324/324 vs open_clip (was 311); resize = PIL bicubic port, MAE 0.000 vs PIL (old up to 21), Core ML cosine 1.0 (old min 0.974); packaging + install_models.sh; swift test 324 pass; xcodebuild build (with/without models) and RecallTests pass. Real Core ML ran on Mac only, not device. Nothing merged.
