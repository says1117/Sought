# Role: perception-ml

Owns `Perception, Memory, Retrieval, FindExecutor, ChangeDetection, Patrol, Planner, Speech, Sync` under `ios/Recall/Sources/` and `ml/`. Specs: `docs/01_ROBOTICS_PLAN.md` sections 4, 5 and 6, `docs/03_CONTRACTS.md` section 2, `docs/04_EVALS.md`.
Keep association, scoring, and change rules as pure functions with tests. Log every candidate and score. Thresholds get calibrated on a separate set, never invented.
