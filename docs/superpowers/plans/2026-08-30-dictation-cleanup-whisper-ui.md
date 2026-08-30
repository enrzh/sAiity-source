# Local Dictation Cleanup and Whisper Batch Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add optional local cleanup and release-time multilingual Whisper dictation while keeping captions streaming and insertion authoritative-only.

**Architecture:** Reuse `DictationController`, `ASRBackendPool`, `LocalLLMTranslator`, `LocalModels`, `DictationToastWindow`, `OverlayWindow.FrameStore`, and existing settings. Add one concrete `WhisperDictationBackend` and value/closure boundaries only; add no Manager, Service, Factory, Strategy, Protocol, Adapter, Coordinator, Provider, Resolver, Registry, or new model subsystem. `finish(session:)` is orchestration only: it stops capture, calls the existing backend's `finishDictation()`, releases it, sequences optional cleanup and translation, and performs one insertion.

**Tech Stack:** Swift 6 in Swift 5 language mode, macOS 26 AppKit/SwiftUI, SwiftPM, WhisperKit 1.0.0, existing GGUF `LocalLLMTranslator`, Swift Testing, String Catalog, `build-app.sh`.

## Global Constraints

- Start from clean `HEAD df72b5597cf44e51fb14c35e27573486f13bca56`; do not reset or require a reset. If implementation commits have already moved HEAD, use the actual parent of the implementation start as the recorded baseline.
- The only pipeline is `authoritative transcript -> optional cleanup -> optional dictation translation -> one clipboard/text insertion`.
- The authoritative text is the single result of existing `finishDictation()`. Partials, rolling captions, and hypotheses never enter cleanup, translation, clipboard, or insertion. There is no collector fallback.
- Cleanup is default-off and uses only the existing concrete Qwen/Gemma-compatible GGUF path; never use `HyMT2Translator`, MADLAD, or `TranslationEngine.effective` for cleanup.
- Whisper is created only after recording release. Preparation may download files and establish readiness, but must not create/load a Whisper model or open the microphone.
- Only `openai_whisper-base` and `openai_whisper-small` are selectable; no `.en` variant.
- Add exactly `.package(url: "https://github.com/argmaxinc/WhisperKit.git", exact: "1.0.0")` and `.product(name: "WhisperKit", package: "WhisperKit")`; preserve resolved revision `25c62997041c134b03ca82731ce2f6fd2cae1eb9`.
- Whisper receives a supported base ISO-639-1 hint or `nil`; unsupported base means `nil` and `detectLanguage: true`. Persist canonical BCP-47 separately.
- Readiness is required model files plus an sAiity marker written last after successful `loadModels(prewarmMode: true)`; downloads stage in a temporary directory.
- One operation per identifier is in flight; later download/prewarm/remove awaits the first. Cancellation removes only the interrupted partial directory.
- The cap is exactly `320000` successfully converted mono 16 kHz samples. Conversion failures do not count; release, limit, cancel, and new-generation terminal transitions are first-wins and main-actor serialized.
- Validation is exactly trim controls, reject empty, reject Markdown fences, reject explanatory prefix, reject multiple commentary paragraphs, otherwise accept plain text. No ratio, echo, language, quote, wrapper, or other heuristic.
- Cleanup failure/cancellation falls back to authoritative original; translation failure after cleanup retains cleaned text; cancellation or new generation performs no write.
- Use current `DictationPhase` names (`idle`, `waitingForInputMonitoring`, `preparing`, `ready`, `starting`, `dictating`, `transcribing`, `translating`, `inserting`, `result`, `failure`) and add only `cleaning` plus explicit limit/recovery states required by the existing UI.
- Captions keep independent readiness/settings. Do not change iOS, external APIs, upload/release metadata, or push workflows.

## Files and Responsibilities

