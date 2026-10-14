#!/usr/bin/env python3
"""Check existing local benchmark JSON lines against explicit release budgets."""
import argparse
import hashlib
from itertools import product
import json
import math
from pathlib import Path
import statistics
import sys
import benchmark_evidence


PREFIXES = ("SAIITY_ASR_BENCHMARK ", "SAIITY_CAPTION_BENCHMARK ")
ACCURACY = {"wer", "cer", "missingWords", "droppedAudioSeconds", "translationWER", "translationCER", "translationMissingWords", "outputWER", "outputMissingWords"}
TARGET_LATENCY = ("firstTargetSeconds", "targetFinalSeconds", "translationDrainSeconds")


def number(value):
    if isinstance(value, bool) or not isinstance(value, (int, float)) or not math.isfinite(value) or value < 0:
        raise ValueError("missing, negative or non-finite measurement")
    return value


def p95(values):
    return sorted(values)[math.ceil(len(values) * 0.95) - 1]


def language_sequence(languages):
    if not isinstance(languages, list) or not languages:
        raise ValueError("missing scored language sequence")
    result = []
    for language in languages:
        if not isinstance(language, str):
            raise ValueError("invalid scored language sequence")
        base = language.strip().replace("_", "-").split("-")[0].lower()
        if base in ("", "auto", "und", "unknown"):
            raise ValueError("unknown scored language sequence")
        if not result or result[-1] != base:
            result.append(base)
    return result


def reviewed_coverage(policy, fixtures):
    evidence = policy.get("languageEvidence")
    if evidence is None:
        return []  # Historical/custom gates retain their original, narrower contract.
    required = evidence.get("requiredCohorts")
    if (not isinstance(required, list) or not required or any(not isinstance(x, str) or not x.strip() for x in required)
            or len(set(required)) != len(required)):
        raise ValueError("explicit nonempty required cohorts are required")
    for field in ("minimumClips", "minimumSpeakers"):
        if type(evidence.get(field)) is not int or evidence[field] < 1:
            raise ValueError("positive cohort coverage requirements are required")
    for audio, fixture in fixtures.items():
        provenance = fixture.get("provenance", {})
        if (not isinstance(provenance, dict) or provenance.get("reviewed") is not True
                or provenance.get("speechType") != "natural"
                or any(not isinstance(provenance.get(key), str) or not provenance[key].strip()
                       for key in ("source", "license", "consent", "speaker", "reviewer"))):
            raise ValueError(f"{audio}: reviewed natural-speech provenance is required")
        review = fixture.get("referenceReview", {})
        if (not isinstance(review, dict) or review.get("reviewed") is not True or review.get("independent") is not True
                or not isinstance(review.get("reviewer"), str) or not review["reviewer"].strip()):
            raise ValueError(f"{audio}: independent reference review is required")
        cohort = fixture.get("cohort")
        if cohort not in required or cohort not in fixture["expectedLanguages"]:
            raise ValueError(f"{audio}: cohort must match an explicit reviewed language/variant in required cohorts")
        scoring = fixture.get("scoring", {})
        if (not isinstance(scoring, dict) or scoring.get("language") not in fixture["expectedLanguages"]
                or scoring.get("wordUnit") != "natural-language" or scoring.get("normalization") != "nfc-grapheme-v1"):
            raise ValueError(f"{audio}: explicit reviewed word/grapheme scoring contract is required")
    for cohort in required:
        clips = [fixture for fixture in fixtures.values() if fixture["cohort"] == cohort]
        speakers = {fixture["provenance"]["speaker"] for fixture in clips}
        if len(clips) < evidence["minimumClips"] or len(speakers) < evidence["minimumSpeakers"]:
            raise ValueError(f"{cohort}: unverified cohort coverage (clips={len(clips)}, speakers={len(speakers)})")
    return required


