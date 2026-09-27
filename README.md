# sAiity

Live subtitles for whatever your Mac is playing.

sAiity captures system audio, recognises speech, and translates it on the Mac.
It can save bilingual transcripts locally and provide press-to-talk dictation
to the app that currently has focus.

**No account. No API key. No audio leaves the Mac.**

- Native SwiftUI/AppKit app for macOS 26 on Apple Silicon
- Streaming captions from system audio
- Optional translation below the original caption
- Local transcripts with SRT, WebVTT, Markdown, and text export
- Press-to-talk dictation with a configurable key
- A dictated result is inserted into the app you were in when you started
  speaking when possible, and always remains on the clipboard. Password fields
  are refused, as they are by macOS dictation
- German, English, French, Spanish, and Japanese interface localizations
- No Windows release target. The repository carries Windows packaging and
  overlay-build workflows, but no published Windows binary

## Translation

MADLAD-400-3B is the translation engine. It covers a broad range of languages
and runs on-device.

Models are downloaded on first use and stored locally. The app does not ship
model weights.

## Dictation

Hold the configured press-to-talk key while speaking. Release it to transcribe
locally, clean the result, and insert it into the focused app. When there is no
focused editable field, the result is copied without attempting a paste.

Dictation is a separate microphone-only session. It does not write to saved
caption transcripts and it does not require sAiity to be the frontmost app.
Captions and dictation do not own the microphone at the same time.

## Privacy

System audio is captured through ScreenCaptureKit. Screen Recording permission
is the macOS permission that gates this access.

The optional microphone mixer for captions is off by default. Dictation opens
the microphone only while the press-to-talk key is held. Recognition, translation,
and saved transcripts stay on the device.

Models are downloaded from huggingface.co. Update checks are opt-in and send no
audio, transcript, or account identifier.

## Source policy

This repository is public for inspection. No license is granted to copy, modify, or redistribute the source.

The release page is the supported way to obtain the application. Security
reports can be sent through [aiity.de](https://aiity.de).

## Build

The app is assembled as a signed bundle because macOS permissions are bound to
the application identity, not to a bare SwiftPM executable.

    ./build-app.sh
    ./build-app.sh --install
    ./build-app.sh --notarize

These three are different products, and the difference matters when a check
fails:

| Command | Test hooks | Signature | For |
| --- | --- | --- | --- |
| `./build-app.sh` | compiled in | best available, else ad-hoc | local development |
| `./build-app.sh --notarize` | compiled out | requires Developer ID | a release |

`verify-release.sh` rejects a binary that still carries the test hooks, so it
only passes for a `--notarize` build. That is deliberate: the hooks exist to
start system-audio capture from a script with no UI and no consent, which is
reasonable while developing and not a thing to notarise. Run the release
checks against a notarised bundle.

Both build paths need a full git checkout, not a shallow one. The version stamp
comes from `git describe --tags` and the build number from
`git rev-list --count HEAD`, and on a depth-1 clone that count is 1 — which
both build-app.sh's own stamp assertion and `verify-release.sh` read as an
unstamped bundle.

To check that a bundle really launches — a real `NSApplication`, the real
`AppDelegate`, one turn of the run loop, and a window the window server agrees
exists — run:

    build/sAiity.app/Contents/MacOS/sAiity --selftest

It exits 0 on success, 1 if a check failed, and 70 if the launch never
finished. Over a plain ssh session, where there is no window server to launch
a GUI into, it reports a skip and exits 0. CI runs this after assembling the
bundle.

The release test command is:

    DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}" xcrun swift test -c release -Xswiftc -enable-testing -Xswiftc -DSAIITY_TEST_HOOKS

A plain debug test run is not the supported verification path on this
toolchain.

For a local real-model regression run, keep recordings outside the repository
and provide a `manifest.json` beside 1...12 mono Float32 16 kHz WAV fixtures:

    SAIITY_ASR_BENCHMARK_DIR=/absolute/fixtures scripts/model-matrix.sh

The matrix records cold model preparation, sequential segmented latency, real-
time factor, WER, and language-span preservation. It never downloads weights
and fails when the benchmark test is skipped. Release bundles are checked with
`scripts/verify-release.sh`; generated Sparkle feeds are checked against their
ZIP with `scripts/validate-appcast.sh`.

For a real-time live-caption regression run, use the same fixture format with
`scripts/caption-matrix.sh`. It records first volatile/final caption latency,
backlog, dropped audio, and real-time factor without downloading model weights:

    SAIITY_CAPTION_BENCHMARK_DIR=/absolute/fixtures scripts/caption-matrix.sh

The build scripts use `/Applications/Xcode.app/Contents/Developer` through
`DEVELOPER_DIR` by default and do not change global `xcode-select`. Override
that variable when another installed Xcode is required.

Model downloads check the available volume capacity before starting. Downloads
are staged and can be cancelled or resumed from Settings; model bytes are not
included in the application bundle.

## Layout

| Path | Responsibility |
| --- | --- |
| Sources/sAiity/StreamingASRBackend.swift | Streaming recognition, partial text, pauses, and sentence commits |
| Sources/sAiity/Translators.swift | MADLAD and local-LLM translation lifecycle |
| Sources/sAiity/HyMT2Translator.swift | Hy-MT2 model template, language set, and generation |
| Sources/sAiity/DictationController.swift | Press-to-talk dictation lifecycle |
| Sources/sAiity/DictationToastWindow.swift | Dictation status surface above other apps |
| Sources/sAiity/TranscriptStore.swift | Local transcript storage and retention |
| Sources/sAiity/OverlayWindow.swift | Caption bubble geometry and presentation |
| Resources/Localizable.xcstrings | User-facing localization catalog |

## What's new in 2.5.5

- Settings is a proper native window: a real sidebar, native toolbar controls,
  and one full-row disclosure header instead of a chevron you have to aim at.
- Transcripts have their own page with search, export, and retention, and
  interrupted model downloads can be cleaned up from the Models page beside
  Refresh and Remove All.
- Recognition is Nemotron and translation is MADLAD, and nothing else is
  offered; previously downloaded Parakeet and Hy-MT2 data is kept readable and
  is only offered for cleanup.
- Live captions use adaptive speech activity detection, so natural pauses close
  captions without confusing healthy digital silence with a stalled stream.
- Cumulative recognizer revisions are reconciled into stable text and a
  revisable tail, reducing duplicated words and lost text around pauses.
- Caption processing stays bounded with one in-flight ASR operation, protected
  audio backlog limits, sample-clock timestamps, and diagnostics for latency and
  dropped audio.
- Script-aware joining keeps Latin spacing readable while preserving CJK and
  other spaceless scripts; translation requests are cached and stale results
  cannot repaint a newer session.

## Release

The current signed and notarized release is [sAiity 2.5.5](https://github.com/enrzh/sAiity/releases/tag/v2.5.5).

- [Download the DMG](https://github.com/enrzh/sAiity/releases/download/v2.5.5/sAiity-2.5.5.dmg)
- [Download the ZIP](https://github.com/enrzh/sAiity/releases/download/v2.5.5/sAiity-2.5.5.zip)
- [Sparkle update feed](https://enrzh.github.io/sAiity/appcast.xml)

This release focuses on faster, more reliable live captions while keeping all
audio recognition and translation local to the Mac.

sAiity is part of the [aiity](https://aiity.de) family.