- `Package.swift`: exact WhisperKit dependency.
- `Sources/sAiity/WhisperDictationBackend.swift`: concrete model choice, locale hint, download/readiness marker, single-flight lifecycle, and batch transcription.
- `Sources/sAiity/TranscriptionBackend.swift`: existing backend boundary; retain `finishDictation()` as authoritative.
- `Sources/sAiity/DictationMicrophoneCapture.swift`: converted-sample accounting and terminal cap.
- `Sources/sAiity/DictationController.swift`: release-created Whisper backend, authoritative finalization, cleanup/translation ordering, generation guards, one insertion.
- `Sources/sAiity/DictationState.swift`: cleanup preferences, phase values, `DictationAudioSampleLimit`, and terminal enum.
- `Sources/sAiity/Translators.swift`: one concrete cleanup method on existing `LocalLLMTranslator`; reuse its existing generated source entry point.
- `Sources/sAiity/LocalModels.swift`: exact Qwen/Gemma compatibility/readiness value check.
- `Sources/sAiity/AppDelegate.swift`, `SettingsWindow.swift`, `SettingsPages.swift`: dependency wiring and independent controls/actions.
- `Sources/sAiity/DictationToastWindow.swift`, `Sources/sAiity/OverlayWindow.swift`: phase presentation, saved frame, AX behavior.
- `Resources/Localizable.xcstrings`: complete new key set and translations.
- Existing focused test files: `WhisperDictationBackendTests.swift`, `DictationMicrophoneCaptureTests.swift`, `DictationControllerTests.swift`, `DictationToastWindowTests.swift`, `SettingsWindowTests.swift`, `LocalizationTests.swift`, and relevant `LanguageTests.swift`/`ModelLifecycleTests.swift`.

---

### Task 1: Add exact WhisperKit dependency and model contract

**Files:** Modify `Package.swift`; create `Sources/sAiity/WhisperDictationBackend.swift`; modify `Tests/sAiityTests/LanguageTests.swift`; add RED tests to `Tests/sAiityTests/WhisperDictationBackendTests.swift`.

**Interfaces:** Define `WhisperDictationBackend.ModelChoice: CaseIterable, Equatable, Sendable` with exactly `.base` and `.small`; `identifier` returns `openai_whisper-base`/`openai_whisper-small`; `description` returns `base`/`small`; `static let supportedLanguageCodes = Set(LanguageCatalog.all.map(\.code))`; `static func languageHint(for locale: Locale) -> String?` is nonthrowing and returns a supported base code or nil. Persist the choice and canonical locale as existing app-state values; add no configuration object.

- [ ] Write RED tests asserting exact manifest literals, two choices/descriptions, `Set(LanguageCatalog.all.map(\.code)) == Set(MADLADLanguages.canonicalCodes).union(LanguageCatalog.popular)`, `de-DE -> "de"`, `zh-Hant-TW -> "zh"`, and unsupported -> nil/detection.
- [ ] Run `swift test -c release -Xswiftc -enable-testing -Xswiftc -DSAIITY_TEST_HOOKS --filter 'WhisperDictationBackendTests|LanguageTests'`; expect failure because the dependency and symbols are absent.
- [ ] Add the exact package/product declarations and implement locale canonicalization using existing BCP-47 utilities. Do not throw for unsupported locale; the caller passes nil and `detectLanguage: true`. Define app-private per-identifier folder and marker names, without loading Whisper or touching the microphone.
- [ ] Run the same command; expect all model/locale/catalog assertions to pass and no catalog assertion to compare incompatible canonical forms.
- [ ] Commit `git add Package.swift Sources/sAiity/WhisperDictationBackend.swift Tests/sAiityTests/WhisperDictationBackendTests.swift Tests/sAiityTests/LanguageTests.swift && git commit -m 'feat: define Whisper dictation model contract'`.

### Task 2: Add real WhisperKit lifecycle and batch API boundary

**Files:** Modify `Sources/sAiity/WhisperDictationBackend.swift`; add RED tests to `Tests/sAiityTests/WhisperDictationBackendTests.swift`.

**Interfaces:** Use local WhisperKit 1.0.0 symbols exactly: `WhisperKit.download(variant: String, downloadBase: URL? = nil, useBackgroundSession: Bool = false, from: String = "argmaxinc/whisperkit-coreml", token: String? = nil, endpoint: String = Constants.defaultRemoteEndpoint, progressCallback: ((Progress) -> Void)? = nil) async throws -> URL`; instance `setupModels(model: String?, downloadBase: URL? = nil, modelRepo: String?, modelToken: String? = nil, modelFolder: String?, download: Bool, remoteConfigName: String = Constants.defaultRemoteConfigName, endpoint: String = Constants.defaultRemoteEndpoint) async throws`; `loadModels(prewarmMode: Bool = false) async throws`; and `transcribe(audioArrays: [[Float]], decodeOptions: DecodingOptions? = nil, callback: TranscriptionCallback = nil) async -> [[TranscriptionResult]?]`. Use `ModelVariant.base/small.description` only for `base`/`small` labels; use `DecodingOptions(language: hint, detectLanguage: hint == nil)` and returned `.text`.

