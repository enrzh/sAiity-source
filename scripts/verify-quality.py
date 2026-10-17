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


def sha256(value):
    return isinstance(value, str) and len(value) == 64 and all(c in "0123456789abcdef" for c in value)


def verify_product(policy, manifest, records, observations, revision):
    """Validate supplied independent evidence; never infer visible UI from native dispatch."""
    if (not isinstance(policy, dict) or not isinstance(manifest, dict)
            or not isinstance(manifest.get("fixtures"), list) or not isinstance(records, list)):
        raise ValueError("product policy, manifest and records have invalid shapes")
    limits = policy["limits"]
    ceilings = {"captureStart": 0.150, "rules": 0.700, "model": 1.2, "translated": 2.5,
                "stopToCompositorHidden": 0.100, "stopToInputStopped": 0.250}
    if (type(policy.get("schema")) is not int or policy["schema"] != 1 or type(policy.get("minimumWarmRuns")) is not int or policy["minimumWarmRuns"] < 50
            or policy.get("maxShortSeconds") != 10 or policy.get("longSeconds") != 30
            or number(policy.get("cleanWER")) > 0.05 or number(policy.get("translatedWER")) > 0.25
            or not isinstance(revision, str) or len(revision) != 40 or any(c not in "0123456789abcdef" for c in revision)):
        raise ValueError("product policy requires 50 warm short runs, fixed duration boundaries, accuracy ceilings and exact revision")
    cold = policy.get("coldObservations", {})
    if not isinstance(cold, dict) or set(cold) != {"cold-start", "post-eviction"} or any(type(v) is not int or v < 5 for v in cold.values()):
        raise ValueError("separately defined cold-start and post-eviction observations are required")
    if not isinstance(limits, dict) or set(limits) != set(ceilings) or any(number(limits[key]) > value for key, value in ceilings.items()):
        raise ValueError("product budgets cannot relax accepted targets")
    fixtures = {}
    for fixture in manifest["fixtures"]:
        if not isinstance(fixture, dict) or not isinstance(fixture.get("audio"), str):
            raise ValueError("invalid reviewed product fixture")
        audio = fixture["audio"]
        if (audio in fixtures or Path(audio).name != audio or not audio.endswith(".wav")
                or not isinstance(fixture.get("expectedText"), str) or not fixture["expectedText"].strip()
                or fixture.get("condition") not in ("clean", "difficult", "noisy")
                or number(fixture.get("durationSeconds")) == 0):
            raise ValueError("invalid reviewed product fixture or duration/condition")
        language_sequence(fixture.get("expectedLanguages"))
        fixtures[audio] = fixture
    evidence_policy = policy["languageEvidence"]
    if (not isinstance(evidence_policy, dict) or evidence_policy.get("requiredCohorts") != ["en", "de"]
            or any(type(evidence_policy.get(k)) is not int or evidence_policy[k] < 2 for k in ("minimumClips", "minimumSpeakers"))):
        raise ValueError("clean EN/DE qualification requires multiple reviewed clips and speakers")
    reviewed_coverage({"languageEvidence": evidence_policy}, fixtures)
    cases = policy.get("requiredCases")
    if (not isinstance(cases, list) or not cases or any(not isinstance(c, dict)
            or c.get("cohort") not in ("en", "de") or not isinstance(c.get("model"), str) or not c["model"].strip()
            or not isinstance(c.get("configuration"), dict)
            or c["configuration"].get("cleanup") not in ("rules", "model")
            or not isinstance(c["configuration"].get("translation"), str)
            or "target" not in c["configuration"] for c in cases)
            or len({benchmark_evidence.digest(c) for c in cases}) != len(cases)):
        raise ValueError("explicit unique product model/cohort/processing cases are required")
    if not records or not isinstance(observations, list) or not observations:
        raise ValueError("real external observations are missing")
    observed = {}
    observation_fields = {"runID", "outputSHA256", "evidenceSHA256", "endpoint", "observer", "targetApp",
                          "physicalInputObserved", "compositorHiddenObserved", "inputStoppedObserved", "durationsSeconds", "qualityReview"}
    for observation in observations:
        if (not isinstance(observation, dict) or not isinstance(observation.get("runID"), str)
                or set(observation) != observation_fields or not observation["runID"].strip() or observation["runID"] in observed):
            raise ValueError("missing or duplicate external observation runID")
        observed[observation["runID"]] = observation
    groups, run_ids, headers = {}, set(), {}
    source_models, source_hardware, source_build = {}, None, None
    phases = ("capture", "modelLoad", "nativeQueue", "recognition", "cleanup", "translation", "delivery", "drain")
    timing = ("captureStart", "releaseToEndpoint", "stopToCompositorHidden", "stopToInputStopped")
    for row in records:
        if not isinstance(row, dict):
            raise ValueError("product record is not an object")
        run_id = row.get("runID")
        if not isinstance(run_id, str) or not run_id.strip() or run_id in run_ids or run_id not in observed:
            raise ValueError("missing or duplicate native runID or external observation")
        run_ids.add(run_id)
        header = row.get("evidence", {})
        if not isinstance(header, dict):
            raise ValueError("missing product evidence header")
        binding = benchmark_evidence.digest(header)
        if binding not in headers:
            if header.get("schema") != 1 or header.get("revision") != revision or header.get("sourceState") != "clean":
                raise ValueError("stale, dirty or missing exact product source revision")
            build, hardware, models, corpus = (header.get(k, {}) for k in ("appBuild", "hardware", "models", "corpus"))
            if (not isinstance(build, dict) or not sha256(build.get("binarySHA256"))
                    or any(not isinstance(build.get(k), str) or not build[k].strip() for k in ("version", "build"))):
                raise ValueError("exact app build and binary fingerprint are required")
            if (not isinstance(hardware, dict) or any(not isinstance(hardware.get(k), str) or not hardware[k].strip()
                    for k in ("model", "arch", "macOS", "osBuild", "toolchain", "swift", "sdk", "machineID"))
                    or type(hardware.get("memoryBytes")) is not int or hardware["memoryBytes"] <= 0):
                raise ValueError("complete hardware/machine identity is required")
            if (not isinstance(models, dict) or not models or any(not isinstance(k, str) or not k.strip() or not sha256(v) for k, v in models.items())):
                raise ValueError("exact model fingerprints are required")
            if (not isinstance(corpus, dict) or not sha256(corpus.get("manifestSHA256"))
                    or not isinstance(corpus.get("recordings"), dict) or set(corpus["recordings"]) != set(fixtures)
                    or any(not sha256(v) for v in corpus["recordings"].values())
                    or corpus.get("corpusSHA256") != benchmark_evidence.digest(corpus["recordings"])):
                raise ValueError("reviewed corpus fingerprints are required")
            if source_hardware is not None and (source_hardware != hardware or source_build != build
                    or next(iter(headers.values()))["corpus"] != corpus):
                raise ValueError("different hardware, app builds or corpora cannot be combined")
            if any(source_models[k] != models[k] for k in source_models.keys() & models.keys()):
                raise ValueError("different model bytes cannot be combined")
            source_hardware, source_build = hardware, build
            source_models.update(models)
            headers[binding] = header
        config = header.get("configuration", {})
        if (not isinstance(config, dict) or row.get("configuration") != config or config.get("profile") != "pipeline"
                or config.get("language") != "auto" or type(config.get("runs")) is not int or config["runs"] < 1
                or type(config.get("chunkMs")) is not int or config["chunkMs"] not in (1120, 2240)
                or config.get("preview") != [False, True] or any(type(v) is not bool for v in config["preview"])
                or any(not isinstance(config.get(k), str) or not config[k].strip() for k in ("powerMode", "thermalState", "memoryPressure"))
                or config.get("cleanup") not in ("rules", "model") or not isinstance(config.get("translation"), str)
                or not config["translation"].strip() or "target" not in config or "cleanupModel" not in config):
            raise ValueError("complete matching product configuration is required")
        models = header["models"]
        model = row.get("model")
        if not isinstance(model, str) or model not in models or (model.startswith("nemotron-") and model != f"nemotron-{config['chunkMs']}"):
            raise ValueError("measured ASR model has no matching fingerprint/tier")
        translated = config["translation"] != "off"
        if translated:
            if config["translation"] not in models or not isinstance(config["target"], str):
                raise ValueError("translation fingerprint and explicit target are required")
            language_sequence([config["target"]])
        elif config["target"] is not None:
            raise ValueError("untranslated configuration has a target")
        if config["cleanup"] == "model":
            if not isinstance(config["cleanupModel"], str) or "cleanup:" + config["cleanupModel"] not in models:
                raise ValueError("cleanup model fingerprint is required")
            counts = [row.get(k) for k in ("modelCalls", "modelAccepted", "modelFallbacks", "rulesSkipped")]
            if (row.get("cleanupUnavailable") is not False or any(type(v) is not int or v < 0 for v in counts)
                    or counts[2] != 0 or counts[1] != counts[0] or (counts[0] == 0 and counts[3] == 0)):
                raise ValueError("model cleanup fallback, unavailable or inconsistent counts")
        elif config["cleanupModel"] is not None:
            raise ValueError("rules cleanup unexpectedly fingerprints a cleanup model")
        if (row.get("phase") != "release_to_insertion" or row.get("status", "measured") != "measured"
                or type(row.get("run")) is not int or row["run"] < 1 or type(row.get("preview")) is not bool
                or row.get("warmState") not in ("warm", *cold)
                or any(row.get(k) != config[k] for k in ("cleanup", "translation", "target"))):
            raise ValueError("invalid product run, lifecycle, preview or processing outcome")
        if not isinstance(row.get("fixture"), str):
            raise ValueError("invalid product fixture name")
        fixture = fixtures.get(row["fixture"])
        if fixture is None or number(row.get("phraseSeconds")) != fixture["durationSeconds"]:
            raise ValueError("product phrase duration differs from reviewed fixture")
        observation = observed[run_id]
        endpoint = observation.get("endpoint")
        if (row.get("deliveryEndpoint") not in ("copied", "paste-dispatched")
                or endpoint not in ("copied", "paste-dispatched", "visible-insertion")
                or (endpoint == "copied" and row["deliveryEndpoint"] != "copied")
                or (endpoint != "copied" and row["deliveryEndpoint"] != "paste-dispatched")):
            raise ValueError("external endpoint cannot be inferred from native copy/paste dispatch")
        observer = observation.get("observer", {})
        if (not sha256(row.get("outputSHA256")) or observation.get("outputSHA256") != row["outputSHA256"]
                or observation.get("evidenceSHA256") != binding or not isinstance(observer, dict)
                or set(observer) != {"identity", "independent", "method"}
                or observer.get("independent") is not True or not isinstance(observer.get("identity"), str) or not observer["identity"].strip()
                or observer.get("method") not in ("external-accessibility", "external-video", "human-observation")
                or not isinstance(observation.get("targetApp"), str) or not observation["targetApp"].strip()
                or any(observation.get(k) is not True for k in ("physicalInputObserved", "compositorHiddenObserved", "inputStoppedObserved"))):
            raise ValueError("independent exact-output/environment-bound external physical/UI observation is required")
        durations, phase_seconds = observation.get("durationsSeconds", {}), row.get("phaseSeconds", {})
        if (not isinstance(durations, dict) or not isinstance(phase_seconds, dict)
                or set(durations) != set(timing) or set(phase_seconds) != set(phases)):
            raise ValueError("external and native phase durations are required")
        for key in timing: number(durations.get(key))
        for key in phases: number(phase_seconds.get(key))
        review = observation.get("qualityReview", {})
        reviewed_output(dict(row, qualityReview=review), run_id)
        if (review.get("evidenceSHA256") != binding or set(review) != {
                "reviewed", "independent", "reviewer", "outputSHA256", "evidenceSHA256",
                "meaning", "names", "numbers", "negation", "omissions", "naturalness"}):
            raise ValueError("quality review differs from exact output/environment binding")
        if (row.get("scoring") != fixture["scoring"]
                or language_sequence(row.get("scoredLanguages")) != language_sequence(fixture["expectedLanguages"])
                or row.get("languagePreserved") is not True):
            raise ValueError("source scoring/language preservation differs from reviewed reference")
        number(row.get("cer"))
        metrics = {"wer": policy["cleanWER"] if fixture["condition"] == "clean" else 0.25,
                   "missingWords": 0, "droppedAudioSeconds": 0}
        if translated:
            references = fixture.get("expectedTranslations", {})
            if not isinstance(references, dict) or not isinstance(references.get(config["target"]), dict):
                raise ValueError("reviewed target reference is required")
            reference = references[config["target"]]
            reference_review = reference.get("referenceReview", {})
            if (not isinstance(reference_review, dict) or reference.get("reviewed") is not True or not isinstance(reference.get("text"), str) or not reference["text"].strip()
                    or reference_review.get("reviewed") is not True or reference_review.get("independent") is not True
                    or not isinstance(reference_review.get("reviewer"), str) or not reference_review["reviewer"].strip()
                    or reference.get("scoring") != {"language": config["target"], "wordUnit": "natural-language", "normalization": "nfc-grapheme-v1"}
                    or row.get("translationScoring") != reference["scoring"]
                    or row.get("translationReferenceSHA256") != hashlib.sha256(reference["text"].encode()).hexdigest()
                    or row.get("wasTranslated") is not True or row.get("targetLanguagePreserved") is not True
                    or any(type(row.get(k)) is not int or row[k] != 0 for k in ("translationFailures", "translationSkipped"))):
                raise ValueError("completed translation with independent target/pair review is required")
            alternatives = reference.get("alternatives")
            if alternatives is not None:
                if (not isinstance(alternatives, list) or not 1 <= len(alternatives) <= 8
                        or any(not isinstance(v, str) or not v.strip() for v in alternatives)
                        or len(set([reference["text"], *alternatives])) != len(alternatives) + 1):
                    raise ValueError("invalid reviewed translation alternatives")
                hashes = [hashlib.sha256(v.encode()).hexdigest() for v in [reference["text"], *alternatives]]
                if row.get("translationReferencesSHA256") != hashlib.sha256("\n".join(hashes).encode()).hexdigest():
                    raise ValueError("translation alternatives binding mismatch")
            if any(v.lower() in ("hans", "hant") for v in config["target"].replace("_", "-").split("-")) and row.get("targetVariantPreserved") is not True:
                raise ValueError("translation script outcome is missing")
            number(row.get("translationCER"))
            metrics.update(translationWER=policy["translatedWER"], translationMissingWords=0)
        else:
            if (row.get("outputLanguagePreserved") is not True
                    or language_sequence(row.get("scoredOutputLanguages")) != language_sequence(fixture["expectedLanguages"])):
                raise ValueError("final output language preservation failed or unmeasured")
            number(row.get("outputCER"))
            metrics.update(outputWER=metrics["wer"], outputMissingWords=0)
        for metric, limit in metrics.items():
            if number(row.get(metric)) > limit:
                raise ValueError(f"{run_id}: {metric} exceeds product accuracy/loss budget {limit}")
        seconds = fixture["durationSeconds"]
        group = {"warmState": row["warmState"], "duration": "short" if seconds <= 10 else "medium" if seconds < 30 else "long",
                 "condition": fixture["condition"], "cohort": fixture["cohort"], "model": model,
                 "configuration": {k: v for k, v in config.items() if k != "runs"}, "preview": row["preview"],
                 "endpoint": endpoint, "targetApp": observation["targetApp"]}
        key = benchmark_evidence.digest(group)
        groups.setdefault(key, (group, []))[1].append((row, observation))
    if run_ids != set(observed):
        raise ValueError("external observations contain unmatched runs")
    summaries = []
    for group, pairs in groups.values():
        rows = [pair[0] for pair in pairs]
        short_visible = group["condition"] == "clean" and group["duration"] == "short" and group["endpoint"] == "visible-insertion"
        if short_visible:
            minimum = policy["minimumWarmRuns"] if group["warmState"] == "warm" else cold[group["warmState"]]
            clips = {r["fixture"] for r in rows}
            speakers = {fixtures[a]["provenance"]["speaker"] for a in clips}
            if len(rows) < minimum or len(clips) < evidence_policy["minimumClips"] or len(speakers) < evidence_policy["minimumSpeakers"]:
                raise ValueError(f"{group}: missing visible-insertion repetition/clip/speaker coverage")
            if group["configuration"]["cleanup"] == "model" and not any(r["modelAccepted"] > 0 for r in rows):
                raise ValueError("successful model cleanup coverage missing")
        summary = dict(group, runs=len(rows), metrics={}, phaseSeconds={}, qualityScope="preliminary-product-subset")
        for metric in timing:
            values = [p[1]["durationsSeconds"][metric] for p in pairs]
            summary["metrics"][metric] = {"p50": statistics.median(values), "p95": p95(values)}
            if short_visible and group["warmState"] == "warm":
                limit_key = ("translated" if group["configuration"]["translation"] != "off" else group["configuration"]["cleanup"]) if metric == "releaseToEndpoint" else metric
                if p95(values) > limits[limit_key]:
                    raise ValueError(f"{group}: {metric} p95 exceeds {limits[limit_key]}")
        for metric in phases:
            values = [r["phaseSeconds"][metric] for r in rows]
            summary["phaseSeconds"][metric] = {"p50": statistics.median(values), "p95": p95(values)}
        for metric in ("wer", "cer", "missingWords", "droppedAudioSeconds", "translationWER", "translationCER", "translationMissingWords") if group["configuration"]["translation"] != "off" else ("wer", "cer", "missingWords", "droppedAudioSeconds", "outputWER", "outputCER", "outputMissingWords"):
            values = [r[metric] for r in rows]
            summary["metrics"][metric] = {"max": max(values), "p50": statistics.median(values), "p95": p95(values)}
        summaries.append(summary)
    for case, state, preview in product(cases, ("warm", *cold), (False, True)):
        if not any(s["warmState"] == state and s["preview"] is preview and s["duration"] == "short"
                   and s["condition"] == "clean" and s["endpoint"] == "visible-insertion"
                   and s["cohort"] == case["cohort"] and s["model"] == case["model"]
                   and all(s["configuration"].get(k) == v for k, v in case["configuration"].items()) for s in summaries):
            raise ValueError(f"{case}/{state}/preview={preview}: visible-insertion product coverage missing")
    return summaries


