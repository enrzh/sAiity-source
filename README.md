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
- A dictated result is inserted into the focused text field when possible and
  always remains on the clipboard
- German, English, French, Spanish, and Japanese interface localizations
- No Windows release target

## Translation

MADLAD-400-3B is the recommended translation engine. It covers a broad range of
languages and runs on-device.

Hy-MT2-1.8B is an opt-in translation-specialized engine. It is useful for the
language set declared by its model card, but it is not the broad-coverage
default. Local Qwen and Gemma GGUF models remain available for users who want
to supply a different local model.

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

## What's new in 2.5.3

- Live captions now use adaptive speech activity detection, so natural pauses
  close captions without confusing healthy digital silence with a stalled stream.
- Cumulative recognizer revisions are reconciled into stable text and a
  revisable tail, reducing duplicated words and lost text around pauses.
- Caption processing stays bounded with one in-flight ASR operation, protected
  audio backlog limits, sample-clock timestamps, and diagnostics for latency and
  dropped audio.
- Script-aware joining keeps Latin spacing readable while preserving CJK and
  other spaceless scripts; translation requests are cached and stale results
  cannot repaint a newer session.

## Release

The current signed and notarized release is [sAiity 2.5.3](https://github.com/enrzh/sAiity/releases/tag/v2.5.3).

- [Download the DMG](https://github.com/enrzh/sAiity/releases/download/v2.5.3/sAiity-2.5.3.dmg)
- [Download the ZIP](https://github.com/enrzh/sAiity/releases/download/v2.5.3/sAiity-2.5.3.zip)
- [Sparkle update feed](https://enrzh.github.io/sAiity/appcast.xml)

This release focuses on faster, more reliable live captions while keeping all
audio recognition and translation local to the Mac.

DMG SHA-256: `a168c2f0e1fcb6c15bc2729872981f253fd7a9f9294c95acb4eeedba55b2a113`

ZIP SHA-256: `dc0596902a1ac3fe28d9f04d43cc2ba0aff8b4af4211b10ed91c6937cbc1b035`

sAiity is part of the [aiity](https://aiity.de) family.