- [ ] Write RED tests for the exact source contract, marker-last readiness, required `MelSpectrogram`/`AudioEncoder`/`TextDecoder` files, temporary-directory cancellation cleanup, retry/remove, and same-identifier single-flight.
- [ ] Run the focused release command; expect RED compile/source-contract failure.
- [ ] Implement download into `<identifier>.partial`, calling `WhisperKit.download(variant: choice.identifier, downloadBase: partialRoot, useBackgroundSession: false, from: "argmaxinc/whisperkit-coreml", token: nil, endpoint: Constants.defaultRemoteEndpoint, progressCallback: progress)`, then create the concrete instance with `try await WhisperKit(model: choice.identifier, modelRepo: nil, modelFolder: folder.path, prewarm: false, load: false, download: false)` and call `setupModels(model: choice.identifier, modelRepo: nil, modelFolder: folder.path, download: false)` before `loadModels(prewarmMode: true)` in the explicit model action. Write the marker last. `prepare` only checks files/marker and downloads; it never creates the WhisperKit instance or calls load. `transcribe(samples:locale:)` creates/configures the instance after release and calls the exact array overload. Serialize per identifier with stored tasks in this concrete type; use `FileManager.removeItem` for remove, never a nonexistent WhisperKit remove API.
- [ ] Run focused tests; expect lifecycle, source symbols, cancellation, marker, retry, remove, and single-flight tests to pass.
- [ ] Commit `git add Sources/sAiity/WhisperDictationBackend.swift Tests/sAiityTests/WhisperDictationBackendTests.swift && git commit -m 'feat: add Whisper lifecycle and batch recognition'`.

### Task 3: Add authoritative finalization, cleanup boundary, and exact audio terminal state

**Files:** Modify `Sources/sAiity/TranscriptionBackend.swift`, `DictationController.swift`, `DictationState.swift`, `DictationMicrophoneCapture.swift`, `LocalModels.swift`, and existing `Translators.swift`; add RED tests to `DictationControllerTests.swift`, `DictationMicrophoneCaptureTests.swift`, and `ModelLifecycleTests.swift`.

**Interfaces:** `DictationAudioSampleLimit.maximumSamples == 320000`; synchronous `accepted(sampleCount:) -> DictationAudioSampleLimit.Decision`; conversion failure leaves count unchanged. Define a main-actor-owned terminal enum with `.open`, `.released`, `.limited`, `.cancelled`; `accept(_:)` is first-wins. Add `DictationCleanupValidator.validate(_:) -> String?`, `DictationCleanupConfiguration(enabled: Bool)`, `LocalModel.isCleanupCompatible(_:) -> Bool`, and `LocalLLMTranslator.cleanup(_ text: String) async -> String?`. Inject only a `cleanup: (String) async -> String?` closure beside existing translation closure for tests, with no protocol.

