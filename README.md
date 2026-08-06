# sAiity

Live subtitles for whatever your Mac is playing — captured, recognised and
translated entirely on this machine. No account, no API key, and no audio ever
leaves the device. The only network traffic is one-time model downloads from
huggingface.co.

## What it does

- **Captions system audio.** ScreenCaptureKit taps what the Mac is playing
  (Screen Recording permission is how macOS gates system audio — there is no
  audio-only permission). Your microphone is never touched.
- **Recognises on-device.** Two streaming engines, selectable in Settings:
  - **Nemotron 3.5 multilingual** (default, 634 MB) — one model, ~121 language
    tags, identifies the spoken language from the audio itself. Two latency
    tiers: Balanced (2240 ms) and Fast (1120 ms), each its own download.
  - **Parakeet EOU** (437 MB) — English only, quicker to the first word,
    detects end-of-utterance itself.
- **Translates on-device**, optionally, as a second line under each caption:
  - **MADLAD-400-3B** (default, 1.86 GB) — a dedicated translation model
    covering ~450 languages including broad Asian and African coverage;
    ~0.2 s per sentence.
  - **A local LLM** — curated Qwen and Gemma GGUF builds, or your own model
    added by URL or picked from disk (Ollama blobs are GGUF files and can be
    chosen directly).
- **Commits on pauses.** A finished sentence is translated when the speaker
  stops, not when a time budget expires; CJK scripts commit correctly despite
  having no spaces.
- **Records transcripts** (off by default), exportable as SRT, Markdown or
  plain text — also from the command line.

## The caption bubble

A liquid-glass panel whose width is a *setting*, not a measurement — that is
what keeps it perfectly still while captions and translations stream through
it. It grows upward within a configurable screen margin, wraps long lines
instead of truncating, and can be dragged, resized at the edges (the cursor
shows it), or clicked through to the video underneath (default). Appearance is
configurable per line — size, weight, colour, opacity, max lines for the
original and the translation independently — with per-section resets. Reduce
Transparency and Increase Contrast are honoured automatically.

## Building

```
./build-app.sh            # build + sign build/sAiity.app (test hooks enabled)
./build-app.sh --install  # …and install to /Applications
./build-app.sh --notarize # Developer ID build: no test hooks, notarised, stapled
```

A bare `swift build` binary cannot hold Screen Recording permission — TCC keys
off a bundle identity — hence the assembled .app. The script bundles the
vendored `llama.framework`, the MLX metallib, and assembles `Credits.txt` from
the 40 dependency licences at build time. Versions are stamped from
`git describe`.

Tests (the plain `swift test` fails on this toolchain's debug C targets):

```
swift test -c release -Xswiftc -enable-testing -Xswiftc -DSAIITY_TEST_HOOKS
```

## Command line

```
sAiity --version
sAiity --list
sAiity --export srt|md|txt [sessionId]
```

## Layout

- `Sources/sAiity/ModelRegistry.swift` — every downloadable model: paths,
  completeness, deletion. One registry; the Models page renders it.
- `StreamingASRBackend.swift` — the shared streaming driver: single-pump
  serialisation (FluidAudio's actors are re-entrant across awaits), the
  cumulative→delta committer, pause/rolling commits, subtitle timing.
- `Translators.swift` + `EngineLanguages.swift` + `MADLADLanguages.swift` —
  translation engines and the per-engine language-code normalisation (MADLAD
  wants `zh`, never `zh-Hans`; an LLM wants an English language *name*).
- `OverlayWindow.swift` + `BubbleGeometry.swift` — the bubble; geometry is pure
  and unit-tested.
- `Onboarding*.swift` — first-run: permission with live status, model choice
  with sizes stated before download.
- `TestHooks.swift` — `SAIITY_AUTOSTART` / `SAIITY_OPEN_SETTINGS` /
  `SAIITY_ONBOARDING=force`, compiled out of `--notarize` builds.

## Privacy

Recognition, translation and transcripts are processed and stored locally.
Transcripts are off by default and live under
`~/Library/Application Support/de.aiity.saiity/Sessions`. Model weights are
downloaded once into `…/Models` and each row in Settings → Models names its
licence; Remove All frees everything.

## Licence

MIT — see [LICENSE](LICENSE). Third-party notices are assembled into the app
bundle at build time and shown in the About window.
