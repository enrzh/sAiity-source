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

gate = runpy.run_path(str(Path(__file__).resolve().parents[1] / "scripts/verify-quality.py"))
verify = gate["verify"]


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
        self.assertNotIn("languageEvidence", policy)
        evidence = policy["futureTier"]["languageEvidence"]
        self.assertEqual(evidence.get("status"), "unverified")
        self.assertEqual(evidence.get("requiredCohorts"), ["en", "de", "ja", "zh-Hans", "zh-Hant", "fr", "es", "pt", "ar", "ru", "hi", "ko"])
        self.assertEqual(evidence.get("minimumClips"), 1)
        self.assertEqual(evidence.get("minimumSpeakers"), 1)
        self.assertEqual(evidence.get("corpusGoal"), {"clips": 20, "speakers": 3,
                         "conditions": {"clean": 12, "difficult": 4, "critical": 4}})
        self.assertEqual(policy["limits"]["warm_segmented_decode"]["realTimeFactor"], 1.0)
        self.assertEqual(policy["limits"]["warm_live_stream"]["droppedAudioSeconds"], 0.0)
        self.assertEqual(policy["minimumRuns"], 5)

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
        # The product branch exports this name earlier. Slice the release function only.
        start = source.index("run_report() {")
        run_report = source[start:source.index("export SAIITY_ASR_BENCHMARK_DIR", start)]
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
            configs = policy["configurations"][phase]
            self.assertEqual({c["chunkMs"] for c in configs}, {1120, 2240})
            self.assertEqual({c["translation"] for c in configs}, {"off"})
            self.assertNotIn("model", {c["cleanup"] for c in configs})
        self.assertEqual({c["cleanup"] for c in policy["configurations"]["release_to_insertion"]}, {"rules"})
        self.assertEqual(policy["models"]["warm_segmented_decode"], ["nemotron-2240"])
        self.assertEqual(policy["models"]["warm_live_stream"], ["nemotron-1120", "nemotron-2240"])
        future = policy["futureTier"]
        self.assertEqual(future["translationLatency"], {"status": "unverified", "limits": None})
        self.assertEqual(future["models"]["warm_segmented_decode"], ["whisper-base"])
        self.assertEqual({c["translation"] for c in future["configurations"]["warm_live_stream"]}, {"hy-mt2", "madlad"})
        self.assertEqual({c["cleanup"] for c in future["configurations"]["release_to_insertion"]}, {"rules", "model"})
        self.assertIn("hy-mt2", {c["translation"] for c in future["configurations"]["release_to_insertion"]})
        self.assertIn("madlad", {c["translation"] for c in future["configurations"]["release_to_insertion"]})
        self.assertLessEqual(len(future["configurations"]["release_to_insertion"]), 8)
        self.assertEqual(policy["limits"]["release_to_insertion"]["seconds"], 8)
        self.assertEqual(policy["limits"]["warm_live_stream"]["firstVolatileSeconds"], 5)
        self.assertNotIn("translationLatency", policy)

    def test_future_tier_skips_until_its_inputs_exist_and_budgets_still_fail(self):
        policy = json.loads((Path(__file__).resolve().parents[1] / "docs/benchmarks/release-quality.json").read_text())
        manifest = {"fixtures": [
            {"audio": "german-fleurs.wav", "expectedText": "Hallo", "expectedLanguages": ["de"], "categories": ["german"]},
            {"audio": "english-jfk.wav", "expectedText": "Hello", "expectedLanguages": ["en"], "categories": ["english"]},
            {"audio": "mixed-de-en.wav", "expectedText": "Hallo Hello", "expectedLanguages": ["de", "en"], "categories": ["mixed", "german", "english"]},
            {"audio": "noise-english.wav", "expectedText": "Hello", "expectedLanguages": ["en"], "categories": ["noise", "english"]},
            {"audio": "technical-english.wav", "expectedText": "Hello", "expectedLanguages": ["en"], "categories": ["technical", "english"]},
        ]}
        with tempfile.TemporaryDirectory(prefix="saiity-future-tier-") as directory:
            root = Path(directory)
            plan = gate["release_plan"](policy, manifest, model_root=root, environment={})
            self.assertEqual([(run["phase"], run["configuration"]["chunkMs"], run["configuration"]["cleanup"],
                               run["configuration"]["translation"]) for run in plan["runs"]], [
                ("warm_segmented_decode", 2240, "off", "off"),
                ("warm_live_stream", 1120, "off", "off"),
                ("warm_live_stream", 2240, "off", "off"),
                ("release_to_insertion", 1120, "rules", "off"),
                ("release_to_insertion", 2240, "rules", "off"),
            ])
            self.assertEqual(plan["policy"]["limits"], policy["limits"])
            self.assertNotIn("languageEvidence", plan["policy"])
            self.assertNotIn("futureTier", plan["policy"])
            skipped = {item["case"]: item["reason"] for item in plan["skips"]}
            self.assertIn("german-fleurs.wav", skipped["languageEvidence"])
            self.assertIn("Whisper base", skipped["warm_segmented_decode/whisper-base"])
            for case in (
                "warm_live_stream/1120/cleanup=off/translation=hy-mt2/target=de",
                "warm_live_stream/2240/cleanup=off/translation=madlad/target=de",
                "release_to_insertion/1120/cleanup=model/translation=off/target=off",
                "release_to_insertion/2240/cleanup=model/translation=off/target=off",
                "release_to_insertion/2240/cleanup=rules/translation=hy-mt2/target=de",
                "release_to_insertion/2240/cleanup=model/translation=hy-mt2/target=de",
                "release_to_insertion/2240/cleanup=rules/translation=madlad/target=de",
                "release_to_insertion/2240/cleanup=model/translation=madlad/target=de",
            ):
                self.assertIn(case, skipped)
                self.assertTrue(skipped[case].strip())
                self.assertEqual(gate["skip_line"](case, skipped[case]),
                                 f"SKIP (optional future tier): {case} — {skipped[case]}")
            # A slow run still fails the unchanged 8 second budget. The optional
            # tier is not a switch that turns the required gate into a no-op.
            gated = copy.deepcopy(plan["policy"])
            gated["models"] = {"release_to_insertion": ["nemotron-2240"]}
            gated["configurations"] = {"release_to_insertion": [
                config for config in plan["policy"]["configurations"]["release_to_insertion"] if config["chunkMs"] == 2240]}
            config = gated["configurations"]["release_to_insertion"][0]
            rows = [dict(row, fixture=fixture["audio"], configuration=config, seconds=9)
                    for fixture in manifest["fixtures"] for row in self.records]
            with self.assertRaisesRegex(ValueError, "seconds"):
                verify(gated, manifest, rows)

            ready = root / "whisper-openai_whisper-base"
            ready.mkdir()
            (ready / ".saiity-ready").write_bytes(b"")
            (ready / "weights.bin").write_bytes(b"weights")
            (root / "hymt2").mkdir()
            (root / "hymt2" / "Hy-MT2-1.8B-Q4_K_M.gguf").write_bytes(b"gguf")
            (root / "madlad" / "int4").mkdir(parents=True)
            (root / "madlad" / "int4" / "model.safetensors").write_bytes(b"madlad")
            (root / "qwen").mkdir()
            (root / "qwen" / "cleanup.gguf").write_bytes(b"cleanup")
            reviewed = copy.deepcopy(manifest)
            for fixture in reviewed["fixtures"]:
                fixture["expectedTranslations"] = {"de": {"text": "Hallo", "reviewed": True}}
            included = gate["release_plan"](policy, reviewed, model_root=root, environment={
                "SAIITY_DICTATION_BENCHMARK_CLEANUP_MODEL": "cleanup.gguf"})
            included_cases = {(run["phase"], run["configuration"]["cleanup"], run["configuration"]["translation"],
                               run["configuration"]["chunkMs"]) for run in included["runs"]}
            self.assertIn(("release_to_insertion", "model", "off", 1120), included_cases)
            self.assertIn(("release_to_insertion", "model", "off", 2240), included_cases)
            self.assertIn(("release_to_insertion", "rules", "hy-mt2", 2240), included_cases)
            self.assertIn(("release_to_insertion", "model", "hy-mt2", 2240), included_cases)
            self.assertIn(("release_to_insertion", "rules", "madlad", 2240), included_cases)
            self.assertIn(("release_to_insertion", "model", "madlad", 2240), included_cases)
            self.assertIn("whisper-base", included["policy"]["models"]["warm_segmented_decode"])
            # Caption translation stays out until its latency budget is calibrated.
            self.assertNotIn(("warm_live_stream", "off", "hy-mt2", 1120), included_cases)
            self.assertNotIn(("warm_live_stream", "off", "madlad", 2240), included_cases)
            self.assertNotIn("translationLatency", included["policy"])
            calibrated = copy.deepcopy(policy)
            calibrated["futureTier"]["translationLatency"] = {"status": "calibrated", "limits": {
                "firstTargetSeconds": 5, "targetFinalSeconds": 6, "translationDrainSeconds": 0.5}}
            captions = gate["release_plan"](calibrated, reviewed, model_root=root, environment={
                "SAIITY_DICTATION_BENCHMARK_CLEANUP_MODEL": "cleanup.gguf"})
            caption_cases = {(run["phase"], run["configuration"]["translation"], run["configuration"]["chunkMs"])
                             for run in captions["runs"]}
            self.assertIn(("warm_live_stream", "hy-mt2", 1120), caption_cases)
            self.assertIn(("warm_live_stream", "madlad", 2240), caption_cases)
            self.assertEqual(captions["policy"]["translationLatency"]["status"], "calibrated")


