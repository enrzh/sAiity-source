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