def product_logs(args):
    if args.observations is None:
        raise ValueError("real external observations are required (--observations)")
    manifest = json.loads(args.manifest.read_text())
    records = []
    manifest_hash = benchmark_evidence.file_hash(args.manifest)
    for log in args.logs:
        lines = log.read_text().splitlines()
        stamps = [v for v in lines if v.startswith("SAIITY_QUALITY_SOURCE ")]
        headers = [json.loads(v.removeprefix("SAIITY_BENCHMARK_EVIDENCE ")) for v in lines if v.startswith("SAIITY_BENCHMARK_EVIDENCE ")]
        if stamps != [f"SAIITY_QUALITY_SOURCE {args.revision} clean"] or not headers or any(h != headers[0] for h in headers):
            raise ValueError("missing, dirty or inconsistent product source/fingerprint markers")
        header = headers[0]
        if (not isinstance(header, dict) or not isinstance(header.get("corpus"), dict)
                or header["corpus"].get("manifestSHA256") != manifest_hash):
            raise ValueError("reviewed product manifest fingerprint mismatch")
        fingerprint = benchmark_evidence.digest(header)
        completions = [v for v in lines if v.startswith("SAIITY_QUALITY_COMPLETE ")]
        if (len(completions) != 1 or lines[-1] != completions[0]
                or json.loads(completions[0].removeprefix("SAIITY_QUALITY_COMPLETE ")) != {
                    "revision": args.revision, "beforeSHA256": fingerprint, "afterSHA256": fingerprint}):
            raise ValueError("missing or inconsistent post-run product completion marker")
        batch = []
        for line in lines:
            for prefix in ("SAIITY_PRODUCT_BENCHMARK ", "SAIITY_ASR_BENCHMARK "):
                if line.startswith(prefix):
                    row = json.loads(line[len(prefix):])
                    if not isinstance(row, dict) or "evidence" in row:
                        raise ValueError("invalid product record or overridden batch evidence")
                    batch.append(dict(row, evidence=header))
        if not batch:
            raise ValueError("empty product batch cannot qualify")
        records.extend(batch)
    return verify_product(json.loads(args.policy.read_text()), manifest, records,
                          json.loads(args.observations.read_text()), args.revision)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--manifest", required=True, type=Path)
    parser.add_argument("--policy", type=Path)
    parser.add_argument("--product", action="store_true", help="qualify externally observed short dictation; legacy release gate is separate")
    parser.add_argument("--observations", type=Path, help="content-free external product observations JSON array")
    parser.add_argument("--revision", required=True, help="exact clean Git revision measured by every log")
    parser.add_argument("logs", nargs="+", type=Path)
    args = parser.parse_args()
    if args.policy is None:
        args.policy = Path(__file__).resolve().parents[1] / "docs/benchmarks" / ("product-quality.json" if args.product else "release-quality.json")
    try:
        if args.product:
            result = product_logs(args)
            for summary in result:
                print(json.dumps(summary, sort_keys=True, allow_nan=False))
            print(f"product qualification passed: {len(result)} separately observed groups; broader release gate remains separate")
            return 0
        if args.observations is not None:
            raise ValueError("--observations requires --product")
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
    except (OSError, ValueError, KeyError, TypeError, AttributeError) as error:
        print(f"FATAL: {'product qualification UNVERIFIED' if args.product else 'quality gate failed'}: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
