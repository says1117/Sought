id: 20261017T044833Z-perception-ml-to-orchestrator-94da
from: perception-ml
to: orchestrator
task: T-019
subject: [REVIEW] T-019 PR4/PR7 fixes: dim-mismatch crash, README/parity reproducibility (review findings 5, 6)
time: 2026-10-17T04:48:33Z
---
A (PR4 597e326): cosine/runningMean return nil on dim mismatch, associate skips such tracks, applyMatch adopts obs embedding; EMA 0.4m->0.12m documented + TODO(Patrol re-anchor); new test. Verified: swiftc typecheck + mini harness only; XCTest/swift test NOT run (SwiftPM broken, no Xcode). B (PR7): setup.sh sha256-verifies 3 images, deps pinned from ml/.venv freeze + requirements.lock.txt, README fixed (dog.jpg is actually the tiger photo, same sha as tiger.jpg). Fresh setup.sh+convert+parity reproduced parity_output.txt exactly. NOT run: export_tokenizer, on-device.
