# Evals
Room description, photos, and setup notes go here. Protocol: docs/04_EVALS.md.
Files: queries.yaml, ground_truth.json, results/run_<ts>_<kind>.json, make_tables.py -> results.json, results.md.

No room or robot measurements have been collected here. `queries.yaml` and
`ground_truth.json` are empty collection templates, not a completed evaluation.
The query template uses JSON syntax (valid YAML); its JSON Schema and the ground
truth schema live in `schemas/`. Ambiguous queries accept multiple target IDs.
Choose and record the protocol's 30 queries before inspecting retrieval results.
Ground truth positions use meters in the Teach world frame. Changes may omit
`from` for added objects or `to` for removed objects. IDs must be unique and query
target IDs must refer to recorded objects; check this when collecting the dataset.

Run `python3 evals/make_tables.py` to write aggregate JSON and Markdown from
`evals/results/run_*.json`. Retrieval `top1`/`top3` are counts out of `n`.
Position error is for the first-ranked prediction against the closest acceptable
target, including incorrect predictions; missing predictions contribute no error
measurement (`pos_err_n` states that denominator). Missing measurement summaries
are null, never fabricated zeros. Find time summarizes all trials with times,
including unsuccessful trials; `time_n` states its denominator. Find success uses
`outcome`, constrained by optional `arrival_dist_m` and `accepted_track_id` when
present. Patrol and memory aggregation await defined raw interfaces and remain
empty with explicit unmeasured notes. Query-type breakdowns, collision counts,
distance driven, false-accept rates, and latency metrics are not implemented.

`fixtures/` contains **SAMPLE synthetic test data**, never real measurements.
Sample-marked logs are rejected by default; a demonstration requires an explicit
separate output folder:

```
python3 evals/make_tables.py --runs evals/fixtures --ground-truth evals/fixtures/ground_truth_SAMPLE.json --allow-sample --output-dir /tmp/recall-sample-evals
python3 -m unittest discover -s evals -p 'test_*.py'
```

Do not cite sample output as robot performance. Real reports must describe the
room, date, operator, lighting, small sample limitations, and link raw sources.
