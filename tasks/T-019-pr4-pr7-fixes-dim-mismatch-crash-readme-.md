id: T-019
title: PR4/PR7 fixes: dim-mismatch crash, README/parity reproducibility (review findings 5, 6)
role: perception-ml
size: S
status: review
owner: perception-ml
depends: 
read: PR 4, PR 7, review message
created: 2026-10-17T04:31:38Z
doing: 
doing_at: 2026-10-17T04:46:29Z
---
Replace the embedding-dim precondition crash with a handled mismatch; document that EMA 0.3 moves a 0.4 m shift to 0.12 m. PR7: make parity sample reproducible (setup.sh downloads dog.jpg or README cites the real row), pin deps.

[2026-10-17T04:48:33Z] perception-ml -> review: A (PR4 597e326): cosine/runningMean return nil on dim mismatch, associate skips such tracks, applyMatch adopts obs embedding; EMA 0.4m->0.12m documented + TODO(Patrol re-anchor); new test. Verified: swiftc typecheck + mini harness only; XCTest/swift test NOT run (SwiftPM broken, no Xcode). B (PR7): setup.sh sha256-verifies 3 images, deps pinned from ml/.venv freeze + requirements.lock.txt, README fixed (dog.jpg is actually the tiger photo, same sha as tiger.jpg). Fresh setup.sh+convert+parity reproduced parity_output.txt exactly. NOT run: export_tokenizer, on-device.
