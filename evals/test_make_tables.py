import json
import tempfile
import unittest
from pathlib import Path
from make_tables import aggregate, markdown

BASE = Path(__file__).resolve().parent


class TablesTest(unittest.TestCase):
    def setUp(self):
        self.paths = list((BASE / 'fixtures').glob('run_*.json'))
        self.truth = json.loads((BASE / 'fixtures/ground_truth_SAMPLE.json').read_text())

    def test_sample_cannot_leak_into_real_results(self):
        with self.assertRaisesRegex(ValueError, 'SAMPLE'):
            aggregate(self.paths, self.truth)

    def test_measured_counts_and_geometry(self):
        result = aggregate(self.paths, self.truth, True)
        row = result['retrieval'][0]
        self.assertEqual((row['n'], row['top1'], row['top3']), (1, 0, 1))
        self.assertEqual(row['pos_err_cm_median'], 500)
        self.assertEqual(result['find_end_to_end'][0]['success'], 1)
        self.assertEqual(result['find_end_to_end'][0]['median_time_s'], 3)
        self.assertEqual(result['change_detection'], [])
        self.assertEqual(result['memory'], [])
        self.assertIn('SAMPLE', markdown(result))

    def test_optional_evidence_constrains_success(self):
        run = json.loads((BASE / 'fixtures/run_SAMPLE_find.json').read_text())
        run['trials'][0]['arrival_dist_m'] = 1
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'run.json'
            path.write_text(json.dumps(run))
            result = aggregate([path], self.truth, True)
        self.assertEqual(result['find_end_to_end'][0]['success'], 0)

    def test_sample_ground_truth_refused_without_marked_runs(self):
        with self.assertRaisesRegex(ValueError, 'SAMPLE ground truth'):
            aggregate([], self.truth)

    def test_query_type_denominators_and_ambiguous_targets(self):
        run = json.loads((BASE / 'fixtures/run_SAMPLE_retrieval.json').read_text())
        ambiguous = dict(run['trials'][0], query_id='amb', target=['SAMPLE_obj', 'SAMPLE_wrong'])
        missing = dict(run['trials'][0], query_id='missing', ranked=[])
        run['trials'] += [ambiguous, missing]
        truth = dict(self.truth, objects=self.truth['objects'] +
                     [dict(id='SAMPLE_wrong', x=3, z=4)])
        queries = [dict(id='SAMPLE_q', type='exact'), dict(id='amb', type='ambiguous')]
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'run.json'
            path.write_text(json.dumps(run))
            result = aggregate([path], truth, True, queries)
        row = result['retrieval'][0]
        self.assertEqual((row['n'], row['top1'], row['top3'], row['pos_err_n']), (3, 1, 2, 2))
        parts = {part['type']: part for part in row['by_query_type']}
        self.assertEqual(parts['ambiguous']['pos_err_cm_median'], 0)
        self.assertEqual(parts['exact']['n'], 1)
        self.assertEqual(parts['unknown']['pos_err_n'], 0)
        self.assertIsNone(parts['unknown']['pos_err_cm_median'])
        self.assertIn('### By query type', markdown(result))

    def test_no_runs_produces_empty_tables(self):
        result = aggregate([], {'objects': [], 'changes': []})
        self.assertEqual(result['retrieval'], [])
        self.assertEqual(result['find_end_to_end'], [])
        self.assertNotIn('SAMPLE', result['notes'])

    def test_missing_ground_truth_is_an_error(self):
        with self.assertRaisesRegex(ValueError, 'ground truth'):
            aggregate(self.paths, {'objects': []}, True)


if __name__ == '__main__':
    unittest.main()
