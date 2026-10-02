#!/usr/bin/env python3
"""Check existing local benchmark JSON lines against explicit release budgets."""
import argparse
import json
import math
from pathlib import Path
import statistics
import sys


PREFIXES = ("SAIITY_ASR_BENCHMARK ", "SAIITY_CAPTION_BENCHMARK ")
ACCURACY = {"wer", "cer", "missingWords", "droppedAudioSeconds"}


def number(value):
    if isinstance(value, bool) or not isinstance(value, (int, float)) or not math.isfinite(value) or value < 0:
        raise ValueError("missing, negative or non-finite measurement")
    return value


def p95(values):
    return sorted(values)[math.ceil(len(values) * 0.95) - 1]


def verify(policy, manifest, records):
    minimum = policy["minimumRuns"]
    if type(minimum) is not int or minimum < 5:
        raise ValueError("at least five warm runs are required")
    if not policy["models"] or not policy["requiredCategories"]:
        raise ValueError("model and corpus requirements cannot be empty")
    fixtures = {}
    categories = set()
    for fixture in manifest["fixtures"]:
        audio = fixture["audio"]
        if audio in fixtures or Path(audio).name != audio or not audio.endswith(".wav"):
            raise ValueError("duplicate or invalid fixture name")
        if not isinstance(fixture.get("expectedText"), str) or not fixture["expectedText"].strip():
            raise ValueError(f"{audio}: verified expectedText is required")
        languages = fixture.get("expectedLanguages")
        if not isinstance(languages, list) or not languages or any(not isinstance(x, str) or not x.strip() for x in languages):
            raise ValueError(f"{audio}: expectedLanguages is required")
        labels = fixture.get("categories", [])
        if not isinstance(labels, list) or any(not isinstance(x, str) for x in labels):
            raise ValueError(f"{audio}: invalid categories")
        language_codes = {language.strip().replace("_", "-").split("-")[0].lower() for language in languages}
        if language_codes.intersection({"auto", "und", "unknown", ""}):
            raise ValueError(f"{audio}: reference languages must be known")
        if "mixed" in labels and len(language_codes) < 2:
            raise ValueError(f"{audio}: mixed speech needs multiple reference languages")
        categories.update(labels)
        fixtures[audio] = fixture
    if not fixtures or not set(policy["requiredCategories"]).issubset(categories):
        raise ValueError("corpus is missing required speech categories")

    summaries = []
    for phase, models in policy["models"].items():
        limits = policy["limits"][phase]
        if not models or not limits or "wer" not in limits or "missingWords" not in limits:
            raise ValueError(f"{phase}: accuracy budgets and models are required")
        for metric, limit in limits.items():
            number(limit)
        for model in models:
            for audio in fixtures:
                for preview in ([False, True] if phase == "release_to_insertion" else [None]):
                    rows = [r for r in records if r.get("phase") == phase and r.get("model") == model
                            and r.get("fixture") == audio and (preview is None or r.get("preview") is preview)]
                    label = f"{phase}/{model}/{audio}" + (f"/preview={preview}" if preview is not None else "")
                    runs = [r.get("run") for r in rows]
                    if len(rows) < minimum or any(type(run) is not int or run < 1 for run in runs) or len(set(runs)) != len(runs):
                        raise ValueError(f"{label}: missing or duplicate warm runs")
                    if any(r.get("languagePreserved") is not True for r in rows):
                        raise ValueError(f"{label}: language preservation failed or was not measured")
                    if phase == "release_to_insertion" and any(r.get("translation") != "off" or r.get("cleanup") != "rules" for r in rows):
                        raise ValueError(f"{label}: measure the rules-cleanup, untranslated pipeline")
                    summary = {"case": label, "runs": len(rows), "metrics": {}}
                    for metric, limit in limits.items():
                        values = [number(r.get(metric)) for r in rows]
                        observed = max(values) if metric in ACCURACY else p95(values)
                        if observed > limit:
                            raise ValueError(f"{label}: {metric} {observed:.3f} exceeds {limit:.3f}")
                        summary["metrics"][metric] = {"p50": statistics.median(values), "p95": p95(values)}
                    if all(r.get("physicalMemoryBytes") is not None for r in rows):
                        summary["metrics"]["physicalMemoryBytes"] = {"p95": p95([number(r["physicalMemoryBytes"]) for r in rows])}
                    summaries.append(summary)
    return summaries


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--manifest", required=True, type=Path)
    parser.add_argument("--policy", type=Path, default=Path(__file__).resolve().parents[1] / "docs/benchmarks/release-quality.json")
    parser.add_argument("--revision", required=True, help="exact clean Git revision measured by every log")
    parser.add_argument("logs", nargs="+", type=Path)
    args = parser.parse_args()
    try:
        records = []
        for log in args.logs:
            lines = log.read_text().splitlines()
            stamps = [line for line in lines if line.startswith("SAIITY_QUALITY_SOURCE ")]
            if stamps != [f"SAIITY_QUALITY_SOURCE {args.revision} clean"]:
                raise ValueError(f"{log.name}: missing, dirty or stale source revision")
            for line in lines:
                for prefix in PREFIXES:
                    if line.startswith(prefix):
                        record = json.loads(line[len(prefix):])
                        if not isinstance(record, dict):
                            raise ValueError("benchmark record is not an object")
                        records.append(record)
        result = verify(json.loads(args.policy.read_text()), json.loads(args.manifest.read_text()), records)
        for summary in result:
            print(json.dumps(summary, sort_keys=True, allow_nan=False))
        print(f"quality gate passed: {len(result)} fixture/model/preview cases")
    except (OSError, ValueError, KeyError, TypeError) as error:
        print(f"FATAL: quality gate failed: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
