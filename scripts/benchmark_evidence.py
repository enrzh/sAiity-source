#!/usr/bin/env python3
"""Fingerprint local benchmark inputs without retaining transcript contents."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import re
import subprocess
import sys


def digest(value):
    return hashlib.sha256(json.dumps(value, sort_keys=True, separators=(",", ":")).encode()).hexdigest()


def file_hash(path):
    result = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            result.update(block)
    return result.hexdigest()


def tree_hash(path):
    if path.is_file():
        return file_hash(path)
    files = sorted(p for p in path.rglob("*") if p.is_file())
    if not files:
        raise ValueError(f"missing or empty model: {path.name}")
    return digest({p.relative_to(path).as_posix(): file_hash(p) for p in files})


def corpus(directory):
    manifest = directory / "manifest.json"
    files = sorted(p for p in directory.iterdir() if p.suffix.lower() == ".wav" and p.is_file())
    if not files:
        raise ValueError("no benchmark recordings")
    recordings = {p.name: file_hash(p) for p in files}
    return {"manifestSHA256": file_hash(manifest), "recordings": recordings,
            "corpusSHA256": digest(recordings)}


def command(*args):
    return subprocess.check_output(args, text=True, stderr=subprocess.DEVNULL).strip()


def configuration(profile, environment=os.environ, *, product=None):
    if profile not in ("asr", "captions", "pipeline"):
        raise ValueError("unknown benchmark profile")
    if product is not None:
        fields = {"binary", "version", "build", "revision", "machineID", "powerMode", "thermalState", "memoryPressure"}
        if (profile != "pipeline" or not isinstance(product, dict) or set(product) != fields
                or any(not isinstance(product[field], str) or not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._-]*", product[field])
                       for field in fields - {"binary", "revision"})
                or not isinstance(product["revision"], str) or not re.fullmatch(r"[0-9a-f]{40}", product["revision"])
                or not isinstance(product["binary"], (str, Path)) or not str(product["binary"]).strip()
                or any(ord(c) < 32 for c in str(product["binary"]))):
            raise ValueError("product pipeline requires exact binary/version/build/revision and content-free machine/condition metadata")
    prefix = "SAIITY_CAPTION_BENCHMARK_" if profile == "captions" else "SAIITY_DICTATION_BENCHMARK_"
    chunk = int(environment.get(prefix + "CHUNK_MS", "2240")) if profile != "asr" else 2240
    runs = int(environment.get(prefix + "RUNS", "3")) if profile == "captions" else 5
    if product is not None:
        runs = int(environment.get(prefix + "RUNS", "5"))
    realtime = environment.get(prefix + "REALTIME", "1")
    cleanup = environment.get(prefix + "CLEANUP", "rules") if profile == "pipeline" else "off"
    cleanup_model = environment.get(prefix + "CLEANUP_MODEL") if cleanup == "model" else None
    translation = environment.get(prefix + "TRANSLATION", "off") if profile != "asr" else "off"
    target = environment.get(prefix + "TARGET", "de") if translation != "off" else None
    if chunk not in (1120, 2240) or not 1 <= runs <= (50 if product is not None else 10) or realtime not in ("0", "1"):
        raise ValueError("unsupported benchmark tier, runs or realtime setting")
    if cleanup not in ("off", "rules", "model") or translation not in ("off", "hy-mt2", "madlad"):
        raise ValueError("unknown cleanup or translation engine")
    if cleanup == "model" and (not cleanup_model or Path(cleanup_model).name != cleanup_model or not cleanup_model.endswith(".gguf")):
        raise ValueError("model cleanup requires an explicit installed GGUF filename")
    if target is not None and (not target.strip() or target in ("auto", "und", "unknown")):
        raise ValueError("translation requires an explicit target language")
    result = {"profile": profile, "language": "auto", "chunkMs": chunk, "runs": runs,
              "realtime": realtime == "1" if profile == "captions" else None,
              "preview": [False, True] if profile == "pipeline" else None,
              "cleanup": cleanup, "cleanupModel": cleanup_model, "translation": translation, "target": target}
    if product is not None:
        result.update({key: product[key] for key in ("powerMode", "thermalState", "memoryPressure")})
    return result


def require_clean_revision(revision):
    root = str(Path(__file__).resolve().parents[1])
    if command("git", "-C", root, "rev-parse", "HEAD") != revision:
        raise ValueError("product source revision differs from exact measured revision")
    if command("git", "-C", root, "status", "--porcelain", "--untracked-files=all"):
        raise ValueError("product qualification requires actual clean source")


def capture(directory, profile, model_root, environment=os.environ, *, product=None):
    config = configuration(profile, environment, product=product)
    if product is not None:
        binary = Path(product["binary"])
        if not binary.is_file() or binary.stat().st_size == 0:
            raise ValueError("explicit measured binary is missing, empty or not a file")
        require_clean_revision(product["revision"])
    chunk = config["chunkMs"]
    models = environment.get("SAIITY_CAPTION_BENCHMARK_MODELS", "nemotron").split(",") if profile == "captions" else ["nemotron"]
    if profile == "captions" and environment.get("SAIITY_CAPTION_BENCHMARK_WHISPER") == "1" and "whisper" not in models:
        models.append("whisper")
    if profile == "asr": models.append("whisper-base")
    paths = {}
    for model in models:
        if model == "nemotron": paths[f"nemotron-{chunk}"] = model_root / "nemotron-multilingual/multilingual" / f"{chunk}ms"
        elif model == "whisper-base": paths[model] = model_root / "whisper-openai_whisper-base"
        elif model in ("qwen-small", "qwen-large"):
            paths[model] = model_root / ("qwen3-asr-0.6b-4bit" if model == "qwen-small" else "qwen3-asr-1.7b-4bit")
        elif model == "whisper": paths["whisper-openai_whisper-large-v3-v20240930_626MB"] = model_root / "whisper-openai_whisper-large-v3-v20240930_626MB"
        else: raise ValueError(f"unknown benchmark model: {model}")
    if config["cleanupModel"]:
        paths["cleanup:" + config["cleanupModel"]] = model_root / "qwen" / config["cleanupModel"]
    translation = config["translation"]
    if translation == "madlad": paths["madlad"] = model_root / "madlad/int4"
    elif translation == "hy-mt2": paths["hy-mt2"] = model_root / "hymt2/Hy-MT2-1.8B-Q4_K_M.gguf"
    elif translation != "off": raise ValueError("unknown translation engine")
    hardware = {"model": command("sysctl", "-n", "hw.model"), "arch": platform.machine(),
                "memoryBytes": int(command("sysctl", "-n", "hw.memsize")),
                "macOS": command("sw_vers", "-productVersion"), "osBuild": command("sw_vers", "-buildVersion"),
                "toolchain": command("xcodebuild", "-version"), "swift": command("xcrun", "swift", "--version"),
                "sdk": command("xcrun", "--sdk", "macosx", "--show-sdk-version")}
    result = {"schema": 1, "corpus": corpus(directory), "models": {name: tree_hash(path) for name, path in paths.items()},
              "hardware": hardware, "configuration": config}
    if product is not None:
        result.update(revision=product["revision"], sourceState="clean",
                      appBuild={"version": product["version"], "build": product["build"], "binarySHA256": file_hash(binary)})
        hardware["machineID"] = product["machineID"]
        require_clean_revision(product["revision"])
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("fixtures", type=Path)
    parser.add_argument("--profile", required=True, choices=("asr", "captions", "pipeline"))
    parser.add_argument("--model-root", type=Path, default=Path.home() / "Library/Application Support/de.aiity.saiity/Models")
    parser.add_argument("--product", action="store_true", help="collect exact clean-source pipeline product evidence")
    parser.add_argument("--binary", type=Path, help="explicit app/test-host executable being measured")
    parser.add_argument("--version")
    parser.add_argument("--build")
    parser.add_argument("--revision")
    parser.add_argument("--machine-id", help="operator-supplied content-free machine identifier")
    parser.add_argument("--power-mode")
    parser.add_argument("--thermal-state")
    parser.add_argument("--memory-pressure")
    args = parser.parse_args()
    try:
        product = {"binary": args.binary, "version": args.version, "build": args.build, "revision": args.revision,
                   "machineID": args.machine_id, "powerMode": args.power_mode, "thermalState": args.thermal_state,
                   "memoryPressure": args.memory_pressure}
        if not args.product and any(value is not None for value in product.values()):
            raise ValueError("product metadata requires --product")
        print(json.dumps(capture(args.fixtures, args.profile, args.model_root, product=product if args.product else None),
                         sort_keys=True, allow_nan=False))
    except (OSError, ValueError, subprocess.CalledProcessError) as error:
        print(f"FATAL: benchmark evidence unavailable: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
