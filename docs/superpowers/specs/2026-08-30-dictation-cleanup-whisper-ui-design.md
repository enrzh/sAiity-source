# Local Dictation Cleanup and Whisper Batch Design

## Status and scope

This is an implementation-ready macOS-only specification. It covers authoritative dictation finalization, optional local cleanup, optional dictation translation, one final insertion or clipboard operation, and release-time Whisper batch recognition. Live captions retain the existing Nemotron/Parakeet streaming path. No iOS, external API, upload, release, navigation redesign, or new model subsystem is included.

The existing `DictationController.finishDictation()` completion boundary, `ASRBackendPool`, `DictationToastWindow`, `OverlayWindow`, `FrameStore`, `LocalModels`, and existing settings screens remain the integration points. No Manager, Service, Factory, Strategy, Protocol, Adapter, Coordinator, Provider, Registry, or additional model type is added.

## Processing contract

The only pipeline is:

```text
authoritative transcript -> optional cleanup -> optional dictation translation
-> one clipboard/text insertion operation
```

Only the single authoritative result returned by the existing finalization call enters cleanup. Streaming partials, rolling caption finals, and intermediate hypotheses never enter cleanup, translation, clipboard, or insertion. Cleanup is opt-in and default-off. It uses only the existing `LocalLLMTranslator` Qwen/Gemma-compatible GGUF generation path. It must never call `HyMT2Translator`, MADLAD, or `TranslationEngine.effective`. No cleanup model is added to `TranslationEngine` or `ModelRegistry`.

If no compatible downloaded `LocalModel.selected` GGUF exists, the cleanup control is `Not ready` and offers navigation to the existing Models screen. Dictation still inserts the authoritative original. Cleanup generation gets a separate system prompt and a user prompt containing only the authoritative transcript. The system prompt requests punctuation, casing, filler, false-start, and repetition correction while preserving meaning, names, numbers, order, and uncertainty; it forbids summary, translation, expansion, explanation, invention, and added information.

The cleanup validator performs exactly these operations: trim leading and trailing whitespace and control characters; reject empty output; reject any Markdown fence marker or fenced block; reject output beginning with an explanatory prefix; reject output containing multiple commentary paragraphs; accept otherwise as plain text. It uses no length ratio, language detector, echo detector, quote stripping, wrapper removal, or other heuristic. Cleanup failure includes error, timeout, cancellation, nil output, empty output, and validator rejection. Cleanup failure selects the authoritative original.

Translation receives the selected cleaned/original text. Translation failure selects the cleaned transcript if cleanup succeeded; only cleanup failure selects the authoritative original. A user cancel or new session generation invalidates all pending and completed downstream work and performs no write.

## Whisper models and locales

The first release offers exactly these official multilingual WhisperKit model identifiers:

| UI choice | WhisperKit identifier | Meaning |
| --- | --- | --- |
| Base | `openai_whisper-base` | multilingual base |
| Small | `openai_whisper-small` | multilingual small |

The `.en` identifiers are not used. The local checkout confirms `ModelVariant.base.description == "base"`, `ModelVariant.small.description == "small"`, and `WhisperKit` resolves those variants to the identifiers above.

Every language in `LanguageCatalog.all` is selectable for Whisper. That set is the union of `MADLADLanguages.canonicalCodes` and `LanguageCatalog.popular`, using the existing canonical BCP-47 strings, including `en`, `de`, `fr`, `es`, `it`, `pt`, `nl`, `pl`, `ru`, `uk`, `tr`, `ar`, `he`, `hi`, `bn`, `ur`, `fa`, `zh-Hans`, `zh-Hant`, `ja`, `ko`, `th`, `vi`, `id`, `sw`, `am`, `ha`, `yo`, `ig`, `zu`, and `so`, plus the complete MADLAD code set.

For a multilingual model, an explicit locale selection is canonicalized as a BCP-47 identifier, reduced to the base ISO-639-1 code accepted by WhisperKit, and passed in `DecodingOptions.language`. A supported script or region is retained only for sAiity persistence; WhisperKit receives the base language code. Only an explicit `Auto` selection passes `language: nil` with `detectLanguage: true`, and that mode is allowed only for these multilingual model choices. Any explicit locale whose base code is unsupported fails clearly before transcription; it never falls back to automatic detection or another language.

## Swift package and real API

`Package.swift` currently has no WhisperKit dependency and its `sAiity` executable target has no WhisperKit product dependency. The implementation must add this exact package declaration:

```swift
.package(url: "https://github.com/argmaxinc/WhisperKit.git", exact: "1.0.0")
```

and this exact executable target dependency:

```swift
.product(name: "WhisperKit", package: "WhisperKit")
```

