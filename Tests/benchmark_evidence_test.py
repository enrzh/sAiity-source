import hashlib
import json
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "scripts"))
import benchmark_evidence as evidence


class BenchmarkEvidenceTests(unittest.TestCase):
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
            def command(*args):
                return "16" if args[-1] == "hw.memsize" else "test-hardware"
            with patch.object(evidence, "command", command):
                asr = evidence.capture(root, "asr", root, {})
                pipeline = evidence.capture(root, "pipeline", root, {})
            self.assertEqual(asr["hardware"], pipeline["hardware"])
            self.assertEqual(asr["models"]["nemotron-2240"], pipeline["models"]["nemotron-2240"])
            self.assertIn("whisper-base", asr["models"])
            self.assertEqual(pipeline["configuration"]["preview"], [False, True])
            self.assertEqual(pipeline["configuration"]["cleanup"], "rules")


if __name__ == "__main__":
    unittest.main()
