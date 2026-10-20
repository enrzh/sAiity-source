from contextlib import redirect_stderr, redirect_stdout
import hashlib
import io
import json
import os
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "scripts"))
import benchmark_evidence as evidence


class BenchmarkEvidenceTests(unittest.TestCase):
    def product_fixture(self, root):
        # Synthetic bytes only; no real recording, model or executable is read/run.
        (root / "manifest.json").write_text(json.dumps({"fixtures": [{"audio": "speech.wav",
            "expectedText": "test-only source phrase", "expectedTranslations": {"de": {
                "text": "test-only target phrase", "reviewed": True}}, "output": "test-only model output"}]}))
        (root / "speech.wav").write_bytes(b"synthetic audio fixture")
        model = root / "nemotron-multilingual/multilingual/2240ms"
        model.mkdir(parents=True)
        (model / "weights").write_bytes(b"synthetic model bytes")
        binary = root / "synthetic-host"
        binary.write_bytes(b"synthetic executable bytes")
        return {"binary": binary, "version": "2.7.0-rc.9", "build": "225", "revision": "a" * 40,
                "machineID": "test-machine", "powerMode": "normal", "thermalState": "nominal", "memoryPressure": "normal"}

    @staticmethod
    def product_command(*args):
        if args[0] == "git":
            return "a" * 40 if "rev-parse" in args else ""
        return "16" if args[-1] == "hw.memsize" else "synthetic-hardware"

    def test_legacy_capture_and_cli_shape_remain_exact_and_ignore_pipeline_run_override(self):
        with tempfile.TemporaryDirectory(dir=os.environ["CODEX_TASK_TMP"], prefix="header-") as directory:
            root = Path(directory)
            self.product_fixture(root)
            environment = {"SAIITY_DICTATION_BENCHMARK_RUNS": "50"}
            with patch.object(evidence, "command", self.product_command):
                header = evidence.capture(root, "pipeline", root, environment)
                self.assertEqual(set(header), {"schema", "corpus", "models", "hardware", "configuration"})
                self.assertEqual(header["configuration"], {"profile": "pipeline", "language": "auto", "chunkMs": 2240,
                    "runs": 5, "realtime": None, "preview": [False, True], "cleanup": "rules", "cleanupModel": None,
                    "translation": "off", "target": None})
                self.assertNotIn("machineID", header["hardware"])
                argv = ["benchmark_evidence.py", str(root), "--profile", "pipeline", "--model-root", str(root)]
                output = io.StringIO()
                with patch.object(sys, "argv", argv), patch.dict(os.environ, {}, clear=True), redirect_stdout(output):
                    self.assertEqual(evidence.main(), 0)
                self.assertEqual(json.loads(output.getvalue()), header)

    def test_product_header_binds_exact_binary_revision_build_and_stays_content_free(self):
        with tempfile.TemporaryDirectory(dir=os.environ["CODEX_TASK_TMP"], prefix="header-") as directory:
            root = Path(directory)
            metadata = self.product_fixture(root)
            with patch.object(evidence, "command", self.product_command):
                header = evidence.capture(root, "pipeline", root, {}, product=metadata)
                self.assertEqual(set(header), {"schema", "corpus", "models", "hardware", "configuration", "revision", "sourceState", "appBuild"})
                self.assertEqual(header["sourceState"], "clean")
                self.assertEqual(header["revision"], metadata["revision"])
                self.assertEqual(header["appBuild"], {"version": metadata["version"], "build": metadata["build"],
                    "binarySHA256": hashlib.sha256(b"synthetic executable bytes").hexdigest()})
                self.assertEqual(header["hardware"]["machineID"], "test-machine")
                for field in ("powerMode", "thermalState", "memoryPressure"):
                    self.assertEqual(header["configuration"][field], metadata[field])
                original = evidence.digest(header)
                metadata["binary"].write_bytes(b"changed synthetic executable")
                changed = evidence.capture(root, "pipeline", root, {}, product=metadata)
                self.assertNotEqual(changed["appBuild"]["binarySHA256"], header["appBuild"]["binarySHA256"])
                self.assertNotEqual(evidence.digest(changed), original)
                self.assertEqual(changed["corpus"], header["corpus"])
                self.assertEqual(changed["models"], header["models"])
            for private in ("test-only source phrase", "test-only target phrase", "test-only model output", str(root)):
                self.assertNotIn(private, json.dumps(header))

    def test_product_machine_conditions_version_and_build_change_canonical_binding_only(self):
        with tempfile.TemporaryDirectory(dir=os.environ["CODEX_TASK_TMP"], prefix="header-") as directory:
            root = Path(directory)
            metadata = self.product_fixture(root)
            with patch.object(evidence, "command", self.product_command):
                before = evidence.capture(root, "pipeline", root, {}, product=metadata)
                for field, value in (("machineID", "other-machine"), ("powerMode", "low-power"),
                        ("thermalState", "serious"), ("memoryPressure", "warning"), ("version", "2.7.0-rc.10"), ("build", "226")):
                    with self.subTest(field=field):
                        changed = evidence.capture(root, "pipeline", root, {}, product=dict(metadata, **{field: value}))
                        self.assertNotEqual(evidence.digest(before), evidence.digest(changed))
                        self.assertEqual(changed["corpus"], before["corpus"])
                        self.assertEqual(changed["models"], before["models"])
                        self.assertEqual(changed["appBuild"]["binarySHA256"], before["appBuild"]["binarySHA256"])

    def test_product_missing_malformed_metadata_fails_before_tools_or_hashing(self):
        with tempfile.TemporaryDirectory(dir=os.environ["CODEX_TASK_TMP"], prefix="header-") as directory:
            root = Path(directory)
            metadata = self.product_fixture(root)
            invalid = [None, [], {}, dict(metadata, transcript="must not be accepted")]
            invalid += [{k: v for k, v in metadata.items() if k != field} for field in metadata]
            for field in metadata:
                invalid += [dict(metadata, **{field: value}) for value in (None, "", " ", True, ["bad"], "bad\nfield")]
            invalid += [dict(metadata, revision="revision"), dict(metadata, revision="B" * 40),
                        dict(metadata, binary=root / "missing"), dict(metadata, binary=root)]
            for bad in invalid:
                # None means legacy mode; use an empty product dictionary for that missing payload case.
                if bad is None: bad = {}
                with self.subTest(metadata=bad), patch.object(evidence, "command") as command, \
                        patch.object(evidence, "corpus") as corpus, patch.object(evidence, "file_hash") as file_hash, \
                        patch.object(evidence, "tree_hash") as tree_hash:
                    with self.assertRaises(ValueError): evidence.capture(root, "pipeline", root, {}, product=bad)
                    command.assert_not_called()
                    corpus.assert_not_called()
                    file_hash.assert_not_called()
                    tree_hash.assert_not_called()

    def test_product_dirty_or_stale_source_fails_before_hardware_and_file_reads(self):
        with tempfile.TemporaryDirectory(dir=os.environ["CODEX_TASK_TMP"], prefix="header-") as directory:
            root = Path(directory)
            metadata = self.product_fixture(root)
            for revision, status in (("b" * 40, ""), ("a" * 40, " M fake.swift"), ("a" * 40, "?? untracked.swift")):
                calls = []
                def command(*args):
                    calls.append(args)
                    self.assertEqual(args[:3], ("git", "-C", str(Path(evidence.__file__).resolve().parents[1])))
                    if "status" in args:
                        self.assertIn("--untracked-files=all", args, "repository config must not hide untracked source")
                    return revision if "rev-parse" in args else status
                with self.subTest(revision=revision, status=status), patch.object(evidence, "command", command), \
                        patch.object(evidence, "file_hash") as file_hash, patch.object(evidence, "tree_hash") as tree_hash:
                    with self.assertRaisesRegex(ValueError, "clean|revision"):
                        evidence.capture(root, "pipeline", root, {}, product=metadata)
                    self.assertTrue(calls)
                    file_hash.assert_not_called()
                    tree_hash.assert_not_called()

    def test_product_source_change_during_collection_cannot_claim_clean(self):
        with tempfile.TemporaryDirectory(dir=os.environ["CODEX_TASK_TMP"], prefix="header-") as directory:
            root = Path(directory)
            metadata = self.product_fixture(root)
            for fault in ("revision", "dirty"):
                seen = {"head": 0, "status": 0}
                def command(*args):
                    if args[0] != "git": return self.product_command(*args)
                    key = "head" if "rev-parse" in args else "status"
                    seen[key] += 1
                    if seen[key] > 1:
                        if fault == "revision" and key == "head": return "b" * 40
                        if fault == "dirty" and key == "status": return " M changed.swift"
                    return "a" * 40 if key == "head" else ""
                with self.subTest(fault=fault), patch.object(evidence, "command", command):
                    with self.assertRaisesRegex(ValueError, "clean|revision|changed"):
                        evidence.capture(root, "pipeline", root, {}, product=metadata)

    def test_product_pipeline_repeats_extend_only_explicit_mode(self):
        with tempfile.TemporaryDirectory(dir=os.environ["CODEX_TASK_TMP"], prefix="header-") as directory:
            root = Path(directory)
            metadata = self.product_fixture(root)
            for repeats in ("1", "5", "10", "50"):
                config = evidence.configuration("pipeline", {"SAIITY_DICTATION_BENCHMARK_RUNS": repeats}, product=metadata)
                self.assertEqual(config["runs"], int(repeats))
            for repeats in ("0", "51", "-1", "1.5", "bad"):
                with self.subTest(repeats=repeats), patch.object(evidence, "command") as command:
                    with self.assertRaises(ValueError):
                        evidence.capture(root, "pipeline", root, {"SAIITY_DICTATION_BENCHMARK_RUNS": repeats}, product=metadata)
                    command.assert_not_called()
            for profile in ("asr", "captions"):
                with self.assertRaises(ValueError): evidence.configuration(profile, {}, product=metadata)
            self.assertEqual(evidence.configuration("pipeline", {"SAIITY_DICTATION_BENCHMARK_RUNS": "50"})["runs"], 5)
            with self.assertRaises(ValueError): evidence.configuration("captions", {"SAIITY_CAPTION_BENCHMARK_RUNS": "50"})

    def test_product_cli_supplies_all_metadata_and_requires_explicit_opt_in(self):
        with tempfile.TemporaryDirectory(dir=os.environ["CODEX_TASK_TMP"], prefix="header-") as directory:
            root = Path(directory)
            metadata = self.product_fixture(root)
            argv = ["benchmark_evidence.py", str(root), "--profile", "pipeline", "--model-root", str(root),
                "--product", "--binary", str(metadata["binary"]), "--version", metadata["version"], "--build", metadata["build"],
                "--revision", metadata["revision"], "--machine-id", metadata["machineID"], "--power-mode", metadata["powerMode"],
                "--thermal-state", metadata["thermalState"], "--memory-pressure", metadata["memoryPressure"]]
            with patch.object(sys, "argv", argv), patch.dict(os.environ, {"SAIITY_DICTATION_BENCHMARK_RUNS": "50"}, clear=True), \
                    patch.object(evidence, "command", self.product_command), redirect_stdout(io.StringIO()) as output:
                self.assertEqual(evidence.main(), 0)
                result = json.loads(output.getvalue())
                self.assertEqual(result["configuration"]["runs"], 50)
                self.assertEqual(result["revision"], metadata["revision"])
            for missing in ("--product", "--binary", "--revision", "--machine-id", "--thermal-state"):
                bad = argv.copy()
                index = bad.index(missing)
                del bad[index:index + (1 if missing == "--product" else 2)]
                with self.subTest(missing=missing), patch.object(sys, "argv", bad), patch.object(evidence, "command") as command, \
                        redirect_stdout(io.StringIO()) as output, redirect_stderr(io.StringIO()) as error:
                    self.assertEqual(evidence.main(), 1)
                    self.assertEqual(output.getvalue(), "")
                    self.assertIn("FATAL: benchmark evidence unavailable", error.getvalue())
                    command.assert_not_called()

    def test_multilingual_reviews_and_alternatives_remain_bound_without_disclosing_text(self):
        with tempfile.TemporaryDirectory(prefix="saiity-evidence-test-") as directory:
            root = Path(directory)
            manifest = {"fixtures": [{"audio": "speech.wav", "expectedText": "private source",
                "cohort": "zh-Hant", "provenance": {"consent": "reviewed local consent"},
                "scoring": {"language": "zh-Hant", "wordUnit": "natural-language"},
                "expectedTranslations": {"en": {"text": "private target", "reviewed": True,
                    "alternatives": ["private reviewed alternative"]}}}]}
            (root / "speech.wav").write_bytes(b"synthetic hash test only")
            (root / "manifest.json").write_text(json.dumps(manifest))
            original = evidence.corpus(root)
            fixture = manifest["fixtures"][0]
            for update in (lambda: fixture.update(cohort="zh-Hans"),
                           lambda: fixture["provenance"].update(consent="changed consent"),
                           lambda: fixture["scoring"].update(wordUnit="scalar"),
                           lambda: fixture["expectedTranslations"]["en"]["alternatives"].append("another private alternative")):
                before = evidence.corpus(root)
                update()
                (root / "manifest.json").write_text(json.dumps(manifest))
                after = evidence.corpus(root)
                self.assertNotEqual(before["manifestSHA256"], after["manifestSHA256"])
                self.assertEqual(original["recordings"], after["recordings"])
                self.assertNotIn("private", json.dumps(after))

    def test_enabled_processing_and_tiers_are_fingerprinted(self):
        with tempfile.TemporaryDirectory(prefix="saiity-evidence-test-") as directory:
            root = Path(directory)
            (root / "manifest.json").write_text("{}")
            (root / "speech.wav").write_bytes(b"synthetic recording")
            for name in ["nemotron-multilingual/multilingual/1120ms/weights", "qwen/cleanup.gguf",
                         "hymt2/Hy-MT2-1.8B-Q4_K_M.gguf", "madlad/int4/weights"]:
                path = root / name
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_bytes(name.encode())
            env = {"SAIITY_DICTATION_BENCHMARK_CHUNK_MS": "1120", "SAIITY_DICTATION_BENCHMARK_CLEANUP": "model",
                   "SAIITY_DICTATION_BENCHMARK_CLEANUP_MODEL": "cleanup.gguf",
                   "SAIITY_DICTATION_BENCHMARK_TRANSLATION": "hy-mt2", "SAIITY_DICTATION_BENCHMARK_TARGET": "en"}
            with patch.object(evidence, "command", lambda *args: "16" if args[-1] == "hw.memsize" else "test"):
                for translation in ["off", "hy-mt2", "madlad"]:
                    with self.subTest(translation=translation):
                        env["SAIITY_DICTATION_BENCHMARK_TRANSLATION"] = translation
                        result = evidence.capture(root, "pipeline", root, env)
                        self.assertEqual(result["configuration"]["chunkMs"], 1120)
                        self.assertEqual(result["configuration"]["cleanupModel"], "cleanup.gguf")
                        self.assertEqual(result["configuration"]["translation"], translation)
                        self.assertIn("cleanup:cleanup.gguf", result["models"])
                        if translation != "off": self.assertIn(translation, result["models"])

    def test_invalid_configuration_is_rejected_before_tools(self):
        for profile, env in [("pipeline", {"SAIITY_DICTATION_BENCHMARK_CHUNK_MS": "560"}),
                             ("pipeline", {"SAIITY_DICTATION_BENCHMARK_CLEANUP": "model"}),
                             ("captions", {"SAIITY_CAPTION_BENCHMARK_RUNS": "11"}),
                             ("captions", {"SAIITY_CAPTION_BENCHMARK_REALTIME": "invalid"})]:
            with self.subTest(profile=profile, env=env), patch.object(evidence, "command") as command:
                with self.assertRaises(ValueError): evidence.capture(Path("/missing"), profile, Path("/missing"), env)
                command.assert_not_called()

    def test_content_hashes_are_stable_and_detect_changed_bytes(self):
        with tempfile.TemporaryDirectory(prefix="saiity-evidence-test-") as directory:
            root = Path(directory)
            (root / "manifest.json").write_text('{"expectedText":"private reference"}')
            (root / "speech.wav").write_bytes(b"recording")
            before = evidence.corpus(root)
            self.assertEqual(before["recordings"]["speech.wav"], hashlib.sha256(b"recording").hexdigest())
            self.assertEqual(before, evidence.corpus(root))
            self.assertNotIn("private reference", json.dumps(before))
            (root / "speech.wav").write_bytes(b"different recording")
            self.assertNotEqual(before["corpusSHA256"], evidence.corpus(root)["corpusSHA256"])
            (root / "manifest.json").write_text('{"expectedText":"corrected reference"}')
            self.assertNotEqual(before["manifestSHA256"], evidence.corpus(root)["manifestSHA256"])

    def test_model_tree_hash_includes_names_and_bytes(self):
        with tempfile.TemporaryDirectory(prefix="saiity-evidence-test-") as directory:
            root = Path(directory)
            (root / "weights.bin").write_bytes(b"weights")
            first = evidence.tree_hash(root)
            self.assertEqual(first, evidence.tree_hash(root))
            (root / "weights.bin").rename(root / "renamed.bin")
            self.assertNotEqual(first, evidence.tree_hash(root))
            renamed = evidence.tree_hash(root)
            (root / "renamed.bin").write_bytes(b"new weights")
            self.assertNotEqual(renamed, evidence.tree_hash(root))

    def test_missing_inputs_fail_explicitly(self):
        with tempfile.TemporaryDirectory(prefix="saiity-evidence-test-") as directory:
            root = Path(directory)
            with self.assertRaises(ValueError): evidence.corpus(root)
            with self.assertRaises(ValueError): evidence.tree_hash(root)

    def test_profiles_record_hardware_and_actual_model_bytes(self):
        with tempfile.TemporaryDirectory(prefix="saiity-evidence-test-") as directory:
            root = Path(directory)
            (root / "manifest.json").write_text("{}")
            (root / "speech.wav").write_bytes(b"recording")
            for name in ["nemotron-multilingual/multilingual/2240ms", "whisper-openai_whisper-base"]:
                model = root / name
                model.mkdir(parents=True)
                (model / "weights.bin").write_bytes(name.encode())
            (root / "whisper-openai_whisper-base" / ".saiity-ready").write_bytes(b"")
            def command(*args):
                return "16" if args[-1] == "hw.memsize" else "test-hardware"
            with patch.object(evidence, "command", command):
                asr = evidence.capture(root, "asr", root, {})
                pipeline = evidence.capture(root, "pipeline", root, {})
                self.assertEqual(asr["hardware"], pipeline["hardware"])
                self.assertEqual(asr["models"]["nemotron-2240"], pipeline["models"]["nemotron-2240"])
                self.assertIn("whisper-base", asr["models"])
                (root / "whisper-openai_whisper-base" / ".saiity-ready").unlink()
                self.assertNotIn("whisper-base", evidence.capture(root, "asr", root, {})["models"])
            self.assertEqual(pipeline["configuration"]["preview"], [False, True])
            self.assertEqual(pipeline["configuration"]["cleanup"], "rules")


if __name__ == "__main__":
    unittest.main()
