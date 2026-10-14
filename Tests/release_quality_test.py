import copy
import hashlib
import json
import os
from pathlib import Path
import runpy
import subprocess
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "scripts"))
import benchmark_evidence

verify = runpy.run_path(str(Path(__file__).resolve().parents[1] / "scripts/verify-quality.py"))["verify"]


class ReleaseQualityTests(unittest.TestCase):
    def reviewed_cohort(self):
        # Synthetic metadata tests the gate only; no acoustic quality claim.
        policy = copy.deepcopy(self.policy)
        policy["languageEvidence"] = {"status": "unverified", "requiredCohorts": ["de"],
                                      "minimumClips": 1, "minimumSpeakers": 1}
        manifest = copy.deepcopy(self.manifest)
        fixture = manifest["fixtures"][0]
        fixture.update(cohort="de", provenance={"reviewed": True, "source": "synthetic gate test",
            "license": "test only", "consent": "test only", "speechType": "natural",
            "speaker": "test-speaker", "reviewer": "test-curator"},
            referenceReview={"reviewed": True, "independent": True, "reviewer": "test-listener"},
            scoring={"language": "de", "wordUnit": "natural-language", "normalization": "nfc-grapheme-v1"})
        rows = copy.deepcopy(self.records)
        for row in rows:
            row.update(scoring=fixture["scoring"], cer=0, outputCER=0, scoredLanguages=["de", "en"],
                       scoredOutputLanguages=["de", "en"], outputSHA256="a" * 64,
                       qualityReview={"reviewed": True, "independent": True, "reviewer": "test-listener",
                           "outputSHA256": "a" * 64, "meaning": True, "names": True, "numbers": True,
                           "negation": True, "omissions": True, "naturalness": True})
        return policy, manifest, rows

    def test_reviewed_cohorts_cannot_be_certified_by_german_english_only(self):
        policy, manifest, rows = self.reviewed_cohort()
        policy["languageEvidence"]["requiredCohorts"].append("ja")
        with self.assertRaisesRegex(ValueError, "ja.*unverified|missing.*cohort"):
            verify(policy, manifest, rows)

    def test_reviewed_provenance_and_independent_reference_are_required(self):
        policy, manifest, rows = self.reviewed_cohort()
        for part, field, value in [("provenance", "reviewed", False), ("provenance", "source", ""),
                ("provenance", "license", ""), ("provenance", "consent", ""),
                ("provenance", "speechType", "synthetic"), ("provenance", "speaker", ""),
                ("referenceReview", "independent", False), ("referenceReview", "reviewer", "")]:
            bad = copy.deepcopy(manifest)
            bad["fixtures"][0][part][field] = value
            with self.subTest(part=part, field=field), self.assertRaisesRegex(ValueError, "provenance|reference review"):
                verify(policy, bad, rows)
        self.assertEqual(len(verify(policy, manifest, rows)), 2)

    def test_clip_and_speaker_coverage_is_independent_of_warm_repetitions(self):
        policy, manifest, rows = self.reviewed_cohort()
        for field in ("minimumClips", "minimumSpeakers"):
            bad = copy.deepcopy(policy)
            bad["languageEvidence"][field] = 2
            with self.subTest(field=field), self.assertRaisesRegex(ValueError, "coverage"):
                verify(bad, manifest, rows)
        policy["languageEvidence"]["requiredCohorts"] = ["zh-Hant"]
        manifest["fixtures"][0].update(cohort="zh-Hans", expectedLanguages=["zh-Hans", "en"])
        with self.assertRaisesRegex(ValueError, "cohort|coverage"):
            verify(policy, manifest, rows)

    def test_scoring_sequence_cer_and_meaning_are_independent_gates(self):
        policy, manifest, rows = self.reviewed_cohort()
        for field, value in [("scoring", None), ("cer", None), ("outputCER", None),
                             ("scoredLanguages", ["de", "fr", "en"]),
                             ("scoredOutputLanguages", ["de", "en", "unknown"]),
                             ("qualityReview", None), ("outputSHA256", "b" * 64)]:
            bad = copy.deepcopy(rows)
            bad[0][field] = value
            with self.subTest(field=field), self.assertRaises(ValueError):
                verify(policy, manifest, bad)
        for check in ("meaning", "names", "numbers", "negation", "omissions", "naturalness"):
            bad = copy.deepcopy(rows)
            bad[0]["qualityReview"][check] = False
            with self.subTest(check=check), self.assertRaisesRegex(ValueError, "quality review"):
                verify(policy, manifest, bad)
        summary = verify(policy, manifest, rows)[0]
        self.assertEqual(summary.get("cohort"), "de")
        self.assertEqual(summary.get("verifiedCohorts"), ["de"])
        self.assertEqual(summary.get("scoring"), manifest["fixtures"][0]["scoring"])
        self.assertEqual(summary["metrics"].get("cer"), {"p50": 0, "p95": 0})
        self.assertEqual(summary["metrics"].get("outputCER"), {"p50": 0, "p95": 0})

    def test_alternative_reference_binding_and_script_outcome_cannot_be_omitted(self):
        policy = copy.deepcopy(self.policy)
        config = {"cleanup": "rules", "translation": "hy-mt2", "target": "zh-Hant"}
        policy["configurations"] = {"release_to_insertion": [config]}
        manifest = copy.deepcopy(self.manifest)
        reference = {"text": "學校", "reviewed": True, "alternatives": ["學校裡"]}
        manifest["fixtures"][0]["expectedTranslations"] = {"zh-Hant": reference}
        hashes = [hashlib.sha256(text.encode()).hexdigest() for text in [reference["text"], *reference["alternatives"]]]
        rows = [dict(row, configuration=config, translation="hy-mt2", wasTranslated=True,
                     target="zh-Hant", translationReferenceSHA256=hashes[0],
                     translationReferencesSHA256=hashlib.sha256("\n".join(hashes).encode()).hexdigest(),
                     translationWER=0, translationCER=0, translationMissingWords=0,
                     targetLanguagePreserved=True, targetVariantPreserved=True,
                     translationFailures=0, translationSkipped=0) for row in self.records]
        self.assertEqual(len(verify(policy, manifest, rows)), 2)
        for field in ("translationReferencesSHA256", "targetVariantPreserved"):
            bad = copy.deepcopy(rows)
            del bad[0][field]
            with self.subTest(field=field), self.assertRaises(ValueError): verify(policy, manifest, bad)
        reference["alternatives"].append("另一個已審閱答案")
        with self.assertRaisesRegex(ValueError, "reference"):
            verify(policy, manifest, rows)

    def test_initial_twelve_cohorts_are_declared_unverified_without_relaxing_limits(self):
        policy = json.loads((Path(__file__).resolve().parents[1] / "docs/benchmarks/release-quality.json").read_text())
        evidence = policy.get("languageEvidence", {})
        self.assertEqual(evidence.get("status"), "unverified")
        self.assertEqual(evidence.get("requiredCohorts"), ["en", "de", "ja", "zh-Hans", "zh-Hant", "fr", "es", "pt", "ar", "ru", "hi", "ko"])
        self.assertEqual(evidence.get("minimumClips"), 1)
        self.assertEqual(evidence.get("minimumSpeakers"), 1)
        self.assertEqual(evidence.get("corpusGoal"), {"clips": 20, "speakers": 3,
                         "conditions": {"clean": 12, "difficult": 4, "critical": 4}})

    def test_translated_reviewed_scope_requires_target_contract_and_review(self):
        policy, manifest, rows = self.reviewed_cohort()
        config = {"cleanup": "rules", "translation": "hy-mt2", "target": "en"}
        policy["configurations"] = {"release_to_insertion": [config]}
        reference = {"text": "Hello world", "reviewed": True,
                     "referenceReview": manifest["fixtures"][0]["referenceReview"],
                     "scoring": {"language": "en", "wordUnit": "natural-language", "normalization": "nfc-grapheme-v1"}}
        manifest["fixtures"][0]["expectedTranslations"] = {"en": reference}
        for row in rows:
            row.update(configuration=config, translation="hy-mt2", wasTranslated=True, target="en",
                translationReferenceSHA256=hashlib.sha256(reference["text"].encode()).hexdigest(),
                translationWER=0, translationCER=0, translationMissingWords=0, translationScoring=reference["scoring"],
                targetLanguagePreserved=True, translationFailures=0, translationSkipped=0)
        self.assertEqual(len(verify(policy, manifest, rows)), 2)
        self.assertEqual(verify(policy, manifest, rows)[0]["metrics"].get("translationCER"), {"p50": 0, "p95": 0})
        for field, value in [("wordUnit", "scalar"), ("normalization", "unreviewed"), ("language", "de")]:
            bad = copy.deepcopy(manifest)
            bad["fixtures"][0]["expectedTranslations"]["en"]["scoring"][field] = value
            bad_rows = copy.deepcopy(rows)
            for row in bad_rows: row["translationScoring"] = bad["fixtures"][0]["expectedTranslations"]["en"]["scoring"]
            with self.subTest(field=field), self.assertRaisesRegex(ValueError, "scoring"):
                verify(policy, bad, bad_rows)

    def test_subset_policy_preflight_can_finish_without_native_commands(self):
        repository = Path(__file__).resolve().parents[1]
        source = (repository / "scripts/quality-matrix.sh").read_text()
        preflight = source[:source.index("run_report() {")]
        policy, manifest, _ = self.reviewed_cohort()
        policy["languageEvidence"]["requiredCohorts"].append("ja")
        with tempfile.TemporaryDirectory(prefix="saiity-pql7-preflight-") as directory:
            root = Path(directory)
            (root / "manifest.json").write_text(json.dumps(manifest))
            (root / "policy.json").write_text(json.dumps(policy))
            # The real script's cd is relative to its own path. Supply that path as $0.
            harness = 'git() { if [ "$1" = rev-parse ]; then printf "revision\\n"; fi; }\n'
            env = dict(os.environ, SAIITY_RELEASE_FIXTURES=str(root), SAIITY_RELEASE_POLICY=str(root / "policy.json"),
                       SAIITY_RELEASE_QUALITY_OUT=str(root / "reports"), PYTHONDONTWRITEBYTECODE="1")
            result = subprocess.run(["bash", "-c", harness + preflight, str(repository / "scripts/quality-matrix.sh")],
                                    env=env, capture_output=True, text=True)
            self.assertNotEqual(result.returncode, 0, "missing cohort must stop before any native runner")
            self.assertIn("ja", result.stderr)

    def test_model_cleanup_requires_successful_calls_per_configuration_and_preview(self):
        policy = copy.deepcopy(self.policy)
        config = {"cleanup": "model", "translation": "off"}
        policy["configurations"] = {"release_to_insertion": [config]}
        rows = [dict(row, cleanup="model", cleanupUnavailable=False, configuration=config,
                     modelCalls=0, modelAccepted=0, modelFallbacks=0, rulesSkipped=1) for row in self.records]
        with self.assertRaisesRegex(ValueError, "model.*coverage"):
            verify(policy, self.manifest, rows)
        rows[0].update(modelCalls=1, modelAccepted=1, rulesSkipped=0)
        with self.assertRaisesRegex(ValueError, "model.*coverage"):
            verify(policy, self.manifest, rows)
        rows[5].update(modelCalls=1, modelAccepted=1, rulesSkipped=0)
        self.assertEqual(len(verify(policy, self.manifest, rows)), 2)
        bad = copy.deepcopy(rows)
        bad[1].update(modelCalls=1, rulesSkipped=0)
        with self.assertRaisesRegex(ValueError, "counts"):
            verify(policy, self.manifest, bad)
        for field, value in [("modelCalls", None), ("modelAccepted", True), ("modelFallbacks", -1),
                             ("rulesSkipped", 0.5), ("modelFallbacks", 1)]:
            bad = copy.deepcopy(rows)
            bad[0][field] = value
            with self.subTest(field=field, value=value), self.assertRaises(ValueError):
                verify(policy, self.manifest, bad)
        # Coverage may come from another reviewed fixture; legitimate rules skips remain.
        manifest = copy.deepcopy(self.manifest)
        manifest["fixtures"].append(dict(manifest["fixtures"][0], audio="repair.wav"))
        skipped = [dict(row, modelCalls=0, modelAccepted=0, rulesSkipped=1) for row in rows]
        self.assertEqual(len(verify(policy, manifest, skipped + [dict(row, fixture="repair.wav") for row in rows])), 4)

    def test_translated_caption_latency_is_retained_and_uncalibrated_is_explicit(self):
        policy = copy.deepcopy(self.policy)
        config = {"cleanup": "off", "translation": "hy-mt2", "target": "de"}
        policy["models"] = {"warm_live_stream": ["nemotron-2240"]}
        policy["limits"] = {"warm_live_stream": {"wer": 0.25, "missingWords": 2, "firstFinalSeconds": 8}}
        policy["configurations"] = {"warm_live_stream": [config]}
        manifest = copy.deepcopy(self.manifest)
        reference = {"text": "Hallo Welt", "reviewed": True}
        manifest["fixtures"][0]["expectedTranslations"] = {"de": reference}
        rows = [dict(row, phase="warm_live_stream", configuration=config, target="de", firstFinalSeconds=0.2,
                     translationReferenceSHA256=hashlib.sha256(reference["text"].encode()).hexdigest(),
                     translationWER=0, translationMissingWords=0, targetLanguagePreserved=True,
                     translationFailures=0, translationSkipped=0, firstTargetSeconds=row["run"],
                     targetFinalSeconds=row["run"] + 1, translationDrainSeconds=row["run"] / 10)
                for row in self.records[:5]]
        summary = verify(policy, manifest, rows)[0]
        self.assertEqual(summary["translationLatency"], "unverified")
        self.assertEqual(summary["metrics"]["firstTargetSeconds"], {"p50": 3, "p95": 5})
        self.assertEqual(summary["metrics"]["targetFinalSeconds"], {"p50": 4, "p95": 6})
        self.assertEqual(summary["metrics"]["translationDrainSeconds"], {"p50": 0.3, "p95": 0.5})
        # Explicit synthetic reference budgets, never measured production constants.
        policy["translationLatency"] = {"status": "calibrated", "limits": {
            "firstTargetSeconds": 5, "targetFinalSeconds": 6, "translationDrainSeconds": 0.5}}
        self.assertEqual(verify(policy, manifest, rows)[0]["translationLatency"], "calibrated")
        for metric in policy["translationLatency"]["limits"]:
            bad = copy.deepcopy(rows)
            bad[-1][metric] = policy["translationLatency"]["limits"][metric] + 1
            with self.subTest(metric=metric), self.assertRaises(ValueError): verify(policy, manifest, bad)
        for metric in ("firstTargetSeconds", "targetFinalSeconds", "translationDrainSeconds"):
            bad = copy.deepcopy(rows)
            del bad[0][metric]
            with self.subTest(missing=metric), self.assertRaises(ValueError): verify(policy, manifest, bad)

        config = benchmark_evidence.configuration("captions", {"SAIITY_CAPTION_BENCHMARK_RUNS": "5",
            "SAIITY_CAPTION_BENCHMARK_TRANSLATION": "hy-mt2"})
        policy["configurations"]["warm_live_stream"] = [config]
        rows = [dict(row, configuration=config) for row in rows]
        with tempfile.TemporaryDirectory(prefix="saiity-target-latency-test-") as directory:
            root = Path(directory)
            (root / "manifest.json").write_text(json.dumps(manifest))
            (root / "mixed.wav").write_bytes(b"synthetic")
            header = {"schema": 1, "corpus": benchmark_evidence.corpus(root), "configuration": config,
                      "models": {"nemotron-2240": "a" * 64, "hy-mt2": "b" * 64},
                      "hardware": {key: "synthetic" for key in ["model", "arch", "macOS", "osBuild", "toolchain", "swift", "sdk"]}}
            header["hardware"]["memoryBytes"] = 16
            (root / "run.log").write_text("SAIITY_QUALITY_SOURCE revision clean\nSAIITY_BENCHMARK_EVIDENCE " + json.dumps(header)
                + "\n" + "\n".join("SAIITY_CAPTION_BENCHMARK " + json.dumps(row) for row in rows) + self.completion(header))
            for calibrated in (False, True):
                tested = copy.deepcopy(policy)
                if not calibrated: tested["translationLatency"] = {"status": "unverified", "limits": None}
                (root / "policy.json").write_text(json.dumps(tested))
                result = subprocess.run([sys.executable, str(Path(__file__).resolve().parents[1] / "scripts/verify-quality.py"),
                    "--revision", "revision", "--policy", str(root / "policy.json"), "--manifest", str(root / "manifest.json"),
                    str(root / "run.log")], capture_output=True, text=True)
                self.assertEqual(result.returncode, 0 if calibrated else 1, result.stderr)
                self.assertIn('"targetFinalSeconds": {"p50": 4, "p95": 6}', result.stdout)
                if not calibrated:
                    self.assertIn("latency is unverified", result.stderr)
                    self.assertNotIn("quality gate passed", result.stdout)

    @staticmethod
    def completion(evidence, revision="revision"):
        fingerprint = benchmark_evidence.digest(evidence)
        return "\nSAIITY_QUALITY_COMPLETE " + json.dumps({"revision": revision,
            "beforeSHA256": fingerprint, "afterSHA256": fingerprint})

    def test_runner_stamps_only_successful_unchanged_runs(self):
        repository = Path(__file__).resolve().parents[1]
        source = (repository / "scripts/quality-matrix.sh").read_text()
        run_report = source[source.index("run_report() {"):source.index("export SAIITY_ASR_BENCHMARK_DIR")]
        # Execute the real shell function with synthetic fingerprint/Git commands;
        # never invoke the matrix's Swift/model/recording paths.
        harness = r'''
set -euo pipefail
revision=revision
source_state=clean
fixtures=synthetic
python3() {
    if [ "$1" = scripts/benchmark_evidence.py ]; then
        if [ -e "$probe_seen" ] && [ "$scenario" = fingerprint ]; then
            printf '{"schema":2}\n'
        else printf '{"schema":1}\n'; fi
    else "$python_runtime" "$@"; fi
}
git() {
    if [ "$1" = rev-parse ]; then
        if [ "$scenario" = revision ]; then printf 'other\n'; else printf 'revision\n'; fi
    elif [ "$scenario" = dirty ]; then printf ' M synthetic.swift\n'; fi
}
probe() {
    printf 'synthetic complete measurements\n'
    touch "$probe_seen"
    [ "$scenario" != command ]
}
'''
        with tempfile.TemporaryDirectory(prefix="saiity-quality-runner-test-") as directory:
            root = Path(directory)
            for scenario in ("success", "command", "fingerprint", "dirty", "revision"):
                log = root / (scenario + ".log")
                environment = dict(os.environ, scenario=scenario, probe_seen=str(root / (scenario + ".seen")),
                                   python_runtime=sys.executable, PYTHONDONTWRITEBYTECODE="1")
                result = subprocess.run(["bash", "-c", harness + run_report + '\nrun_report "$1" pipeline probe\n',
                                         "runner-test", str(log)], cwd=repository, env=environment, capture_output=True, text=True)
                with self.subTest(scenario=scenario):
                    self.assertEqual(result.returncode == 0, scenario == "success", result.stderr)
                    self.assertEqual(log.read_text().count("SAIITY_QUALITY_COMPLETE "), 1 if scenario == "success" else 0)

    def test_explicit_combinations_cannot_share_or_skip_runs(self):
        policy = copy.deepcopy(self.policy)
        policy["configurations"] = {"release_to_insertion": [
            {"chunkMs": 2240, "cleanup": "rules", "translation": "off", "target": None},
            {"chunkMs": 1120, "cleanup": "model", "translation": "off", "target": None}]}
        policy["models"]["release_to_insertion"].append("nemotron-1120")
        rows = [dict(row, configuration=policy["configurations"]["release_to_insertion"][0]) for row in self.records]
        with self.assertRaisesRegex(ValueError, "missing|duplicate"):
            verify(policy, self.manifest, rows)
        rows += [dict(row, model="nemotron-1120", cleanup="model",
                      cleanupUnavailable=False, modelCalls=1, modelAccepted=1, modelFallbacks=0, rulesSkipped=0,
                      configuration=policy["configurations"]["release_to_insertion"][1]) for row in self.records]
        self.assertEqual(len(verify(policy, self.manifest, rows)), 4)
        rows[-1]["cleanupUnavailable"] = True
        with self.assertRaisesRegex(ValueError, "cleanup"):
            verify(policy, self.manifest, rows)
        rows[-1]["cleanupUnavailable"] = False
        rows[-1]["status"] = "skipped"
        with self.assertRaisesRegex(ValueError, "skipped|missing"):
            verify(policy, self.manifest, rows)

    def test_translation_requires_reviewed_target_reference_and_metrics(self):
        policy = copy.deepcopy(self.policy)
        config = {"chunkMs": 2240, "cleanup": "rules", "translation": "hy-mt2", "target": "de"}
        policy["configurations"] = {"release_to_insertion": [config]}
        manifest = copy.deepcopy(self.manifest)
        reference = {"text": "Hallo Welt", "reviewed": True}
        manifest["fixtures"][0]["expectedTranslations"] = {"de": reference}
        rows = [dict(row, translation="hy-mt2", configuration=config, target="de",
                     translationReferenceSHA256=hashlib.sha256(reference["text"].encode()).hexdigest(),
                     translationWER=0, translationMissingWords=0, targetLanguagePreserved=True,
                     translationFailures=0, translationSkipped=0, wasTranslated=True) for row in self.records]
        self.assertEqual(len(verify(policy, manifest, rows)), 2)
        for field, value in [("translationReferenceSHA256", "a" * 64), ("translationWER", None),
                             ("translationWER", 0.3), ("wer", 0.3), ("missingWords", 3), ("languagePreserved", False),
                             ("translationSkipped", 1), ("targetLanguagePreserved", False), ("wasTranslated", False)]:
            bad = copy.deepcopy(rows)
            bad[0][field] = value
            with self.subTest(field=field), self.assertRaises(ValueError): verify(policy, manifest, bad)
        reference["reviewed"] = False
        with self.assertRaisesRegex(ValueError, "reviewed"):
            verify(policy, manifest, rows)

    def test_required_configurations_must_select_a_model(self):
        policy = copy.deepcopy(self.policy)
        policy["configurations"] = {"release_to_insertion": [{"chunkMs": 1120, "cleanup": "rules", "translation": "off"}]}
        with self.assertRaises(ValueError): verify(policy, self.manifest, self.records)

    def test_cli_accepts_enabled_processing_only_with_matching_fingerprints(self):
        script = Path(__file__).resolve().parents[1] / "scripts/verify-quality.py"
        config = benchmark_evidence.configuration("pipeline", {
            "SAIITY_DICTATION_BENCHMARK_CHUNK_MS": "1120", "SAIITY_DICTATION_BENCHMARK_CLEANUP": "model",
            "SAIITY_DICTATION_BENCHMARK_CLEANUP_MODEL": "cleanup.gguf",
            "SAIITY_DICTATION_BENCHMARK_TRANSLATION": "madlad"})
        policy = copy.deepcopy(self.policy)
        policy["models"]["release_to_insertion"] = ["nemotron-1120"]
        policy["configurations"] = {"release_to_insertion": [config]}
        manifest = copy.deepcopy(self.manifest)
        reference = {"text": "Hallo Welt", "reviewed": True}
        manifest["fixtures"][0]["expectedTranslations"] = {"de": reference}
        rows = [dict(row, model="nemotron-1120", cleanup="model", translation="madlad", target="de",
                     configuration=config, translationReferenceSHA256=hashlib.sha256(reference["text"].encode()).hexdigest(),
                     translationWER=0, translationMissingWords=0, targetLanguagePreserved=True,
                     translationFailures=0, translationSkipped=0, wasTranslated=True, cleanupUnavailable=False,
                     modelCalls=1, modelAccepted=1, modelFallbacks=0, rulesSkipped=0) for row in self.records]
        with tempfile.TemporaryDirectory(prefix="saiity-quality-test-") as directory:
            root = Path(directory)
            (root / "manifest.json").write_text(json.dumps(manifest))
            (root / "mixed.wav").write_bytes(b"synthetic fixture")
            (root / "policy.json").write_text(json.dumps(policy))
            header = {"schema": 1, "corpus": benchmark_evidence.corpus(root), "configuration": config,
                      "models": {name: "a" * 64 for name in ["nemotron-1120", "madlad", "cleanup:cleanup.gguf"]},
                      "hardware": {key: "synthetic" for key in ["model", "arch", "macOS", "osBuild", "toolchain", "swift", "sdk"]}}
            header["hardware"]["memoryBytes"] = 16
            for omitted in [None, "madlad", "cleanup:cleanup.gguf", "nemotron-1120"]:
                altered = copy.deepcopy(header)
                if omitted: del altered["models"][omitted]
                (root / "run.log").write_text("SAIITY_QUALITY_SOURCE revision clean\nSAIITY_BENCHMARK_EVIDENCE " + json.dumps(altered)
                    + "\n" + "\n".join("SAIITY_ASR_BENCHMARK " + json.dumps(row) for row in rows) + self.completion(altered))
                result = subprocess.run([sys.executable, str(script), "--revision", "revision", "--policy", str(root / "policy.json"),
                                         "--manifest", str(root / "manifest.json"), str(root / "run.log")], capture_output=True, text=True)
                self.assertEqual(result.returncode, 1 if omitted else 0, result.stderr)

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
        for row in self.records:
            row.update(outputWER=0, outputMissingWords=0, outputLanguagePreserved=True)

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

    def test_cleanup_output_accuracy_is_independent_of_raw_recognition(self):
        for metric, value in [("outputWER", 0.3), ("outputMissingWords", 3), ("outputLanguagePreserved", False)]:
            rows = copy.deepcopy(self.records)
            rows[0][metric] = value
            with self.subTest(metric=metric), self.assertRaises(ValueError):
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
            (root / "mixed.wav").write_bytes(b"local fixture bytes")
            evidence = {"schema": 1, "corpus": benchmark_evidence.corpus(root), "models": {"nemotron-2240": "a" * 64},
                        "hardware": {"model": "test", "arch": "arm64", "memoryBytes": 16, "macOS": "27", "osBuild": "test", "toolchain": "test", "swift": "test", "sdk": "test"},
                        "configuration": {"profile": "pipeline", "language": "auto", "runs": 5, "chunkMs": 2240,
                                          "preview": [False, True], "cleanup": "rules", "translation": "off"}}
            records = "\n".join("SAIITY_ASR_BENCHMARK " + json.dumps(dict(row, configuration=evidence["configuration"])) for row in self.records)
            for stamp, rows, status in [("revision clean", records, 0), ("other clean", records, 1),
                                        ("revision dirty", records, 1), ("revision clean", "", 1),
                                        ("revision clean", "SAIITY_ASR_BENCHMARK {broken}", 1)]:
                with self.subTest(stamp=stamp, empty=not rows):
                    (root / "run.log").write_text("SAIITY_QUALITY_SOURCE " + stamp + "\nSAIITY_BENCHMARK_EVIDENCE " + json.dumps(evidence) + "\n" + rows + self.completion(evidence))
                    result = subprocess.run([sys.executable, str(script), "--revision", "revision",
                        "--policy", str(root / "policy.json"), "--manifest", str(root / "manifest.json"),
                        str(root / "run.log")], capture_output=True, text=True)
                    self.assertEqual(result.returncode, status, result.stderr)

            def check_header(header, measured_records=records):
                (root / "run.log").write_text("SAIITY_QUALITY_SOURCE revision clean\nSAIITY_BENCHMARK_EVIDENCE " + json.dumps(header) + "\n" + measured_records + self.completion(header))
                return subprocess.run([sys.executable, str(script), "--revision", "revision",
                    "--policy", str(root / "policy.json"), "--manifest", str(root / "manifest.json"),
                    str(root / "run.log")], capture_output=True, text=True).returncode
            for field, value in [("fixture", "unreviewed.wav"), ("phase", "warm_live_stream"), ("model", "nemotron-1120")]:
                bad = [dict(row, configuration=evidence["configuration"]) for row in self.records]
                bad[0][field] = value
                bad_records = "\n".join("SAIITY_ASR_BENCHMARK " + json.dumps(row) for row in bad)
                self.assertEqual(check_header(evidence, bad_records), 1)
            extra = dict(self.records[0], fixture="unreviewed.wav", configuration=evidence["configuration"])
            self.assertEqual(check_header(evidence, records + "\nSAIITY_ASR_BENCHMARK " + json.dumps(extra)), 1)
            for field, value in [("runs", 6), ("chunkMs", 1120), ("cleanup", "model")]:
                altered = copy.deepcopy(evidence)
                altered["configuration"][field] = value
                self.assertEqual(check_header(altered), 1, f"row/header mismatch: {field}")
            for field, invalid in [("models", {}), ("hardware", {}), ("configuration", {"profile": "pipeline"})]:
                altered = copy.deepcopy(evidence)
                altered[field] = invalid
                self.assertEqual(check_header(altered), 1)
            check_header(evidence)
            valid_log = (root / "run.log").read_text()
            marker = self.completion(evidence)
            for invalid in [valid_log.removesuffix(marker), valid_log + marker,
                            valid_log.replace(marker, self.completion(evidence, "other")),
                            valid_log.replace(benchmark_evidence.digest(evidence), "b" * 64),
                            valid_log.replace('"afterSHA256": "' + benchmark_evidence.digest(evidence), '"afterSHA256": "' + "b" * 64),
                            marker.lstrip() + "\n" + valid_log.removesuffix(marker)]:
                (root / "run.log").write_text(invalid)
                result = subprocess.run([sys.executable, str(script), "--revision", "revision",
                    "--policy", str(root / "policy.json"), "--manifest", str(root / "manifest.json"),
                    str(root / "run.log")], capture_output=True, text=True)
                self.assertEqual(result.returncode, 1, "incomplete/inconsistent/duplicate/premature completion must fail")
            (root / "run.log").write_text(valid_log)
            for part, field, value, message in [("hardware", "model", "another-device", "different hardware"),
                                                 ("models", "nemotron-2240", "b" * 64, "different model bytes")]:
                altered = copy.deepcopy(evidence)
                altered[part][field] = value
                (root / "second.log").write_text("SAIITY_QUALITY_SOURCE revision clean\nSAIITY_BENCHMARK_EVIDENCE " + json.dumps(altered) + "\n" + records + self.completion(altered))
                result = subprocess.run([sys.executable, str(script), "--revision", "revision",
                    "--policy", str(root / "policy.json"), "--manifest", str(root / "manifest.json"),
                    str(root / "run.log"), str(root / "second.log")], capture_output=True, text=True)
                self.assertEqual(result.returncode, 1)
                self.assertIn(message, result.stderr)
            (root / "mixed.wav").write_bytes(b"changed after measurement")
            self.assertEqual(check_header(evidence), 1)
            (root / "mixed.wav").write_bytes(b"local fixture bytes")
            (root / "manifest.json").write_text(json.dumps(dict(self.manifest, note="changed reference")))
            self.assertEqual(check_header(evidence), 1)

    def test_checked_in_policy_is_complete(self):
        policy = json.loads((Path(__file__).resolve().parents[1] / "docs/benchmarks/release-quality.json").read_text())
        self.assertEqual(set(policy["models"]), {"warm_segmented_decode", "warm_live_stream", "release_to_insertion"})
        self.assertTrue({"german", "english", "mixed", "noise", "technical"}.issubset(policy["requiredCategories"]))
        for limits in policy["limits"].values():
            self.assertTrue({"wer", "missingWords"}.issubset(limits))
        for phase in ("warm_live_stream", "release_to_insertion"):
            configs = policy.get("configurations", {}).get(phase, [])
            self.assertEqual({c["chunkMs"] for c in configs}, {1120, 2240})
            self.assertEqual({c["translation"] for c in configs}, {"off", "hy-mt2", "madlad"})
            if phase == "release_to_insertion":
                self.assertEqual({c["cleanup"] for c in configs}, {"rules", "model"})
            self.assertLessEqual(len(configs), 8, "keep representative coverage bounded")
        self.assertEqual(policy["limits"]["release_to_insertion"]["seconds"], 8)
        self.assertEqual(policy["limits"]["warm_live_stream"]["firstVolatileSeconds"], 5)
        self.assertEqual(policy["translationLatency"], {"status": "unverified", "limits": None})


if __name__ == "__main__":
    unittest.main()
