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

    swift test -c release -Xswiftc -enable-testing -Xswiftc -DSAIITY_TEST_HOOKS

A plain debug test run is not the supported verification path on this
toolchain.

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

## Release

Download the current build from
[GitHub Releases](https://github.com/enrzh/sAiity/releases).

sAiity is part of the [aiity](https://aiity.de) family.