- [ ] Write RED tests: `finishDictation()` is called once and is the only cleanup input; collector/rolling fallback is absent; success cleanup then failed translation retains cleaned text; cleanup failure retains authoritative text; cancellation/new generation writes zero times; limit/release/cancel race accepts one terminal event; converted callback increments before conversion failure can be ignored; exact validator rules; only downloaded Qwen/Gemma-compatible GGUF is ready.
- [ ] Run focused release tests; expect failure against the absent boundary and old fallback.
- [ ] Remove `DictationFinalTextCollector` and every rolling fallback. In private `finish(session:)`, stop capture, await existing backend `finishDictation()`, release backend, guard generation, then sequence `cleaning`, translation, `inserting`; it performs no recognition, collection, model selection, or policy beyond orchestration. Create `WhisperDictationBackend` only in the release path. Add `LocalLLMTranslator.cleanup` in `Translators.swift` by reusing its existing concrete downloaded-model setup and private `generate(system:user:)`; separate prompts contain only the authoritative transcript. Implement `LocalModel.isCleanupCompatible(_:)` as a pure value check requiring a downloaded `.gguf` whose model family metadata/name contains `qwen` or `gemma`, case-insensitively. The injected closure supplies tests without a new abstraction. Add `DictationPhase.cleaning`, `DictationPhase.limit`, and `DictationPhase.recovery(String)` and update every existing switch exhaustively.
- [ ] Implement synchronous converted-sample accounting: increment only after successful mono 16 kHz conversion, emit cap once at exactly 320000, and have release, cap, cancel, and generation invalidation call the terminal enum's first accepted transition. A stale callback drains but cannot feed a later generation.
- [ ] Run the three focused suites; expect authoritative-only, fallback, compatibility, validator, race, and cap tests to pass.
- [ ] Commit the modified production/tests with `git commit -m 'feat: finalize authoritative dictation cleanup flow'`.

### Task 4: Wire release-only Whisper and independent caption state

**Files:** Modify `Sources/sAiity/AppDelegate.swift`, `DictationController.swift`, `DictationState.swift`, and relevant `ModelLifecycleTests.swift`/`DictationControllerTests.swift`.

**Interfaces:** The preparation closure exposes download/readiness only. The release closure constructs `WhisperDictationBackend(choice:locale:)` after capture release and calls `transcribe(samples:locale:)`; caption preparation continues through `ASRBackendPool`.

- [ ] Add RED tests proving preparation never instantiates Whisper, calls `loadModels`, or opens the microphone; release creates it only after `finishDictation`; caption readiness and selected streaming engine do not change while Whisper is downloading/preparing.
- [ ] Run focused tests and record the expected RED failures.
- [ ] Wire callbacks so `.preparing` prepares files/readiness, `.dictating` uses the existing streaming backend, and `.transcribing` releases that backend before constructing Whisper. Keep generation guards before/after awaits and before insertion.
- [ ] Run focused GREEN tests and existing `StreamingASRBackendTests`.
- [ ] Commit `git commit -am 'feat: keep Whisper dictation separate from captions'`.

### Task 5: Add toast phases, saved-frame behavior, and real AppKit accessibility

**Files:** Modify `Sources/sAiity/DictationState.swift`, `DictationToastWindow.swift`, and `OverlayWindow.swift`; add RED tests to `DictationToastWindowTests.swift`.

**Interfaces:** Phase mapping covers permission, preparation, recording, transcribing, cleaning, translating, inserting, success, limit, failure, and recovery using existing names plus exact new cases. Use AppKit `setAccessibilityRole(.status)`, `setAccessibilityLabel(_:)`, `setAccessibilityValue(_:)`, `setAccessibilityEnabled(_:)`, and `NSAccessibility.post(element:notification:)`; Reset Position invokes the existing `FrameStore` reset action.

- [ ] Write RED pure-value tests for all phase mappings, frame immutability on phase changes, drag/clamping/current-screen placement, Reduce Motion direct dismissal, Reduce Transparency opaque surface, Increase Contrast, stable AX label/value/live announcement, and Reset Position action.
- [ ] Run the focused suite and expect RED for new phases/AX values.
- [ ] Implement only existing toast/overlay boundaries. Keep the saved frame unchanged during phase updates; reuse `OverlayWindow` screen/clamp and `FrameStore`. Expose status role, stable label/value, live announcement, and a labeled Reset Position control using the exact AppKit APIs above; do not add an accessibility protocol.
- [ ] Run GREEN and existing overlay geometry tests.
- [ ] Commit `git commit -am 'feat: expose dictation toast states accessibly'`.

### Task 6: Add scoped settings, recovery actions, and complete localization

**Files:** Modify `SettingsWindow.swift`, `SettingsPages.swift`, `DictationState.swift`, and `Resources/Localizable.xcstrings`; add RED tests to `SettingsWindowTests.swift` and `LocalizationTests.swift`.

**Interfaces:** Persist cleanup enabled (false), `ModelChoice`, and canonical dictation locale independently from `ASREngine.selected` and translation settings. Actions are concrete `download`, `retry`, `remove`, and existing Models-pane navigation; no duplicate model screen.

