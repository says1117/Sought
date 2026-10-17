"""Aggregate measured retrieval/find logs; never substitute sample measurements."""
import argparse
import json
import math
from collections import defaultdict
from datetime import datetime, timezone
from pathlib import Path
from statistics import median


def number(value):
    if isinstance(value, bool) or not isinstance(value, (int, float)) or not math.isfinite(value):
        raise ValueError(f"Expected finite numeric measurement, got {value!r}")
    return value


def retrieval_metrics(trials, positions):
    top1 = top3 = 0
    errors = []
    for trial in trials:
        targets = trial['target']
        targets = targets if isinstance(targets, list) else [targets]
        ranked = trial['ranked']
        top1 += bool(ranked and ranked[0]['track_id'] in targets)
        top3 += any(r['track_id'] in targets for r in ranked[:3])
        if ranked:
            candidates = [positions[t] for t in targets if t in positions]
            if len(candidates) != len(targets):
                raise ValueError('Missing target ground truth')
            if candidates:
                errors.append(min(math.hypot(number(ranked[0]['x']) - number(p['x']),
                                             number(ranked[0]['z']) - number(p['z'])) * 100
                                  for p in candidates))
    return dict(n=len(trials), top1=top1, top3=top3, pos_err_n=len(errors),
               pos_err_cm_median=median(errors) if errors else None,
               pos_err_cm_max=max(errors) if errors else None)


def aggregate(paths, ground_truth, allow_sample=False, queries=None):
    positions = {o['id']: o for o in ground_truth['objects']}
    groups = defaultdict(list)
    sample = bool(ground_truth.get('sample'))
    if sample and not allow_sample:
        raise ValueError('SAMPLE ground truth refused')
    query_types = {q['id']: q['type'] for q in (queries or [])}
    if any(t not in ('exact', 'attribute', 'descriptive', 'ambiguous') for t in query_types.values()):
        raise ValueError('Invalid query type')
    sources = []
    for path in sorted(paths):
        run = json.loads(Path(path).read_text())
        if run.get('sample'):
            if not allow_sample:
                raise ValueError(f"SAMPLE fixture refused: {path}")
            sample = True
        kind = run['kind']
        if kind not in ('retrieval', 'find'):
            raise ValueError(f"Unsupported raw kind {kind!r}; patrol/memory not yet measured")
        sources.append(str(path))
        groups[kind, run['variant']].extend(run['trials'])
    output = dict(generated_at=datetime.now(timezone.utc).isoformat(), retrieval=[],
                  find_end_to_end=[], change_detection=[], memory=[],
                  notes=('SAMPLE — synthetic test data. ' if sample else '') +
                  'Change detection and memory: not yet measured. Find outcomes are authoritative; '
                  'optional arrival distance and accepted track constrain success when present. '
                  'No collision, distance-driven, or latency measurements inferred.', sources=sources)
    for (kind, variant), trials in sorted(groups.items()):
        if not trials:
            continue
        row = dict(variant=variant, n=len(trials))
        if kind == 'retrieval':
            row.update(retrieval_metrics(trials, positions))
            typed = defaultdict(list)
            for trial in trials:
                typed[query_types.get(trial['query_id'], 'unknown')].append(trial)
            row['by_query_type'] = []
            for query_type, subset in sorted(typed.items()):
                # Reuse precisely the overall metric calculation for each denominator.
                with_type = retrieval_metrics(subset, positions)
                row['by_query_type'].append(dict(type=query_type, **with_type))
            output['retrieval'].append(row)
        else:
            successes = 0
            times = []
            misses = 0
            for trial in trials:
                if trial['outcome'] not in ('success', 'wrong_object', 'not_found', 'aborted'):
                    raise ValueError('Invalid find outcome')
                success = trial['outcome'] == 'success'
                if 'arrival_dist_m' in trial:
                    success &= 0 <= number(trial['arrival_dist_m']) <= 0.6
                if 'accepted_track_id' in trial:
                    targets = trial['target']
                    targets = targets if isinstance(targets, list) else [targets]
                    success &= trial['accepted_track_id'] in targets
                successes += success
                if 'time_s' in trial:
                    time = number(trial['time_s'])
                    if time < 0:
                        raise ValueError('Negative time')
                    times.append(time)
                count = trial['near_misses']
                if isinstance(count, bool) or not isinstance(count, int) or count < 0:
                    raise ValueError('near_misses must be a nonnegative integer')
                misses += count
            row.update(success=successes, median_time_s=median(times) if times else None,
                       time_n=len(times), near_misses=misses)
            output['find_end_to_end'].append(row)
    return output


def markdown(result):
    lines = ['# Evaluation results', '', result['notes'], '']
    for key in ('retrieval', 'find_end_to_end', 'change_detection', 'memory'):
        lines += [f'## {key}', '']
        rows = result[key]
        if not rows:
            lines += ['Not yet measured.', '']
            continue
        breakdowns = [dict(variant=r['variant'], **part) for r in rows for part in r.get('by_query_type', [])]
        columns = [c for c in rows[0] if c != 'by_query_type']
        lines += ['| ' + ' | '.join(columns) + ' |', '| ' + ' | '.join(['---'] * len(columns)) + ' |']
        lines += ['| ' + ' | '.join('unmeasured' if r[c] is None else str(r[c]) for c in columns) + ' |' for r in rows]
        lines.append('')
        if breakdowns:
            columns = list(breakdowns[0])
            lines += ['### By query type', '', '| ' + ' | '.join(columns) + ' |', '| ' + ' | '.join(['---'] * len(columns)) + ' |']
            lines += ['| ' + ' | '.join('unmeasured' if r[c] is None else str(r[c]) for c in columns) + ' |' for r in breakdowns]
            lines.append('')
    lines += ['## Raw sources', ''] + [f'- `{p}`' for p in result['sources']]
    return '\n'.join(lines) + '\n'


def main():
    base = Path(__file__).resolve().parent
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--queries', type=Path, default=base / 'queries.yaml')
    parser.add_argument('--runs', type=Path, default=base / 'results')
    parser.add_argument('--ground-truth', type=Path, default=base / 'ground_truth.json')
    parser.add_argument('--output-dir', type=Path, default=base)
    parser.add_argument('--allow-sample', action='store_true')
    args = parser.parse_args()
    if args.allow_sample and args.output_dir.resolve() == base:
        parser.error('SAMPLE output requires a separate --output-dir')
    try:
        queries = json.loads(args.queries.read_text())
    except json.JSONDecodeError:
        try:
            import yaml
        except ImportError as exc:
            raise ValueError('YAML query files require PyYAML; JSON syntax is also valid YAML') from exc
        queries = yaml.safe_load(args.queries.read_text())
    result = aggregate(args.runs.glob('run_*.json'), json.loads(args.ground_truth.read_text()), args.allow_sample, queries)
    args.output_dir.mkdir(parents=True, exist_ok=True)
    (args.output_dir / 'results.json').write_text(json.dumps(result, indent=2, allow_nan=False) + '\n')
    (args.output_dir / 'results.md').write_text(markdown(result))


if __name__ == '__main__':
    main()