class ProductQualificationTests(unittest.TestCase):
    def product_data(self, processing="rules", translation="off"):
        # Entirely synthetic gate fixtures. They do not certify real audio/UI.
        policy = {"schema": 1, "status": "unverified", "minimumWarmRuns": 50,
            "coldObservations": {"cold-start": 5, "post-eviction": 5},
            "maxShortSeconds": 10, "longSeconds": 30, "cleanWER": 0.05,
            "translatedWER": 0.25, "languageEvidence": {"requiredCohorts": ["en", "de"],
                "minimumClips": 2, "minimumSpeakers": 2},
            "limits": {"captureStart": 0.150, "rules": 0.700, "model": 1.2,
                "translated": 2.5, "stopToCompositorHidden": 0.100, "stopToInputStopped": 0.250},
            "requiredCases": []}
        manifest = {"fixtures": []}
        for cohort in ("en", "de"):
            for clip in (1, 2):
                scoring = {"language": cohort, "wordUnit": "natural-language", "normalization": "nfc-grapheme-v1"}
                review = {"reviewed": True, "independent": True, "reviewer": "synthetic-listener"}
                manifest["fixtures"].append({"audio": f"{cohort}-{clip}.wav", "expectedText": "synthetic reference",
                    "expectedLanguages": [cohort], "cohort": cohort, "condition": "clean", "durationSeconds": 5,
                    "categories": ["clean"], "scoring": scoring, "referenceReview": review,
                    "provenance": {"reviewed": True, "source": "synthetic test", "license": "test-only",
                        "consent": "test-only", "speechType": "natural", "speaker": f"speaker-{clip}", "reviewer": "curator"},
                    "expectedTranslations": {target: {"text": "synthetic target", "reviewed": True,
                        "referenceReview": review, "scoring": dict(scoring, language=target)} for target in ("en", "de")}})
        records, observations = [], []
        revision = "c" * 40
        for cohort in ("en", "de"):
            config = {"profile": "pipeline", "language": "auto", "chunkMs": 2240, "runs": 5,
                "preview": [False, True], "cleanup": processing, "cleanupModel": "synthetic.gguf" if processing == "model" else None,
                "translation": translation, "target": ("de" if cohort == "en" else "en") if translation != "off" else None,
                "powerMode": "normal", "thermalState": "nominal", "memoryPressure": "normal"}
            policy["requiredCases"].append({"cohort": cohort, "model": "nemotron-2240",
                "configuration": {key: config[key] for key in ("cleanup", "translation", "target")}})
            recordings = {f["audio"]: "d" * 64 for f in manifest["fixtures"]}
            evidence = {"schema": 1, "revision": revision, "sourceState": "clean",
                "appBuild": {"version": "synthetic", "build": "1", "binarySHA256": "e" * 64},
                "corpus": {"manifestSHA256": hashlib.sha256(json.dumps(manifest).encode()).hexdigest(),
                    "recordings": recordings, "corpusSHA256": benchmark_evidence.digest(recordings)},
                "hardware": {key: "synthetic" for key in ("model", "arch", "macOS", "osBuild", "toolchain", "swift", "sdk", "machineID")},
                "models": {"nemotron-2240": "a" * 64}, "configuration": config}
            evidence["hardware"]["memoryBytes"] = 16
            if processing == "model": evidence["models"]["cleanup:synthetic.gguf"] = "b" * 64
            if translation != "off": evidence["models"][translation] = "f" * 64
            for state, count in (("warm", 50), ("cold-start", 5), ("post-eviction", 5)):
                for preview in (False, True):
                    for run in range(1, count + 1):
                        fixture = manifest["fixtures"][(0 if cohort == "en" else 2) + run % 2]
                        run_id = f"{cohort}-{state}-{preview}-{run}"
                        row = {"phase": "release_to_insertion", "runID": run_id, "run": run,
                            "fixture": fixture["audio"], "model": "nemotron-2240", "configuration": config,
                            "evidence": evidence, "warmState": state, "phraseSeconds": 5, "preview": preview,
                            "deliveryEndpoint": "paste-dispatched", "outputSHA256": "a" * 64,
                            "phaseSeconds": {key: 0.01 for key in ("capture", "modelLoad", "nativeQueue", "recognition", "cleanup", "translation", "delivery", "drain")},
                            "wer": 0, "cer": 0, "missingWords": 0, "droppedAudioSeconds": 0, "languagePreserved": True,
                            "scoring": fixture["scoring"], "scoredLanguages": [cohort], "cleanup": processing,
                            "translation": translation, "target": config["target"], "outputWER": 0, "outputCER": 0,
                            "outputMissingWords": 0, "outputLanguagePreserved": True, "scoredOutputLanguages": [cohort]}
                        if processing == "model":
                            row.update(cleanupUnavailable=False, modelCalls=1, modelAccepted=1, modelFallbacks=0, rulesSkipped=0)
                        if translation != "off":
                            reference = fixture["expectedTranslations"][config["target"]]
                            row.update(wasTranslated=True, translationWER=0, translationCER=0, translationMissingWords=0,
                                translationScoring=reference["scoring"], translationReferenceSHA256=hashlib.sha256(reference["text"].encode()).hexdigest(),
                                targetLanguagePreserved=True, translationFailures=0, translationSkipped=0)
                        binding = benchmark_evidence.digest(evidence)
                        observation = {"runID": run_id, "outputSHA256": row["outputSHA256"], "evidenceSHA256": binding,
                            "endpoint": "visible-insertion", "observer": {"identity": "synthetic-observer", "independent": True,
                                "method": "external-accessibility"}, "targetApp": "synthetic.destination",
                            "physicalInputObserved": True, "compositorHiddenObserved": True, "inputStoppedObserved": True,
                            "durationsSeconds": {"captureStart": 0.1, "releaseToEndpoint": 0.6 if state == "warm" else 9,
                                "stopToCompositorHidden": 0.08, "stopToInputStopped": 0.2},
                            "qualityReview": {"reviewed": True, "independent": True, "reviewer": "synthetic-listener",
                                "outputSHA256": row["outputSHA256"], "evidenceSHA256": binding,
                                **{key: True for key in ("meaning", "names", "numbers", "negation", "omissions", "naturalness")}}}
                        records.append(row)
                        observations.append(observation)
        return policy, manifest, records, observations, revision

    def check(self, data):
        self.assertTrue(callable(gate.get("verify_product")), "explicit product qualification path is missing")
        return gate["verify_product"](*data)

    @staticmethod
    def rebind(data):
        for row, observation in zip(data[2], data[3]):
            binding = benchmark_evidence.digest(row["evidence"])
            observation["evidenceSHA256"] = binding
            observation["qualityReview"]["evidenceSHA256"] = binding

    def test_product_mixed_actual_build_hardware_models_fail_even_with_rebound_observer(self):
        for part, field, value in (("appBuild", "binarySHA256", "b" * 64), ("hardware", "machineID", "different-Mac"),
                                  ("models", "nemotron-2240", "b" * 64)):
            data = self.product_data()
            # Only the DE batch changes. Every observation is consistently rebound.
            data[2][120]["evidence"][part][field] = value
            self.rebind(data)
            with self.subTest(part=part), self.assertRaisesRegex(ValueError, "different"):
                self.check(data)

    def test_product_malformed_nested_evidence_and_content_are_rejected(self):
        for part, field, invalid in (("manifest", "fixtures", None), ("policy", "languageEvidence", None),
                ("row", "model", []), ("row", "fixture", []), ("row", "configuration", None),
                ("observation", "transcript", "content must not be accepted"),
                ("observer", "text", "content must not be accepted"),
                ("review", "text", "content must not be accepted")):
            data = self.product_data()
            target = {"manifest": data[1], "policy": data[0], "row": data[2][0],
                      "observation": data[3][0], "observer": data[3][0]["observer"], "review": data[3][0]["qualityReview"]}[part]
            target[field] = invalid
            with self.subTest(part=part, field=field), self.assertRaises(ValueError): self.check(data)

    def test_product_extra_outcomes_and_durations_are_reported_without_pooling(self):
        data = self.product_data()
        # Additional reviewed observations do not dilute the required clean short groups.
        extras = [(10, "clean", "copied", 0), (10, "clean", "paste-dispatched", 0),
                  (10.01, "clean", "visible-insertion", 0), (30, "clean", "visible-insertion", 0),
                  (5, "difficult", "visible-insertion", 0.2), (5, "noisy", "visible-insertion", 0.2)]
        for index, (duration, condition, endpoint, wer) in enumerate(extras):
            fixture = copy.deepcopy(data[1]["fixtures"][0])
            fixture.update(audio=f"extra-{index}.wav", durationSeconds=duration, condition=condition)
            data[1]["fixtures"].append(fixture)
            row, observation = copy.deepcopy(data[2][0]), copy.deepcopy(data[3][0])
            row.update(runID=f"extra-{index}", fixture=fixture["audio"], phraseSeconds=duration, wer=wer, outputWER=wer,
                       deliveryEndpoint="copied" if endpoint == "copied" else "paste-dispatched")
            observation.update(runID=row["runID"], endpoint=endpoint)
            observation["durationsSeconds"]["releaseToEndpoint"] = 20
            data[2].append(row)
            data[3].append(observation)
        recordings = {fixture["audio"]: "d" * 64 for fixture in data[1]["fixtures"]}
        for row in data[2]:
            row["evidence"]["corpus"] = {"recordings": recordings,
                "corpusSHA256": benchmark_evidence.digest(recordings),
                "manifestSHA256": hashlib.sha256(json.dumps(data[1]).encode()).hexdigest()}
        self.rebind(data)
        summaries = self.check(data)
        self.assertEqual(len(summaries), 18)
        self.assertEqual({s["duration"] for s in summaries}, {"short", "medium", "long"})
        self.assertEqual({s["condition"] for s in summaries}, {"clean", "difficult", "noisy"})
        self.assertEqual({s["endpoint"] for s in summaries}, {"copied", "paste-dispatched", "visible-insertion"})
        warm_visible = [s for s in summaries if s["warmState"] == "warm" and s["condition"] == "clean"
                        and s["duration"] == "short" and s["endpoint"] == "visible-insertion"]
        self.assertTrue(all(s["runs"] == 50 and s["metrics"]["releaseToEndpoint"]["p95"] == 0.6 for s in warm_visible))

    def test_product_fifty_repetitions_cannot_replace_reviewed_clips_or_speakers(self):
        for change in ("clip", "speaker", "model-skips"):
            data = self.product_data("model" if change == "model-skips" else "rules")
            if change == "clip":
                for row in data[2][:50]: row["fixture"] = "en-1.wav"
            elif change == "speaker":
                data[1]["fixtures"][1]["provenance"]["speaker"] = "speaker-1"
            else:
                for row in data[2][:50]: row.update(modelCalls=0, modelAccepted=0, rulesSkipped=1)
            with self.subTest(change=change), self.assertRaisesRegex(ValueError, "coverage"):
                self.check(data)

    def test_product_splits_cold_preview_and_exact_endpoint(self):
        data = self.product_data()
        summaries = self.check(data)
        self.assertEqual(len(summaries), 12)
        warm = [s for s in summaries if s["warmState"] == "warm"]
        self.assertEqual({s["cohort"] for s in warm}, {"en", "de"})
        self.assertTrue(all(s["runs"] == 50 and s["endpoint"] == "visible-insertion" for s in warm))
        self.assertTrue(all(s["metrics"]["releaseToEndpoint"]["p95"] == 9 for s in summaries if s["warmState"] != "warm"))

    def test_product_copy_and_dispatch_never_satisfy_visible_insertion(self):
        for endpoint in ("copied", "paste-dispatched"):
            data = self.product_data()
            for row, observation in zip(data[2], data[3]):
                row["deliveryEndpoint"] = endpoint
                observation["endpoint"] = endpoint
            with self.subTest(endpoint=endpoint), self.assertRaisesRegex(ValueError, "visible|coverage"):
                self.check(data)
        data = self.product_data()
        data[2][0]["deliveryEndpoint"] = "copied"
        with self.assertRaisesRegex(ValueError, "endpoint"):
            self.check(data)
        data[2][0]["deliveryEndpoint"] = "visible-insertion"
        with self.assertRaisesRegex(ValueError, "endpoint"):
            self.check(data)

    def test_product_observations_bind_every_output_and_environment(self):
        for part, field, invalid in [("observation", "outputSHA256", "b" * 64),
                ("observation", "evidenceSHA256", "b" * 64), ("observation", "targetApp", ""),
                ("observer", "identity", ""), ("observer", "independent", False), ("observer", "method", "in-memory"),
                ("observation", "physicalInputObserved", False), ("observation", "compositorHiddenObserved", False),
                ("observation", "inputStoppedObserved", False), ("review", "evidenceSHA256", "b" * 64)]:
            data = self.product_data()
            observation = data[3][0]
            target = observation if part == "observation" else observation["observer" if part == "observer" else "qualityReview"]
            target[field] = invalid
            with self.subTest(part=part, field=field), self.assertRaises(ValueError): self.check(data)
        for field in ("revision", "sourceState", "appBuild", "hardware", "models", "configuration", "corpus"):
            data = self.product_data()
            del data[2][0]["evidence"][field]
            with self.subTest(header=field), self.assertRaises(ValueError): self.check(data)

    def test_product_all_semantic_checks_require_independent_review(self):
        for field in ("reviewed", "independent", "meaning", "names", "numbers", "negation", "omissions", "naturalness"):
            data = self.product_data()
            data[3][0]["qualityReview"][field] = False
            with self.subTest(field=field), self.assertRaises(ValueError): self.check(data)
        for field in ("qualityReview", "observer", "durationsSeconds"):
            data = self.product_data()
            del data[3][0][field]
            with self.subTest(missing=field), self.assertRaises(ValueError): self.check(data)

    def test_product_missing_duplicate_short_warm_and_cold_fail(self):
        for change in (lambda d: d[3].clear(), lambda d: d[3].pop(), lambda d: d[3].append(d[3][0]),
                lambda d: d[2].append(d[2][0]), lambda d: d[2].pop(0), lambda d: d[2].pop(50),
                lambda d: d[0].update(minimumWarmRuns=49)):
            data = self.product_data()
            change(data)
            with self.subTest(change=change), self.assertRaises(ValueError): self.check(data)

    def test_product_thresholds_cannot_hide_lost_audio_or_critical_errors(self):
        for field, invalid in [("captureStart", 0.151), ("releaseToEndpoint", 0.701),
                ("stopToCompositorHidden", 0.101), ("stopToInputStopped", 0.251),
                ("captureStart", True), ("releaseToEndpoint", float("nan")), ("stopToInputStopped", -1)]:
            data = self.product_data()
            # More than 5% fail: nearest-rank p95 must exceed the target.
            for observation in data[3][:3]: observation["durationsSeconds"][field] = invalid
            with self.subTest(metric=field), self.assertRaises(ValueError): self.check(data)
        for metric, invalid in [("wer", 0.051), ("outputWER", 0.051), ("missingWords", 1),
                ("outputMissingWords", 1), ("droppedAudioSeconds", 0.001), ("languagePreserved", False)]:
            data = self.product_data()
            data[2][0][metric] = invalid
            with self.subTest(metric=metric), self.assertRaises(ValueError): self.check(data)
        for metric in ("capture", "modelLoad", "nativeQueue", "recognition", "cleanup", "translation", "delivery", "drain"):
            data = self.product_data()
            del data[2][0]["phaseSeconds"][metric]
            with self.subTest(phase=metric), self.assertRaises(ValueError): self.check(data)

    def test_product_duration_noise_and_configuration_cannot_fill_clean_short_coverage(self):
        for field, value in (("durationSeconds", 10.01), ("condition", "difficult"), ("condition", "noisy")):
            data = self.product_data()
            for fixture in data[1]["fixtures"]: fixture[field] = value
            for row in data[2]:
                row["phraseSeconds"] = data[1]["fixtures"][0]["durationSeconds"]
            with self.subTest(field=field, value=value), self.assertRaises(ValueError): self.check(data)
        data = self.product_data()
        data[2][0]["configuration"] = dict(data[2][0]["configuration"], powerMode="low-power")
        with self.assertRaises(ValueError): self.check(data)

    def test_product_model_and_translation_require_success_and_pair_review(self):
        for processing, translation, budget in (("model", "off", 1.2), ("rules", "hy-mt2", 2.5), ("model", "madlad", 2.5)):
            data = self.product_data(processing, translation)
            for observation in data[3][:50]: observation["durationsSeconds"]["releaseToEndpoint"] = budget
            self.assertEqual(len(self.check(data)), 12)
            for observation in data[3][:3]: observation["durationsSeconds"]["releaseToEndpoint"] = budget + 0.001
            with self.subTest(processing=processing, translation=translation), self.assertRaises(ValueError): self.check(data)
        for processing, translation, field, value in (("model", "off", "modelFallbacks", 1),
                ("model", "off", "cleanupUnavailable", True), ("model", "off", "modelAccepted", 2),
                ("rules", "hy-mt2", "wasTranslated", False), ("rules", "hy-mt2", "translationSkipped", 1),
                ("rules", "hy-mt2", "translationReferenceSHA256", "b" * 64)):
            data = self.product_data(processing, translation)
            data[2][0][field] = value
            with self.subTest(field=field), self.assertRaises(ValueError): self.check(data)

    def test_product_cli_content_free_logs_and_no_audio_access(self):
        data = self.product_data()
        script = Path(__file__).resolve().parents[1] / "scripts/verify-quality.py"
        with tempfile.TemporaryDirectory(dir=os.environ["CODEX_TASK_TMP"], prefix="product-") as directory:
            root = Path(directory)
            for name, value in (("policy.json", data[0]), ("manifest.json", data[1]), ("observations.json", data[3])):
                (root / name).write_text(json.dumps(value))
            logs = []
            for cohort in ("en", "de"):
                rows = [r for r in data[2] if r["runID"].startswith(cohort)]
                header = rows[0]["evidence"]
                path = root / (cohort + ".log")
                path.write_text(f"SAIITY_QUALITY_SOURCE {data[4]} clean\nSAIITY_BENCHMARK_EVIDENCE " + json.dumps(header) + "\n"
                    + "\n".join("SAIITY_PRODUCT_BENCHMARK " + json.dumps({k: v for k, v in r.items() if k != "evidence"}) for r in rows)
                    + ReleaseQualityTests.completion(header, data[4]))
                logs.append(str(path))
            command = [sys.executable, str(script), "--product", "--revision", data[4], "--policy", str(root / "policy.json"),
                "--manifest", str(root / "manifest.json"), "--observations", str(root / "observations.json"), *logs]
            result = subprocess.run(command, capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn("product qualification passed", result.stdout)
            self.assertNotIn("synthetic reference", result.stdout)
            # Product parsing accepts legacy ASR records with the explicit additions.
            first_log = Path(logs[0])
            valid_log = first_log.read_text()
            first_log.write_text(valid_log.replace("SAIITY_PRODUCT_BENCHMARK ", "SAIITY_ASR_BENCHMARK "))
            result = subprocess.run(command, capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            for invalid_log in (valid_log.replace(f"{data[4]} clean", f"{data[4]} dirty"),
                    valid_log.replace(f"SAIITY_QUALITY_SOURCE {data[4]}", "SAIITY_QUALITY_SOURCE " + "b" * 40),
                    valid_log[:valid_log.index("\nSAIITY_QUALITY_COMPLETE ")],
                    valid_log + ReleaseQualityTests.completion(data[2][0]["evidence"], data[4])):
                first_log.write_text(invalid_log)
                result = subprocess.run(command, capture_output=True, text=True)
                self.assertEqual(result.returncode, 1)
                self.assertIn("UNVERIFIED", result.stderr)
                self.assertNotIn("passed", result.stdout)
            first_log.write_text(valid_log)
            (root / "observations.json").write_text("[]")
            result = subprocess.run(command, capture_output=True, text=True)
            self.assertEqual(result.returncode, 1)
            self.assertIn("UNVERIFIED", result.stderr)
            self.assertNotIn("passed", result.stdout)
            for part, field, value in (("manifest", "fixtures", None), ("policy", "languageEvidence", None),
                                      ("policy", "requiredCases", None)):
                malformed = copy.deepcopy(data[1] if part == "manifest" else data[0])
                malformed[field] = value
                changed = root / (part + ".json")
                original = changed.read_text()
                changed.write_text(json.dumps(malformed))
                result = subprocess.run(command, capture_output=True, text=True)
                self.assertEqual(result.returncode, 1)
                self.assertIn("UNVERIFIED", result.stderr)
                self.assertNotIn("Traceback", result.stderr)
                changed.write_text(original)

    def test_product_checked_in_policy_declares_targets_not_measurements(self):
        path = Path(__file__).resolve().parents[1] / "docs/benchmarks/product-quality.json"
        self.assertTrue(path.is_file(), "product policy is missing")
        policy = json.loads(path.read_text())
        self.assertEqual(policy["status"], "unverified")
        self.assertGreaterEqual(policy["minimumWarmRuns"], 50)
        self.assertEqual(policy["limits"], self.product_data()[0]["limits"])
        self.assertEqual(policy["languageEvidence"]["requiredCohorts"], ["en", "de"])


if __name__ == "__main__":
    unittest.main()