- [ ] Write RED tests for defaults, independent persistence, exact two Whisper choices, every `LanguageCatalog.all` locale, readiness/actions, Not ready -> existing Models pane, permission recovery, captions/Whisper independence, readable icon-and-label toolbar, and key/placeholder coverage.
- [ ] Run focused release tests and expect RED.
- [ ] Add dictation controls for cleanup default-off, existing streaming recognizer choice, Base/Small readiness/actions, and locale picker over `LanguageCatalog.all`. Use existing Models navigation when cleanup or Whisper is not ready. Add exactly these new catalog keys: `Dictation cleanup`, `Clean up dictated text`, `Whisper dictation`, `Whisper model`, `Base`, `Small`, `Download`, `Retry`, `Remove`, `Not ready`, `Ready`, `Preparing dictation`, `Transcribing`, `Cleaning up`, `Dictation limit reached`, `Permission required`, `Open System Settings`, `Reset Position`, `Recovery`, `Dictation failed`, `Translated and inserted`, `Inserted and copied`, `Translation unavailable — cleaned text inserted and copied`. Give every key English plus `fr`, `es`, `de`, and `ja`; preserve `%@`/`%lld`/`%f` placeholders exactly where present and compare placeholder multisets.
- [ ] Run GREEN settings/localization tests and confirm no caption readiness or translation preference is mirrored.
- [ ] Commit `git commit -am 'feat: add dictation settings and localization'`.

### Task 7: Execute regression, build, and manual acceptance gates

**Files:** No planned production/test additions. Only repair a verified defect in its owning earlier file; do not add new tests in this task.

**Interfaces:** Consume all prior concrete symbols. This task produces verification evidence only.

- [ ] Run existing focused suites: `swift test -c release -Xswiftc -enable-testing -Xswiftc -DSAIITY_TEST_HOOKS --filter 'WhisperDictationBackendTests|DictationMicrophoneCaptureTests|DictationControllerTests|DictationToastWindowTests|SettingsWindowTests|ModelLifecycleTests|StreamingASRBackendTests'`; expect nonzero tests executed and exit code 0.
- [ ] Run `swift test -c release -Xswiftc -enable-testing -Xswiftc -DSAIITY_TEST_HOOKS` and `swift build -c release`; expect exit code 0 and WhisperKit 1.0.0 linked. Run `./build-app.sh`; record the produced `.app` path.
- [ ] Launch that app and manually gate independent Captions/Dictation settings, Not ready recovery, Base/Small actions, permission recovery, and every toast phase. With one external display verify drag/current-screen/clamped placement and saved-frame immutability.
- [ ] Manually verify `320000` accepted samples, conversion failures not counting, release/limit/cancel first-wins behavior, and captions streaming during Whisper work. In Accessibility Inspector verify AX status role, stable label/value, live announcement, Reset Position, and Reduce Motion/Transparency/Increase Contrast behavior.
- [ ] Self-review against every spec section; run a literal scan for the repository's prohibited placeholder markers and vague planning language and expect no matches. Run `git diff --check` and `git status --short`; expect only this plan changed before commit.
- [ ] Commit only the plan with `git add docs/superpowers/plans/2026-08-30-dictation-cleanup-whisper-ui.md && git commit -m 'docs: correct dictation implementation plan'`. Do not reset, release, upload, or push.

## Self-Review Record

- Spec coverage: Tasks 1-2 cover dependency, local source signatures, identifiers, locales, readiness, marker, cache, and single-flight; Task 3 covers authoritative finalization, cleanup, compatibility, validator, fallback, sample cap, and races; Task 4 covers release-only Whisper and caption independence; Task 5 covers phases, frame, AX, and display/accessibility gates; Task 6 covers settings and localization; Task 7 covers existing tests/build/manual acceptance and no new integration-test step.
- Type consistency: `languageHint` is nonthrowing `String?`; `finishDictation()` is the sole authoritative source; `cleanup` is an injectable closure; Whisper array transcription returns `[[TranscriptionResult]?]`; all task interfaces consume these names.
- Catalog canonicalization: coverage compares canonical BCP-47 sets, Whisper hints compare base ISO-639-1 values, and placeholders compare exact multisets.
