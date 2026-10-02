import copy
import json
from pathlib import Path
import runpy
import subprocess
import sys
import tempfile
import unittest


verify = runpy.run_path(str(Path(__file__).resolve().parents[1] / "scripts/verify-quality.py"))["verify"]


class ReleaseQualityTests(unittest.TestCase):
    def setUp(self):
        self.policy = {"minimumRuns": 5, "requiredCategories": ["mixed"],
                       "models": {"release_to_insertion": ["nemotron-2240"]},
                       "limits": {"release_to_insertion": {"wer": 0.25, "missingWords": 2, "seconds": 8}}}
        self.manifest = {"fixtures": [{"audio": "mixed.wav", "expectedText": "Hallo world",
                                       "expectedLanguages": ["de", "en"], "categories": ["mixed"]}]}
        self.records = [{"model": "nemotron-2240", "phase": "release_to_insertion", "fixture": "mixed.wav",
                         "preview": preview, "run": run, "wer": 0, "missingWords": 0, "seconds": run / 10,
                         "languagePreserved": True, "cleanup": "rules", "translation": "off"}
                        for preview in [False, True] for run in range(1, 6)]

    def test_both_preview_modes_and_percentiles(self):
        summaries = verify(self.policy, self.manifest, self.records)
        self.assertEqual(len(summaries), 2)
        self.assertEqual(summaries[0]["metrics"]["seconds"], {"p50": 0.3, "p95": 0.5})

    def test_incomplete_evidence_never_passes(self):
        for rows in [[], self.records[:-1], self.records + [self.records[0]], self.records[:5]]:
            with self.subTest(rows=len(rows)), self.assertRaises(ValueError):
                verify(self.policy, self.manifest, rows)
        manifest = copy.deepcopy(self.manifest)
        del manifest["fixtures"][0]["expectedText"]
        with self.assertRaises(ValueError):
            verify(self.policy, manifest, self.records)

    def test_invalid_values_and_regressions_fail(self):
        for metric, value in [("wer", float("nan")), ("seconds", float("inf")), ("seconds", True),
                              ("missingWords", -1), ("missingWords", 3), ("wer", 0.3), ("seconds", 8.1),
                              ("languagePreserved", False), ("languagePreserved", None), ("translation", "hy-mt2")]:
            with self.subTest(metric=metric, value=value), self.assertRaises(ValueError):
                rows = copy.deepcopy(self.records)
                rows[0][metric] = value
                verify(self.policy, self.manifest, rows)

    def test_all_reference_categories_are_required(self):
        policy = copy.deepcopy(self.policy)
        policy["requiredCategories"].append("noise")
        with self.assertRaises(ValueError):
            verify(policy, self.manifest, self.records)

    def test_accuracy_cannot_hide_behind_percentile(self):
        # A missing-word regression in one of twenty runs must still fail.
        rows = [dict(self.records[0], run=run) for run in range(1, 21)]
        rows += [dict(row, preview=True) for row in rows]
        rows[0]["wer"] = 0.4
        with self.assertRaises(ValueError):
            verify(self.policy, self.manifest, rows)

    def test_cli_rejects_stale_dirty_and_empty_reports(self):
        script = Path(__file__).resolve().parents[1] / "scripts/verify-quality.py"
        with tempfile.TemporaryDirectory(prefix="saiity-quality-test-") as directory:
            root = Path(directory)
            (root / "policy.json").write_text(json.dumps(self.policy))
            (root / "manifest.json").write_text(json.dumps(self.manifest))
            records = "\n".join("SAIITY_ASR_BENCHMARK " + json.dumps(row) for row in self.records)
            for stamp, rows, status in [("revision clean", records, 0), ("other clean", records, 1),
                                        ("revision dirty", records, 1), ("revision clean", "", 1),
                                        ("revision clean", "SAIITY_ASR_BENCHMARK {broken}", 1)]:
                with self.subTest(stamp=stamp, empty=not rows):
                    (root / "run.log").write_text("SAIITY_QUALITY_SOURCE " + stamp + "\n" + rows)
                    result = subprocess.run([sys.executable, str(script), "--revision", "revision",
                        "--policy", str(root / "policy.json"), "--manifest", str(root / "manifest.json"),
                        str(root / "run.log")], capture_output=True, text=True)
                    self.assertEqual(result.returncode, status, result.stderr)

    def test_checked_in_policy_is_complete(self):
        policy = json.loads((Path(__file__).resolve().parents[1] / "docs/benchmarks/release-quality.json").read_text())
        self.assertEqual(set(policy["models"]), {"warm_segmented_decode", "warm_live_stream", "release_to_insertion"})
        self.assertTrue({"german", "english", "mixed", "noise", "technical"}.issubset(policy["requiredCategories"]))
        for limits in policy["limits"].values():
            self.assertTrue({"wer", "missingWords"}.issubset(limits))


if __name__ == "__main__":
    unittest.main()