`Package.resolved` already verifies version `1.0.0`, revision `25c62997041c134b03ca82731ce2f6fd2cae1eb9`, at that URL. Do not raise the version without a source/API check. The local package manifest exposes the `WhisperKit` library product and target used above; its tools version is 5.10 and its supported macOS minimum is 13, compatible with sAiity's macOS 26 platform declaration.

The holder is one concrete `WhisperDictationBackend` type directly at the existing `DictationController` dependency boundary. It imports `WhisperKit`, owns one configured `WhisperKit` instance, and is not a protocol or manager. It is created only for dictation after recording release; the existing streaming backend pool remains unchanged.

The wrapper uses `WhisperKit.download(variant:downloadBase:useBackgroundSession:from:token:endpoint:progressCallback:)` for download, passes the returned folder to `WhisperKit.setupModels`, calls `loadModels(prewarmMode: true)` for prewarm/readiness, and calls the real array-based `transcribe` overload with `DecodingOptions`. It reads result text from the returned `TranscriptionResult` values. `prewarmModels()` and `loadModels()` are library APIs; there is no separate WhisperKit readiness API.

WhisperKit is not promised to provide an application cache contract, transaction marker, removal API, or complete-transfer recovery policy. sAiity owns one app-private Whisper folder per identifier. Readiness is true only after the required model files are present and a sAiity completion marker is present following successful `loadModels(prewarmMode: true)`. Download uses a temporary directory, cancellation removes that directory, and the marker is written last. Retry removes the incomplete temporary directory and starts the same download again. Remove calls `FileManager.removeItem` on the selected model folder and its marker; it does not call a nonexistent WhisperKit remove method.

Only one operation per model identifier is allowed in flight. A second download, prewarm, or remove awaits the first operation's result. Cancellation invalidates the holder and removes only the interrupted partial directory. Failed holders are released. This is the complete single-flight boundary; there is no global model coordinator.

## Runtime and fallback details

Cleanup calls only `LocalLLMTranslator.prepare` and its existing generation method for a selected Qwen/Gemma-compatible `LocalModel`; it does not resolve `TranslationEngine.effective`. Translation settings remain independent. If a compatible local model is absent, the toggle stays `Not ready`, Models remains the recovery destination, and the original dictation is inserted.

The 20-second cap counts only successfully converted 16 kHz mono samples: exactly 320000 accepted samples stops capture and enters transcription. Conversion failures do not advance the count. Release, cap, cancel, and new session generation use the controller's existing main-actor serialization and one terminal transition; the first accepted transition wins and finalization runs once.

The toast remains a separate window, preserves its existing subtitle-bubble visual language, and adds explicit phases for permission, preparation, recording, transcribing, cleaning, translating, inserting, success, limit, failure, and recovery. Phase updates never move the saved frame. Accessibility exposes role, stable status label, value, live announcement, and Reset Position. Reduced Motion dismisses directly, Reduced Transparency uses an opaque readable surface, and Increase Contrast strengthens border/text contrast.

Settings adds a default-off cleanup toggle, the existing streaming recognizer choice, the two Whisper choices with real local readiness/actions, actionable Download/Retry/Remove controls, and permission recovery. Captions keeps its own readiness screen and never mirrors Whisper state.

## Required tests

Add focused tests for:

- exact multilingual identifiers, full `LanguageCatalog.all` locale coverage, explicit locale base-language hints, explicit `Auto` as nil plus language detection, and clear pre-transcription failure for every explicit unsupported locale;
- the exact package URL/version/product declaration and the concrete wrapper's `setupModels`, `download`, `loadModels(prewarmMode:)`, `transcribe`, and result-text API calls;
- download interruption, partial-directory cleanup, retry, marker-based readiness, remove, and concurrent same-identifier single-flight;
- cleanup runtime exclusion from `HyMT2Translator`, MADLAD, and `TranslationEngine.effective`, plus Not-ready behavior and Models navigation;
- validator trimming and exact rejection of empty, fenced, explanatory-prefix, and multi-paragraph commentary output;
- cleanup-success translation failure retaining cleaned text, cleanup failure retaining authoritative original, and one final insertion;
- authoritative-only input, cancellation/new-generation invalidation, the 320000-sample cap, conversion-failure counting, and caption independence.

## Acceptance and checks

The implementation is local-only, cleanup is off by default, partials are never processed, and only the two multilingual identifiers are selectable. WhisperKit is used through the verified 1.0.0 APIs above; sAiity owns only its folder marker, existence/readiness check, temporary-directory cleanup, and `FileManager` removal. Cleanup uses only the existing Qwen/Gemma-compatible GGUF path. Only explicit `Auto` enables nil language plus detection; every explicit unsupported locale fails before transcription without substitution. All fallbacks, locale rules, single-flight behavior, terminal race rules, and focused tests above are explicit.

Before committing this documentation change, inspect the full file for unresolved planning language; run `git diff --check`; confirm `git status` shows only this spec changed; and commit with message `docs: clarify Whisper locale detection`.