def reviewed_output(row, label):
    review = row.get("qualityReview", {})
    output_hash = row.get("outputSHA256")
    if (not isinstance(review, dict) or review.get("reviewed") is not True or review.get("independent") is not True
            or not isinstance(review.get("reviewer"), str) or not review["reviewer"].strip()
            or not isinstance(output_hash, str) or len(output_hash) != 64 or any(c not in "0123456789abcdef" for c in output_hash)
            or review.get("outputSHA256") != output_hash
            or any(review.get(key) is not True for key in ("meaning", "names", "numbers", "negation", "omissions", "naturalness"))):
        raise ValueError(f"{label}: independent output-bound quality review is required")


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
    cohorts = reviewed_coverage(policy, fixtures)

    summaries = []
    for phase, models in policy["models"].items():
        limits = policy["limits"][phase]
        if not models or not limits or "wer" not in limits or "missingWords" not in limits:
            raise ValueError(f"{phase}: accuracy budgets and models are required")
        for metric, limit in limits.items():
            number(limit)
        configurations = policy.get("configurations", {}).get(phase, [{"cleanup": "rules", "translation": "off"}])
        if not configurations:
            raise ValueError(f"{phase}: required configurations cannot be empty")
        for config in configurations:
            if not any(not model.startswith("nemotron-") or "chunkMs" not in config or model == f"nemotron-{config['chunkMs']}" for model in models):
                raise ValueError(f"{phase}: required configuration has no matching model")
        for config, model in product(configurations, models):
            if "chunkMs" in config and model.startswith("nemotron-") and model != f"nemotron-{config['chunkMs']}":
                continue
            for audio in fixtures:
                for preview in ([False, True] if phase == "release_to_insertion" else [None]):
                    rows = [r for r in records if r.get("phase") == phase and r.get("model") == model
                            and r.get("fixture") == audio and (preview is None or r.get("preview") is preview)
                            and ("configurations" not in policy or all(r.get("configuration", {}).get(key) == value for key, value in config.items()))]
                    label = f"{phase}/{model}/{audio}" + (f"/preview={preview}" if preview is not None else "")
                    label += "/" + json.dumps(config, sort_keys=True)
                    runs = [r.get("run") for r in rows]
                    expected_runs = rows[0].get("configuration", {}).get("runs") if rows else None
                    if (len(rows) < minimum or any(type(run) is not int or run < 1 for run in runs) or len(set(runs)) != len(runs)
                            or (expected_runs is not None and set(runs) != set(range(1, expected_runs + 1)))):
                        raise ValueError(f"{label}: missing or duplicate warm runs")
                    if any(r.get("status", "measured") != "measured" for r in rows):
                        raise ValueError(f"{label}: skipped or unsupported measurements cannot pass")
                    translated = config.get("translation", "off") != "off"
                    if any(r.get("languagePreserved") is not True for r in rows):
                        raise ValueError(f"{label}: language preservation failed or was not measured")
                    if cohorts:
                        for row in rows:
                            if row.get("scoring") != fixtures[audio]["scoring"]:
                                raise ValueError(f"{label}: scoring contract differs from reviewed reference")
                            number(row.get("cer"))
                            if language_sequence(row.get("scoredLanguages")) != language_sequence(fixtures[audio]["expectedLanguages"]):
                                raise ValueError(f"{label}: scored language sequence differs from reviewed reference")
                            reviewed_output(row, label)
                            if phase == "release_to_insertion" and not translated:
                                number(row.get("outputCER"))
                                if language_sequence(row.get("scoredOutputLanguages")) != language_sequence(fixtures[audio]["expectedLanguages"]):
                                    raise ValueError(f"{label}: scored output language sequence differs from reviewed reference")
                    if phase == "release_to_insertion" and any(r.get("translation") != config["translation"] or r.get("cleanup") != config["cleanup"] for r in rows):
                        raise ValueError(f"{label}: pipeline configuration mismatch")
                    if phase == "release_to_insertion" and config["cleanup"] == "model" and any(r.get("cleanupUnavailable") is not False for r in rows):
                        raise ValueError(f"{label}: model cleanup unavailable or unmeasured")
                    if phase == "release_to_insertion" and config["cleanup"] == "model":
                        for row in rows:
                            if any(type(row.get(field)) is not int or row[field] < 0
                                   for field in ("modelCalls", "modelAccepted", "modelFallbacks", "rulesSkipped")):
                                raise ValueError(f"{label}: missing or invalid model cleanup counts")
                            if row["modelFallbacks"] or (row["modelCalls"] == 0) != (row["modelAccepted"] == 0):
                                raise ValueError(f"{label}: model cleanup fallback or inconsistent counts")
                    if phase == "release_to_insertion" and translated and any(r.get("wasTranslated") is not True for r in rows):
                        raise ValueError(f"{label}: translation fell back or was not measured")
                    if translated:
                        reference = fixtures[audio].get("expectedTranslations", {}).get(config.get("target"))
                        if not isinstance(reference, dict) or reference.get("reviewed") is not True or not isinstance(reference.get("text"), str) or not reference["text"].strip():
                            raise ValueError(f"{label}: explicit reviewed target reference is required")
                        reference_hash = hashlib.sha256(reference["text"].encode()).hexdigest()
                        alternatives = reference.get("alternatives")
                        if alternatives is not None:
                            if (not isinstance(alternatives, list) or not alternatives or len(alternatives) > 8
                                    or any(not isinstance(text, str) or not text.strip() for text in alternatives)
                                    or len(set([reference["text"], *alternatives])) != len(alternatives) + 1):
                                raise ValueError(f"{label}: invalid reviewed reference alternatives")
                            hashes = [hashlib.sha256(text.encode()).hexdigest() for text in [reference["text"], *alternatives]]
                            binding = hashlib.sha256("\n".join(hashes).encode()).hexdigest()
                            if any(row.get("translationReferencesSHA256") != binding for row in rows):
                                raise ValueError(f"{label}: reviewed reference alternatives binding mismatch")
                        if any(part.lower() in ("hans", "hant") for part in config["target"].replace("_", "-").split("-")):
                            if any(row.get("targetVariantPreserved") is not True for row in rows):
                                raise ValueError(f"{label}: target script variant outcome is missing or failed")
                        if cohorts:
                            review = reference.get("referenceReview", {})
                            if (not isinstance(review, dict) or review.get("reviewed") is not True or review.get("independent") is not True
                                    or not isinstance(review.get("reviewer"), str) or not review["reviewer"].strip()):
                                raise ValueError(f"{label}: independent target reference review (including all alternatives) is required")
                            scoring = reference.get("scoring", {})
                            if (not isinstance(scoring, dict) or scoring.get("language") != config["target"]
                                    or scoring.get("wordUnit") != "natural-language" or scoring.get("normalization") != "nfc-grapheme-v1"):
                                raise ValueError(f"{label}: reviewed target scoring contract differs from requested target")
                            for row in rows:
                                if row.get("translationScoring") != reference["scoring"]:
                                    raise ValueError(f"{label}: target scoring contract mismatch")
                                number(row.get("translationCER"))
                        if any(r.get("target") != config["target"] or r.get("translationReferenceSHA256") != reference_hash
                               or r.get("targetLanguagePreserved") is not True or r.get("translationFailures") != 0
                               or r.get("translationSkipped") != 0 for r in rows):
                            raise ValueError(f"{label}: target reference, language or translation completion mismatch")
                    summary = {"case": label, "runs": len(rows), "metrics": {}}
                    if cohorts:
                        summary.update(cohort=fixtures[audio]["cohort"], verifiedCohorts=cohorts,
                                       scoring=fixtures[audio]["scoring"], qualityScope="bounded-release-subset")
                    case_limits = dict(limits)
                    if phase == "release_to_insertion" and not translated:
                        if any(r.get("outputLanguagePreserved") is not True for r in rows):
                            raise ValueError(f"{label}: cleanup output language preservation failed or unmeasured")
                        case_limits.update(outputWER=limits["wer"], outputMissingWords=limits["missingWords"])
                    if translated:
                        for metric, translated_metric in {"wer": "translationWER", "cer": "translationCER", "missingWords": "translationMissingWords"}.items():
                            if metric in limits:
                                case_limits[translated_metric] = limits[metric]
                    if translated and phase == "warm_live_stream":
                        calibration = policy.get("translationLatency", {})
                        calibrated = calibration.get("status") == "calibrated"
                        summary["translationLatency"] = "calibrated" if calibrated else "unverified"
                        for metric in TARGET_LATENCY:
                            values = [number(r.get(metric)) for r in rows]
                            summary["metrics"][metric] = {"p50": statistics.median(values), "p95": p95(values)}
                            if calibrated:
                                case_limits[metric] = number(calibration.get("limits", {}).get(metric))
                    for metric, limit in case_limits.items():
                        values = [number(r.get(metric)) for r in rows]
                        observed = max(values) if metric in ACCURACY else p95(values)
                        if observed > limit:
                            raise ValueError(f"{label}: {metric} {observed:.3f} exceeds {limit:.3f}")
                        summary["metrics"][metric] = {"p50": statistics.median(values), "p95": p95(values)}
                    if cohorts:
                        metrics = ["cer"] + (["translationCER"] if translated else ["outputCER"] if phase == "release_to_insertion" else [])
                        for metric in metrics:
                            values = [number(row.get(metric)) for row in rows]
                            summary["metrics"][metric] = {"p50": statistics.median(values), "p95": p95(values)}
                    if all(r.get("physicalMemoryBytes") is not None for r in rows):
                        values = [number(r["physicalMemoryBytes"]) for r in rows]
                        summary["metrics"]["physicalMemoryBytes"] = {"p50": statistics.median(values), "p95": p95(values)}
                    summaries.append(summary)
            if phase == "release_to_insertion" and config["cleanup"] == "model":
                for preview in (False, True):
                    covered = [r for r in records if r.get("phase") == phase and r.get("model") == model
                               and r.get("fixture") in fixtures and r.get("preview") is preview
                               and all(r.get("configuration", {}).get(key) == value for key, value in config.items())]
                    if not any(r["modelCalls"] > 0 and r["modelAccepted"] > 0 for r in covered):
                        raise ValueError(f"{phase}/{model}/{config}/preview={preview}: successful model cleanup coverage missing")
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
        collected = []
        current_corpus = benchmark_evidence.corpus(args.manifest.parent)
        current_corpus["manifestSHA256"] = benchmark_evidence.file_hash(args.manifest)
        manifest = json.loads(args.manifest.read_text())
        fixture_names = {fixture["audio"] for fixture in manifest["fixtures"]}
        if fixture_names != set(current_corpus["recordings"]):
            raise ValueError("recordings and reviewed manifest fixtures differ")
        for log in args.logs:
            lines = log.read_text().splitlines()
            stamps = [line for line in lines if line.startswith("SAIITY_QUALITY_SOURCE ")]
            if stamps != [f"SAIITY_QUALITY_SOURCE {args.revision} clean"]:
                raise ValueError(f"{log.name}: missing, dirty or stale source revision")
            headers = [json.loads(line.removeprefix("SAIITY_BENCHMARK_EVIDENCE ")) for line in lines
                       if line.startswith("SAIITY_BENCHMARK_EVIDENCE ")]
            if not headers or any(header != headers[0] for header in headers):
                raise ValueError(f"{log.name}: missing or inconsistent input fingerprints")
            evidence = headers[0]
            if not isinstance(evidence, dict):
                raise ValueError(f"{log.name}: input fingerprints are not an object")
            completions = [line for line in lines if line.startswith("SAIITY_QUALITY_COMPLETE ")]
            fingerprint = benchmark_evidence.digest(evidence)
            expected_completion = {"revision": args.revision, "beforeSHA256": fingerprint, "afterSHA256": fingerprint}
            if (len(completions) != 1 or lines[-1] != completions[0]
                    or json.loads(completions[0].removeprefix("SAIITY_QUALITY_COMPLETE ")) != expected_completion):
                raise ValueError(f"{log.name}: missing, duplicate or inconsistent post-run completion marker")
            if evidence.get("schema") != 1 or evidence.get("corpus") != current_corpus:
                raise ValueError(f"{log.name}: recordings or reference manifest differ from the measured corpus")
            hardware = evidence["hardware"]
            if not isinstance(hardware, dict) or not all(hardware.get(key) for key in ["model", "arch", "memoryBytes", "macOS", "osBuild", "toolchain", "swift", "sdk"]):
                raise ValueError(f"{log.name}: incomplete hardware/toolchain evidence")
            if number(hardware["memoryBytes"]) == 0:
                raise ValueError(f"{log.name}: invalid hardware memory")
            models = evidence["models"]
            if not isinstance(models, dict) or not models or any(not isinstance(value, str) or len(value) != 64
                                 or any(c not in "0123456789abcdef" for c in value) for value in models.values()):
                raise ValueError(f"{log.name}: missing model checksums")
            config = evidence["configuration"]
            if not isinstance(config, dict):
                raise ValueError(f"{log.name}: missing benchmark settings")
            profile = config["profile"]
            phase = {"asr": "warm_segmented_decode", "captions": "warm_live_stream", "pipeline": "release_to_insertion"}[profile]
            if (config.get("language") != "auto" or type(config.get("runs")) is not int or not 5 <= config["runs"] <= 10
                    or type(config.get("chunkMs")) is not int or config["chunkMs"] not in (1120, 2240)):
                raise ValueError(f"{log.name}: benchmark settings differ from release settings")
            if profile == "captions" and (config.get("realtime") is not True or config.get("cleanup") != "off"):
                raise ValueError(f"{log.name}: release caption timing requires paced capture")
            if profile == "pipeline" and (config.get("preview") != [False, True] or config.get("cleanup") not in ("rules", "model")):
                raise ValueError(f"{log.name}: pipeline settings differ from release settings")
            translation = config.get("translation")
            if translation not in ("off", "hy-mt2", "madlad"):
                raise ValueError(f"{log.name}: unsupported translation configuration")
            if translation != "off" and (translation not in models or not config.get("target") or config["target"] in ("auto", "und", "unknown")):
                raise ValueError(f"{log.name}: missing translation model fingerprint or target")
            if translation == "off" and config.get("target") is not None:
                raise ValueError(f"{log.name}: untranslated configuration has a target")
            cleanup_model = config.get("cleanupModel")
            if config.get("cleanup") == "model" and (not isinstance(cleanup_model, str) or "cleanup:" + cleanup_model not in models):
                raise ValueError(f"{log.name}: missing cleanup model fingerprint")
            measured = []
            for line in lines:
                for prefix in PREFIXES:
                    if line.startswith(prefix):
                        record = json.loads(line[len(prefix):])
                        if not isinstance(record, dict):
                            raise ValueError("benchmark record is not an object")
                        if record.get("configuration") != config:
                            raise ValueError(f"{log.name}: per-run configuration differs from fingerprint")
                        if record.get("model") not in models:
                            raise ValueError(f"{log.name}: measured model has no checksum")
                        if record["model"].startswith("nemotron-") and record["model"] != f"nemotron-{config['chunkMs']}":
                            raise ValueError(f"{log.name}: measured model differs from configured tier")
                        if record.get("phase") in ("warm_segmented_decode", "warm_live_stream", "release_to_insertion") and record["phase"] != phase:
                            raise ValueError(f"{log.name}: measurement phase differs from configured profile")
                        if record.get("phase") == phase and record.get("fixture") not in fixture_names:
                            raise ValueError(f"{log.name}: measured fixture has no reviewed reference")
                        measured.append(record)
            if any(record.get("phase") == phase and record.get("model") not in models for record in measured):
                raise ValueError(f"{log.name}: measured model has no checksum")
            for previous in collected:
                if previous["hardware"] != hardware:
                    raise ValueError("reports from different hardware/toolchains cannot be combined")
                if any(previous["models"][name] != models[name] for name in previous["models"].keys() & models.keys()):
                    raise ValueError("reports used different model bytes")
            collected.append(evidence)
            records.extend(record for record in measured if record.get("phase") == phase)
        result = verify(json.loads(args.policy.read_text()), manifest, records)
        print(json.dumps({"evidence": collected}, sort_keys=True, allow_nan=False))
        for summary in result:
            print(json.dumps(summary, sort_keys=True, allow_nan=False))
        if any(summary.get("translationLatency") == "unverified" for summary in result):
            raise ValueError("translated caption latency is unverified: target-corpus hard-budget calibration required")
        print(f"quality gate passed: {len(result)} fixture/model/configuration/preview cases")
    except (OSError, ValueError, KeyError, TypeError) as error:
        print(f"FATAL: quality gate failed: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
