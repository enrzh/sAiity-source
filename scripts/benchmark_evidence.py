#!/usr/bin/env python3
"""Fingerprint local benchmark inputs without retaining transcript contents."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
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


def capture(directory, profile, model_root, environment=os.environ):
    chunk = environment.get("SAIITY_CAPTION_BENCHMARK_CHUNK_MS", "2240") if profile == "captions" else "2240"
    models = environment.get("SAIITY_CAPTION_BENCHMARK_MODELS", "nemotron").split(",") if profile == "captions" else ["nemotron"]
    if profile == "captions" and environment.get("SAIITY_CAPTION_BENCHMARK_WHISPER") == "1" and "whisper" not in models:
        models.append("whisper")
    if profile == "asr": models.append("whisper-base")
    if profile == "pipeline" and (environment.get("SAIITY_DICTATION_BENCHMARK_CLEANUP", "rules") != "rules"
                                  or environment.get("SAIITY_DICTATION_BENCHMARK_TRANSLATION", "off") != "off"):
        raise ValueError("pipeline release evidence requires rules cleanup and translation off")
    paths = {}
    for model in models:
        if model == "nemotron": paths[f"nemotron-{chunk}"] = model_root / "nemotron-multilingual/multilingual" / f"{chunk}ms"
        elif model == "whisper-base": paths[model] = model_root / "whisper-openai_whisper-base"
        elif model in ("qwen-small", "qwen-large"):
            paths[model] = model_root / ("qwen3-asr-0.6b-4bit" if model == "qwen-small" else "qwen3-asr-1.7b-4bit")
        elif model == "whisper": paths["whisper-openai_whisper-large-v3-v20240930_626MB"] = model_root / "whisper-openai_whisper-large-v3-v20240930_626MB"
        else: raise ValueError(f"unknown benchmark model: {model}")
    translation = environment.get("SAIITY_CAPTION_BENCHMARK_TRANSLATION", "off") if profile == "captions" else "off"
    if translation == "madlad": paths["madlad"] = model_root / "madlad/int4"
    elif translation == "hy-mt2": paths["hy-mt2"] = model_root / "hymt2/Hy-MT2-1.8B-Q4_K_M.gguf"
    elif translation != "off": raise ValueError("unknown translation engine")
    configuration = {"profile": profile, "language": "auto", "chunkMs": int(chunk),
                     "runs": int(environment.get("SAIITY_CAPTION_BENCHMARK_RUNS", "3")) if profile == "captions" else 5,
                     "realtime": environment.get("SAIITY_CAPTION_BENCHMARK_REALTIME", "1") != "0" if profile == "captions" else None,
                     "preview": [False, True] if profile == "pipeline" else None,
                     "cleanup": "rules" if profile == "pipeline" else "off", "translation": translation,
                     "target": environment.get("SAIITY_CAPTION_BENCHMARK_TARGET", "de") if translation != "off" else None}
    hardware = {"model": command("sysctl", "-n", "hw.model"), "arch": platform.machine(),
                "memoryBytes": int(command("sysctl", "-n", "hw.memsize")),
                "macOS": command("sw_vers", "-productVersion"), "osBuild": command("sw_vers", "-buildVersion"),
                "toolchain": command("xcodebuild", "-version"), "swift": command("xcrun", "swift", "--version"),
                "sdk": command("xcrun", "--sdk", "macosx", "--show-sdk-version")}
    return {"schema": 1, "corpus": corpus(directory), "models": {name: tree_hash(path) for name, path in paths.items()},
            "hardware": hardware, "configuration": configuration}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("fixtures", type=Path)
    parser.add_argument("--profile", required=True, choices=("asr", "captions", "pipeline"))
    parser.add_argument("--model-root", type=Path, default=Path.home() / "Library/Application Support/de.aiity.saiity/Models")
    args = parser.parse_args()
    try:
        print(json.dumps(capture(args.fixtures, args.profile, args.model_root), sort_keys=True, allow_nan=False))
    except (OSError, ValueError, subprocess.CalledProcessError) as error:
        print(f"FATAL: benchmark evidence unavailable: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
