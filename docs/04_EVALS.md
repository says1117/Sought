# Evaluation Protocol

This is what earns the AI track. The judges said depth beats polish and they read the code, so the harness has to be clean and the numbers have to be real. Report small sample sizes honestly (for example "7/10", not "70%"), include failures, and never fill a table with numbers we did not measure.

## 1. Questions we answer

1. **Retrieval:** does open-vocabulary embedding retrieval find objects better than detector labels alone, and which parts of the pipeline matter?
2. **End to end:** does the arrival check improve real find success?
3. **Change detection:** how many injected changes does a patrol catch, and how many false alarms does it raise?
4. **Memory:** does selective update match full re-mapping accuracy with far less storage, and beat a static map after the room changes?
5. (Stretch) Does a robot-height adapter improve retrieval?

## 2. Setup

- **Room:** one real room, about 3 x 4 m, with furniture and normal light. Photograph and describe it in `evals/README.md`.
- **Objects:** 12 to 15 everyday items placed on the floor and low surfaces. At least 5 should not be COCO/YOLO classes (for example slippers, charger, cane, cable, tissue box). Record each item's ground truth position.
- **Ground truth:** use `EvalMode` in the app: tap the floor point under each object to log `(x, z)` in the Teach world frame. Spot-check a few against a tape measure and note the error.
- **Teach run (P0):** one baseline Teach and patrol before any change.
- **Fixed seed and settings:** record app git commit, model versions, thresholds, and phone height in every run file.

## 3. Query set (`evals/queries.yaml`)

30 queries, mixed on purpose:

| Type | Count | Example |
|---|---|---|
| exact class | 8 | "backpack" |
| attribute | 10 | "the grey slippers", "the blue box" |
| descriptive | 8 | "the thing I charge my phone with", "something to drink from" |
| ambiguous | 4 | "the bag" when two bags exist (correct behavior is to rank both and verify) |

Each query lists its `target_object_id` (or two ids for ambiguous ones). Write the queries **before** looking at retrieval results.

## 4. Variants (ablation)

| Variant | Proposals | Ranking | Arrival check |
|---|---|---|---|
| `yolo_labels_only` | YOLO boxes | match query words to class names | no |
| `clip_yolo_proposals` | YOLO boxes | embedding similarity | no |
| `clip_full_proposals` | YOLO + saliency + grid | embedding similarity | no |
| `clip_plus_arrival_check` | full | embedding similarity | yes |
| `clip_plus_gemini_rerank` (opt-in) | full | similarity, then Gemini picks among near ties | yes |
| `clip_plus_adapter` (stretch) | full | adapter-adjusted | yes |

Retrieval metrics are computed offline from stored memory for every variant (no driving). End-to-end metrics are driven on the robot for the best two variants only.

## 5. Metrics

### Retrieval (per variant, over the 30 queries)
- **Top-1 and top-3 accuracy:** the correct track is rank 1 or within the top 3.
- **Position error (cm):** distance between the predicted track position and ground truth, median and max, in the horizontal plane.
- Report by query type.

### End to end (10 trials per variant, targets chosen before the run)
- **Find success:** robot arrives within 0.6 m of the true position **and** its arrival check accepts the right object (or, if it rejects, it moves on to the right one).
- **Time to arrive** and **distance driven**.
- **Near misses:** sonar stop events and depth-guard stops. **Collisions:** any contact (count by observation).
- **False accept:** robot declares success at the wrong object.

### Change detection
Inject 10 scripted changes after P0, one of each kind where possible:
- move a chair 0.5 m, move a box 1 m, remove a bottle, add a shoe, add a box on a route, add a cable, open a door, move an object back to its original place, add something small, add something large.

Run patrol P1. Compare events to the injected list:
- **TP, FP, FN per type**, precision and recall.
- Run **two null patrols** (nothing changed) and count every reported event as a false alarm.
- Record whether `hazard` severity was assigned correctly for items placed near the route.

### Memory (conditions A, B, C)
- **A, static map:** never updates memory after P0.
- **B, full remap each visit:** wipes and rebuilds memory every patrol.
- **C, selective update:** the persistence-based method.
- Run 5 patrols with 3 scripted changes each. After each patrol record: database size on disk, keyframe count, and thumbnail count; after the last patrol, find success for the changed objects (use the 3 most recently moved).
- Expectation to test, not assume: C matches B's find success with less storage and beats A after the room changes.

### Latency and reliability (single table)
- Query to first motion, embedding time per crop, keyframe rate, tracking `.limited` incidents per patrol, BLE disconnects.

## 6. Procedure

1. Teach P0 and annotate ground truth. Commit `ground_truth.json`.
2. Write `queries.yaml`. Commit.
3. Run retrieval for all variants from P0 memory. Save `run_<ts>_retrieval.json`.
4. Run end-to-end trials for the best two variants. Save raw trial logs (candidates, scores, arrival scores, outcome, timestamps).
5. Apply the 10 changes. Patrol P1. Save events. Run two null patrols.
6. Run memory conditions A, B, C for 5 patrols.
7. `python evals/make_tables.py` generates `evals/results.json` (contract section 4) and `evals/results.md`.
8. Write a **failure analysis**: list the failed queries and trials with the reason (embedding confusion, occlusion, bad depth, tracking loss, wrong threshold). Include 3 representative images.
9. Calibrate thresholds (`TAU_IMG`, association similarity, persistence) on a **separate calibration set** (for example the first half of the queries or a second room arrangement), not the final test queries, and say so.

## 7. Raw run file format (`evals/results/run_<timestamp>_<kind>.json`)

```json
{
  "kind": "retrieval | find | patrol | memory",
  "commit": "abc1234",
  "variant": "clip_full_proposals",
  "phone_height": "mast_40cm",
  "thresholds": { "tau_img": 0.8, "assoc_sim": 0.85 },
  "trials": [
    {
      "query_id": "q07",
      "text": "the grey slippers",
      "target": "obj_12",
      "ranked": [ { "track_id": "obj_12", "score": 0.31, "x": 1.1, "z": -2.0 } ],
      "outcome": "success | wrong_object | not_found | aborted",
      "time_s": 41.2,
      "near_misses": 0,
      "notes": ""
    }
  ]
}
```

## 8. Reporting rules

- Every README number links to a run file.
- State what the evals do **not** show: one room, one operator, small n, one lighting condition.
- Tables use `n` and counts. No decimals that imply precision the sample cannot support.
- If a variant loses, say so. A careful negative result reads better than a suspicious clean sweep.
