# Syllivra

Previously named sAiity. The app keeps its existing bundle identifier, local data/model directories and `saiity://` links for compatibility. The Swift module and source/test directory names remain internal; new app bundles and downloads use Syllivra.

When upgrading, quit the old sAiity app and replace its app bundle with Syllivra. Keep only one installed copy; removing the old app bundle does not remove the separately stored settings, models or transcripts.

Live subtitles for whatever your Mac is playing.

Syllivra captures system audio, recognises speech, and translates it on the Mac.
It can save bilingual transcripts locally and provide press-to-talk dictation
to the app that currently has focus.

**No account. No API key. No audio leaves the Mac.**

## First use

Install from the [Release downloads](#release), then choose captions, dictation,
or both in setup. Download the recognition model offered for that feature and
grant its permissions. Try a short sentence with **Try Dictation**, or play
speech on the Mac with **Try Captions**; stop the trial when finished.

Captions and Dictation keep everyday controls and bubble preset previews visible;
**More options** starts collapsed and holds alternative engines, vocabulary,
permissions and fine appearance controls. Dictation shows **Fast**, **Balanced**
and **Accurate** processing presets; manually changed or unavailable-cleanup
configurations can read **Custom**. These names describe processing choices,
not measured accuracy guarantees. Existing saved preferences still apply.
Bubble appearance offers **Minimal**, **Balanced**, **Readable** and **Liquid
Glass**; fresh appearance defaults match Balanced. Preview cards illustrate
appearance, independently of the dictation processing preset.

For optional model cleanup, choose **Clean up with** on Dictation. If the selected
model is missing, **Download & Use** downloads it directly; cleanup is enabled
only after success, compatibility checks and an unchanged selection. Selecting
a model is not proof that it is ready. Recognition and translation have their
own installed/missing status and download controls. Translation is a separate,
optional target-language choice; cleanup alone preserves the spoken languages.

Try Dictation also shows the microphone name and observed quiet/clipping hints.
These help investigate input problems; review the recognized words to check the
result. The trial does not paste into another app or replace the clipboard.

In Dictation’s More options, you can keep the last five completed results until
quitting. This is off by default, stays in memory, and clears when disabled.
Recent Dictations opens explicit Copy Result/Copy Original actions. Application
Exceptions lets you choose apps that should receive original recognition text,
with cleanup, vocabulary corrections and translation off for those recordings.
This preserves recognition output; it does not correct recognition mistakes.

Transcript search opens the matching spoken line in its full session. Rename
changes only a session’s optional name, and the reader offers larger text.
Troubleshooting groups recent dictation timings and outcomes without keeping
the dictated words in diagnostics.

## Features

- Native SwiftUI/AppKit app for macOS 26 or later on Apple Silicon
- Streaming captions from system audio
- Optional translation below the original caption
- Local transcripts with SRT, WebVTT, Markdown, and text export
- Press-to-talk dictation with a configurable key
- A dictated result is inserted into the app you were in when you started
  speaking when possible, and always remains on the clipboard. Password fields
  are refused, as they are by macOS dictation
- German, English, French, Spanish, and Japanese interface localizations
- macOS is the supported release target. Windows code is an experimental
  overlay prototype; its build/package workflows run only by manual dispatch

## Translation

MADLAD-400-3B is the recommended translation engine for broad language coverage
and runs locally through MLX. Hy-MT2 is an alternative local CPU engine for its
37 supported languages. Captions and dictation have independent engine and
target-language choices. A failed engine can fall back only to an installed,
compatible alternative; otherwise the original text remains available.

Realtime translation previews automatically update less often in Low Power
Mode, under thermal/memory pressure, or after sustained slow decoding. Final
sentence translations retain priority; recognition settings are not changed.

Mixed-language dictation keeps each spoken language when translation is off.
Enabling translation asks for the entire message in the chosen target language.
Cleanup fixes wording in place; it does not request translation.

Recognition and translation have separate language coverage. Whisper's source
choices come from its pinned recognition vocabulary. Nemotron and Qwen recognize
automatically, but their adapters do not declare a complete source-language set;
automatic recognition is not a promise of equal accuracy in every language.
Qwen does not expose an audio-language tag; Nemotron exposes its first tag.

Japanese kanji and kana stay in one phrase. Clear language switches keep separate
source spans, while short shared-script names remain uncertain. Translation
checks individual regions and the assembled result; rejection keeps the
original available. Explicit Simplified/Traditional Chinese requests use local
script conversion, without promising regional vocabulary changes.

Cleanup uses language-specific rules where available and preserves unhandled
language content. Its numeric, date, currency and omission checks catch concrete
errors; they cannot prove that a model preserved every detail. Ambiguous short
translations or unfamiliar currency spellings can be declined rather than
reported as successful. Natural-speech quality and speed require the reviewed
language evidence described in the [release checklist](docs/release-checklist.md).

Models are downloaded on first use and stored locally. The app does not ship
model weights.

## Realtime subtitles

With Nemotron selected, use **Captions → Quick controls → Subtitle timing →
Realtime** for the 1.12-second streaming model, or **Balanced** for 2.24-second
updates. Alternative recognition engines are under **More options**.
The two timing models are separate local
downloads; the page offers Download when the selected one is missing. Spoken
words appear while speech continues and may be revised. Qwen's captions remain
pause-based; choose Nemotron for realtime word updates.

When translation is enabled, **Translation timing → Realtime** translates interim
words as the sentence grows. Requests coalesce over 400 ms, retain one active
decode and one newest revision, and use the existing local translation engine.
Translation adds its own inference delay and needs more processing than whole
sentences. Closing/clearing a sentence or changing the language cancels stale
previews. Saved transcripts receive only the final sentence translation.

## Setup

Choose captions, dictation or both, download the offered recognition model,
and grant the permissions for that feature. Nemotron is the recommended
multilingual recognition path. Qwen3-ASR is an optional alternative; Whisper
is available for press-to-talk dictation. Model cleanup is optional and uses
the compatible local model selected on the Dictation page.

The final setup step offers an optional real trial. **Try Dictation** records
a short sentence and shows the processed result inside setup without pasting
or replacing the clipboard. **Try Captions** captures speech played on the Mac
through the normal caption pipeline. Stop the trial, or close setup, to end
capture. Setup can be reopened from General settings.

## Dictation

Hold the configured press-to-talk key while speaking. Release it to transcribe
locally, clean the result, and insert it into the focused app. When there is no
focused editable field, the result is copied without attempting a paste.

Automatic insertion also requires the original app and text field to remain
focused. Changing documents or fields while processing keeps the result on the
clipboard. If copying fails, the result stays in the bubble and its action
offers **Retry Copy**; retrying copies the retained text without pasting it.

If cleanup, translation or an approved correction changes the result, the bubble
offers **Copy Original**. The menu bar also offers **Copy Original Dictation**,
including after the bubble disappears. Both copy the retained recognition text
without pasting into another app. It stays in memory until the next recording starts.

Under **More options** on either page, **Names and terms** protects spelling
and **Corrections** stores explicit phrase replacements such as `Ube Eats` →
`Uber Eats`. The dictionary is shared, local, and bounded. Corrections match whole
phrases once, before cleanup/translation; nothing is learned automatically.

Scrolling upward in the caption bubble pauses automatic scrolling while new
speech continues. **Jump to latest**, or scrolling back to the bottom, resumes
following new captions. Clearing the bubble also resumes following.

The bubble displays the latest 50 lines. **Save transcript** saves all committed
lines from the session at the time of the action, including lines outside that
display window. Choose **Saved to Transcripts** in the bubble to open that session. Pending final
translations for those lines are retained; interim preview words are not saved.

Dictation is a separate microphone-only session. It does not write to saved
caption transcripts and it does not require Syllivra to be the frontmost app.
Captions and dictation do not own the microphone at the same time.

## Transcript summary

Open a saved session on the Transcripts page, then choose **Summarize** in its
viewer to write a local recap, decisions, and action items. **Summarize Again**
replaces that preface; **Remove Summary** deletes only the summary, keeping the
spoken lines and exports. The session list marks sessions with a summary and
keeps secondary actions in one menu. The reading sheet can be resized.

A session with one clear spoken language keeps that language in its summary.
For a session with confirmed language switches, choose the summary language in
the reader before generating it. This choice is local to the reader. Its
requested language is saved with the summary and included in Markdown export;
older summaries without that field remain readable.

The summary can miss or invent details. It uses the Gemma cleanup model already
installed for dictation. It does not run while captions or dictation are using
that model, it does not download a model, and it does not change the spoken
lines. SRT and WebVTT stay the words that were said. Markdown export prints
the summary once, above the transcript. A long session keeps the latest portion
that fits and says how many earlier lines were left out.

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
    ./build-app.sh --no-test-hooks
    ./build-app.sh --notarize

Choose the build mode for the verification you need:

| Command | Test hooks | Signature | For |
| --- | --- | --- | --- |
| `./build-app.sh` | compiled in | best available, else ad-hoc | local development |
| `./build-app.sh --no-test-hooks` | compiled out | best available, else ad-hoc | release-mode local/CI verification |
| `./build-app.sh --notarize` | compiled out | requires Developer ID | a release |

`verify-release.sh` rejects test hooks and checks the bundle's version, native
resources and code signature. It accepts either build without test hooks;
it does not prove notarization. A distributable release additionally requires
Developer ID signing, notarization and stapling through `--notarize`.

Both build paths need a full git checkout, not a shallow one. The version stamp
comes from `git describe --tags` and the build number from
`git rev-list --count HEAD`, and on a depth-1 clone that count is 1 — which
both build-app.sh's own stamp assertion and `verify-release.sh` read as an
unstamped bundle.

To check that a bundle really launches — a real `NSApplication`, the real
`AppDelegate`, one turn of the run loop, and a window the window server agrees
exists — run:

    build/Syllivra.app/Contents/MacOS/Syllivra --selftest

It exits 0 on success, 1 if a check failed, and 70 if the launch never
finished. Over a plain ssh session, where there is no window server to launch
a GUI into, it reports a skip and exits 0. CI runs this after assembling the
bundle. The smoke test also presents all four bubble presets, clears and resumes
caption content, switches a dictation result back to its compact recording view,
and lays out the setup trial for each use case. It captures no audio and restores
the settings it temporarily exercises.

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

The release workflow requires a verified local corpus and checks accuracy,
language preservation and warm latency budgets before notarizing or tagging:

    SAIITY_RELEASE_FIXTURES=/absolute/verified-fixtures scripts/quality-matrix.sh

`scripts/release.sh <version>` runs this gate automatically. Missing recordings,
reference text, required model weights, speech categories or benchmark records
fail the gate. Rows in `futureTier` (12-language reviewed provenance, Whisper
base, model cleanup, Hy-MT2, and translated MADLAD) log
`SKIP (optional future tier): <case> — <reason>` when their weights or reviewed
references are absent. That skip does not block 2.7.0. When those inputs exist,
the same budgets gate the row. See [the corpus and acceptance criteria](docs/benchmarks/README.md) and
[the signed-app checklist](docs/release-checklist.md). These checks are local;
they do not download models or send recordings anywhere.

The [release policy](docs/benchmarks/release-quality.json) required tier covers
Nemotron 2240 segmented decode, untranslated Nemotron 1120/2240 live captions,
and rules-cleanup insertion at both chunk sizes. Model cleanup and
Hy-MT2/MADLAD translation remain in `futureTier`. Translated runs that do
execute score raw recognition against reviewed source text and translated
output against a separate reviewed target reference. See [the PRR gates](docs/release-checklist.md) for exact settings
and outstanding device/corpus acceptance; deterministic tests alone are a partial
check, not a full release pass or evidence of improved accuracy/performance.

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
| Sources/sAiity/CaptionSessionResources.swift | Caption audio delivery and pooled backend lease |
| Sources/sAiity/TranslationRuntime.swift | Resident translator, native serialization and lifetime leases |
| Sources/sAiity/DictationToastWindow.swift | Dictation status surface above other apps |
| Sources/sAiity/TranscriptStore.swift | Local transcript storage and retention |
| Sources/sAiity/OverlayWindow.swift | Caption bubble geometry and presentation |
| Resources/Localizable.xcstrings | User-facing localization catalog |

## What's new in 2.6.6

- Open a saved session, then choose **Summarize** in its viewer for a local
  recap, decisions, and action items.
- **Summarize Again** replaces that preface; **Remove Summary** deletes only
  the summary, keeping spoken lines and exports.
- Session rows keep the date, line count, and one secondary-action menu. The
  reading sheet is resizable.
- Summaries share the saved-transcript busy state with retranslation, hold
  cancellation until native work drains, and refuse changed or missing input
  before publishing.
- Build 2: setup and SelfCapture use the same opaque settings surface as
  Settings, so the native titlebar stays solid system chrome.

## What's new in 2.6.5

- On the Transcripts page, **Summarize** writes a local recap, decisions, and
  action items for one saved session.
- It uses the Gemma cleanup model already installed for dictation. It does not
  download a model, and it does not run while captions or dictation are using
  that model.
- Spoken lines stay unchanged. SRT and WebVTT remain the words that were said.
  Markdown export prints the summary once, above the transcript.
- A long session keeps the latest portion that fits and says how many earlier
  lines were left out.

## What's new in 2.6.4

- Nemotron captions offer **Realtime** (1.12 s) or **Balanced** (2.24 s) subtitle
  timing, with a download control when the selected model is missing.
- **Translation timing → Realtime** translates interim words as the sentence
  grows. Requests coalesce, and only the final sentence translation is saved.
- Interim translation updates less often in Low Power Mode, under thermal or
  memory pressure, or after sustained slow decoding. Final translations stay first.
- After cleanup, translation, or an approved correction, **Copy Original** copies
  the recognition text without pasting it.
- **Names and terms** and explicit whole-phrase **Corrections** live in one
  shared local dictionary. Nothing is learned automatically.
- Scrolling up in the caption bubble pauses follow. **Jump to latest**, or
  scrolling back to the bottom, resumes it.

## What's new in 2.6.3

- Automatic insertion requires the press-time app and accessibility field to stay
  focused; otherwise the result is copied without attempting a paste.
- Clipboard write failures keep the complete result in a persistent bubble whose
  action is **Retry Copy**; retry copies the retained text without pasting.
- Caption first-text / first-final cold reporting uses the inverse of prepared-model
  state, and setup reopening restores the persisted automatic-update preference.
- Release-quality logs fingerprint corpus and model bytes without retaining
  transcript contents, and reject inconsistent evidence.

## What's new in 2.6.2

- Failed caption pumps become terminal instead of silent, so a stuck recognition
  path surfaces instead of looking healthy with no new text.
- Qwen3-ASR keeps a fixed PCM bound through silence, and local cleanup/translation
  share one generation budget with a real deadline.
- Speaker labels ride confirmed audio only, so provisional segments cannot invent
  speakers.
- Translation output is validated the same way on every engine, including
  mixed-language preservation when translation is off.
- The release script will not notarize until a clean-source quality matrix clears
  its accuracy and latency budgets on the verified fixture corpus.

## What's new in 2.6.1

- Qwen3-ASR is a selectable caption engine alongside Nemotron. The language row
  now reflects what the chosen engine can recognise instead of offering languages
  the active path cannot.
- Dictation can show realtime text while you are still speaking on the Streaming
  path. An optional preference keeps the live draft on even with cleanup or
  translation in the way, so the raw words appear as they arrive and the finished
  text replaces them.
- Cleanup is a model selector with an explicit Off, and dictation finally has its
  own model picker in Quick controls. The translation engine sits beside the
  language it translates to; Captions can start from its own pane; realtime text
  sits with the streaming model it belongs to.
- The app icon is the Dictus voice mark — three white bars on a blue auto-gradient
  — rebuilt from a checked-in Icon Composer source so it can be regenerated. Glass
  stops being the default for every settings row button.
- The ship DMG keeps its volume icon. Finder was deleting `.VolumeIcon.icns`
  during the layout AppleScript; both DMG scripts restore it after layout and
  re-set the custom-icon flag before detach.

## What's new in 2.6.0

- Hy-MT2 is available again as a second translation engine, under Settings →
  Advanced. It is a translation specialist that runs on CPU: 1.1 GB instead of
  MADLAD's 1.9 GB, for the 37 languages it was trained on. It is a second
  opinion rather than a replacement, and if it ever fails at runtime the app
  falls back to MADLAD automatically — except for Cantonese, which Hy-MT2
  translates and MADLAD does not, where the app says no translator is available
  rather than silently producing nothing.


- A failed translation no longer looks like a model refusing. Engines reported
  "declined" and "failed" as the same value, so a native error surfaced as your
  caption quietly staying untranslated with nothing in the log and translation
  never being switched off. They are separate now: a real failure is logged and
  retires a broken engine after three tries in a row, and a line the model
  declines no longer retires anything. Re-translating a transcript stops on a
  genuine failure instead of writing a half-translated file.
- Press-to-talk no longer fires on an ordinary Control press. The default
  shortcut is now ⌥⌘Space, a chord must contain a real key and not only
  modifiers, and dictation starts switched off on a new install. An install that
  has run before keeps press-to-talk switched on, because in 2.5.5 it was on by
  default and those users never wrote a preference for it to be read from.
- Holding the dictation key past a minute now says the recording was cut, instead
  of showing "Transcribing" and returning a shorter sentence with no explanation.
- Loading a model that is deleted mid-dictation no longer leaks it. A load that
  races the deletion used to displace the in-flight entry, and the model behind
  it was never unloaded.
- Dictation cleanup is roughly 78x faster on a short sentence — it was rebuilding
  about thirty regular expressions and three language recognizers on every
  utterance — and caption language analysis about 1.8x faster on a typical line.
- The live caption is still capped at what the bubble can show (220 characters
  over four lines), which is more than is comfortable to read in the few seconds
  it is on screen. Exported subtitles are the readable form; the live bubble is
  not, and closing that gap means holding a caption up rather than making it
  shorter, which is a deliberate lag trade.
- Exported subtitles are now readable rather than merely short. Cue splitting
  already kept text under a length budget, but nothing governed *speed*: an
  83-character sentence spoken in 1.4 seconds exported at 89 characters per
  second, and its trailing fragment — being small — inherited a proportionally
  small slice of the same span and lasted 0.135 seconds, which a player draws as
  a single frame. Translated captions were the worst case at 126 characters per
  second, because a bilingual cue keeps its raw segment timing. Every cue now
  stays up long enough to read at 17 characters per second, shares the slack
  with the cues around it, never overlaps what follows, and leaves speech that
  was already readable exactly as it was.
- Long caption lines are scanned for a code-switch on a coarse grid first, which
  keeps the same boundary but does about 1.55x less work.
- Searching transcripts no longer recomputes its cache accounting on every
  keystroke, and the cache's eviction policy now has tests.
- A data race on caption cue timings, and a hotkey permission retry loop that
  never backed off, are both fixed.

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

The current signed and notarized release is [sAiity 2.6.6](https://github.com/enrzh/sAiity/releases/tag/v2.6.6).

- [Download the DMG](https://github.com/enrzh/sAiity/releases/download/v2.6.6/sAiity-2.6.6.dmg)
- [Download the ZIP](https://github.com/enrzh/sAiity/releases/download/v2.6.6/sAiity-2.6.6.zip)
- [Sparkle update feed](https://enrzh.github.io/sAiity/appcast.xml)

This release adds a resizable transcript reader with Summarize Again and Remove
Summary, plus safer summary lifecycle controls. Build 2 also keeps setup window
chrome opaque like Settings — still fully local recognition and translation on
the Mac.

Syllivra is part of the [aiity](https://aiity.de) family.
