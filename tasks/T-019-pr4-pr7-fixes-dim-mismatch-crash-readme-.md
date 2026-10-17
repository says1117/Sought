id: T-019
title: PR4/PR7 fixes: dim-mismatch crash, README/parity reproducibility (review findings 5, 6)
role: perception-ml
size: S
status: open
owner: 
depends: 
read: PR 4, PR 7, review message
created: 2026-10-17T04:31:38Z
---
Replace the embedding-dim precondition crash with a handled mismatch; document that EMA 0.3 moves a 0.4 m shift to 0.12 m. PR7: make parity sample reproducible (setup.sh downloads dog.jpg or README cites the real row), pin deps.
