# Local Dictation Cleanup and Whisper Batch Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add an on-device, opt-in dictation cleanup pipeline and release-time multilingual Whisper batch recognition while preserving authoritative-only insertion, independent live captions, and the existing native macOS settings/toast experience.

**Architecture:** Keep `TranscriptionBackend`, `DictationController`, `ASRBackendPool`, `LocalModels`, `OverlayWindow.FrameStore`, `SettingsWindowController`, and the existing settings pages as the integration points. Add only one concrete `WhisperDictationBackend` file because WhisperKit is a dictation-only batch engine; cleanup calls the existing concrete `LocalLLMTranslator` Qwen/Gemma-compatible GGUF path directly. Do not add a Manager, Service, Factory, Strategy, Protocol, Adapter, Coordinator, Provider, Resolver, Registry, or model subsystem.

**Tech Stack:** Swift 6 / SwiftPM in Swift 5 language mode, macOS 26 AppKit and SwiftUI, WhisperKit 1.0.0, existing AVAudioEngine capture and `TranscriptionBackend`, existing LLM.swift `LocalLLMTranslator`, Swift Testing, Apple String Catalog localization, `build-app.sh`.

## Global Constraints

- Work only in `/Users/enrico/Documents/GitHub/saiity`; baseline is clean `HEAD 85d47b45331368ea2270df15f6b3b5f96278ca50`.
- The only implementation pipeline is `authoritative transcript -> optional cleanup -> optional dictation translation -> one clipboard/text insertion operation`.
- Streaming partials, rolling caption finals, and intermediate hypotheses never enter cleanup, translation, clipboard, or insertion.
- Cleanup is default-off and uses only the existing Qwen/Gemma-compatible GGUF generation path; never call `HyMT2Translator`, MADLAD, or `TranslationEngine.effective` from cleanup.
- Whisper is dictation-only, created after recording release; live captions retain their existing `ASRBackendPool` and streaming backend.
- Offer exactly `openai_whisper-base` and `openai_whisper-small`; `.en` variants and any other selectable Whisper model are forbidden.
- Add exactly `.package(url: "https://github.com/argmaxinc/WhisperKit.git", exact: "1.0.0")` and `.product(name: "WhisperKit", package: "WhisperKit")`; do not raise the version.
- Every `LanguageCatalog.all` language is selectable; supported locale persistence remains canonical BCP-47, while Whisper receives only a supported base ISO-639-1 language or `nil` with detection.
- Readiness requires required files plus an sAiity completion marker written after `loadModels(prewarmMode: true)`; downloads use a temporary directory and marker-last installation.
- One operation per Whisper identifier is in flight; later download/prewarm/remove calls await the first result. Cancellation removes only the interrupted partial directory.
- The audio cap is exactly `320000` successfully converted mono 16 kHz samples; conversion failures do not advance the count, and the first terminal transition wins.
- Cleanup validation is exactly trim controls, reject empty, reject Markdown fences, reject explanatory prefix, reject multiple commentary paragraphs, otherwise accept plain text. Do not add ratio, language, echo, quote, wrapper, or other heuristics.
- Cleanup failure or cancellation falls back to authoritative original; translation failure after successful cleanup retains cleaned text; cancellation/new generation performs no write.
- Captions have independent readiness and settings; Whisper state never mirrors caption state.
- Use the existing release test flags: `swift test -c release -Xswiftc -enable-testing -Xswiftc -DSAIITY_TEST_HOOKS`.
- Do not change iOS, external APIs, upload, release metadata, navigation redesign, or release/push workflows.

## Files and Responsibilities

- `Package.swift`: WhisperKit package and executable product dependency.
- `Sources/sAiity/WhisperDictationBackend.swift`: the sole concrete WhisperKit download/setup/readiness/batch holder, including model identifiers, locale hints, marker/cache actions, and single-flight state.
- `Sources/sAiity/TranscriptionBackend.swift`: only the smallest dictation-batch boundary needed by the controller, without changing caption semantics.
- `Sources/sAiity/DictationMicrophoneCapture.swift`: accepted converted-sample accounting and terminal cap delivery.
- `Sources/sAiity/DictationController.swift`: release-to-batch selection, cleanup/translation ordering, generation invalidation, phase transitions, and one insertion.
- `Sources/sAiity/AppDelegate.swift`: concrete dependency wiring, prewarm, toast phase mapping, permission recovery, and caption independence.
- `Sources/sAiity/DictationState.swift`: new value types/constants for Whisper selection, cleanup state, and explicit phases only where existing state is the correct home.
- `Sources/sAiity/LocalModels.swift`: Qwen/Gemma compatibility/readiness query only; no new model registry.
- `Sources/sAiity/SettingsWindow.swift`: persisted dictation cleanup/Whisper preferences and readiness/action state.
- `Sources/sAiity/SettingsPages.swift`: scoped dictation controls, recovery/navigation actions, localization, and readable native toolbar content.
- `Sources/sAiity/DictationToastWindow.swift`: phase presentation, saved-frame drag behavior, multiscreen placement, contrast/motion/accessibility behavior.
- `Resources/Localizable.xcstrings`: new user-visible strings.
- `Tests/sAiityTests/WhisperDictationBackendTests.swift`: model IDs, locales, API contract, marker/cache, cancellation, retry, remove, and single-flight tests.
- `Tests/sAiityTests/DictationMicrophoneCaptureTests.swift`: 320000-sample limit and conversion-failure accounting.
- `Tests/sAiityTests/DictationControllerTests.swift`: cleanup validator/pipeline/races/insertion/caption independence.
- `Tests/sAiityTests/DictationToastWindowTests.swift`: phases, frames, accessibility, contrast/motion, and multiscreen pure behavior.
- `Tests/sAiityTests/SettingsWindowTests.swift` and `Tests/sAiityTests/LocalizationTests.swift`: settings persistence/navigation and string coverage.

## Interfaces

- `WhisperDictationBackend` consumes `Locale`, `AVAudioPCMBuffer`/`[Float]`, `FileManager`, and verified WhisperKit 1.0.0 APIs; it produces `prepare(locale:progress:)`, `prewarm(locale:)`, `transcribe(samples:locale:) async throws -> String`, `download`, `retry`, `remove`, `isReady`, and the exact two model identifiers.
- `DictationController` consumes one dictation backend factory, authoritative `finishDictation()`, `DictationTranslationConfiguration`, and existing `TextInserter`; it produces exactly one downstream `insert(_:)` call for a valid nonempty session.
- Cleanup consumes only `LocalModel.selected` when its file is a downloaded Qwen/Gemma-compatible GGUF and existing `LocalLLMTranslator.prepare` plus generation; it produces validated plain text or an explicit failure.
- `DictationToastWindow` consumes `DictationPhase` and existing `FrameStore`; it produces stable status/value/live accessibility output and never changes the saved frame during phase updates.
- Settings consumes independent dictation preferences and Whisper readiness/actions; it produces navigation to the existing Models pane when cleanup or Whisper is not ready and does not alter caption readiness.

---

### Task 1: Add WhisperKit dependency, multilingual selection, readiness, and cache actions

**Files:**
- Modify: `/Users/enrico/Documents/GitHub/saiity/Package.swift:10-47`
- Create: `/Users/enrico/Documents/GitHub/saiity/Sources/sAiity/WhisperDictationBackend.swift`
- Create: `/Users/enrico/Documents/GitHub/saiity/Tests/sAiityTests/WhisperDictationBackendTests.swift`
- Test: `/Users/enrico/Documents/GitHub/saiity/Tests/sAiityTests/LanguageTests.swift`

**Interfaces:** Consumes `LanguageCatalog.all`, `LanguageCatalog.popular`, `MADLADLanguages.canonicalCodes`, `ModelVariant.base/small`, and WhisperKit 1.0.0 APIs. Produces `WhisperDictationBackend.ModelChoice` with `base`/`small`, identifiers `openai_whisper-base`/`openai_whisper-small`, `WhisperDictationBackend.languageHint(for:) -> String?`, readiness/download/retry/remove/prewarm methods, and a concrete batch `transcribe` entry point for Task 2.

- [ ] **Step 1: Write the failing tests.** Add tests that assert the exact package URL/version/product declaration by reading `Package.swift`; exact model identifiers and descriptions; `Set(LanguageCatalog.all.map(\.code)) == MADLADLanguages.canonicalCodes.union(LanguageCatalog.popular)`; BCP-47 locale hints (`de-DE -> de`, `zh-Hant-TW -> zh`, unsupported base -> nil/detect); explicit unsupported hint rejection; marker-last readiness; interrupted temporary-directory deletion; retry; remove; and same-identifier download/prewarm/remove single-flight. Use an injected `WhisperKitClient` test double only if required by the real call boundary; do not add a production protocol.

```swift
@Test("Whisper offers exactly the two multilingual model identifiers")
func multilingualModelIdentifiers() {
    #expect(WhisperDictationBackend.ModelChoice.all.map(\.identifier) == [
        "openai_whisper-base", "openai_whisper-small"
    ])
    #expect(WhisperDictationBackend.ModelChoice.all.map(\.description) == ["base", "small"])
}

@Test("all catalog languages are selectable by Whisper")
func catalogCoverage() {
    #expect(Set(WhisperDictationBackend.supportedLanguageCodes) ==
            MADLADLanguages.canonicalCodes.union(LanguageCatalog.popular))
}

@Test("locale hint keeps persistence specificity but sends Whisper the base code")
func localeHints() throws {
    #expect(try WhisperDictationBackend.languageHint(for: Locale(identifier: "de-DE")) == "de")
    #expect(try WhisperDictationBackend.languageHint(for: Locale(identifier: "zh-Hant-TW")) == "zh")
    #expect(try WhisperDictationBackend.languageHint(for: Locale(identifier: "xx-ZZ")) == nil)
}
```

- [ ] **Step 2: Run RED.** Run `swift test -c release -Xswiftc -enable-testing -Xswiftc -DSAIITY_TEST_HOOKS --filter WhisperDictationBackendTests` and `swift test -c release -Xswiftc -enable-testing -Xswiftc -DSAIITY_TEST_HOOKS --filter LanguageTests`. Expected: compile/test failure because the package product and `WhisperDictationBackend` do not exist, and the exact model/cache contracts are absent.

- [ ] **Step 3: Implement the minimal dependency and concrete holder.** Add exactly:

```swift
.package(url: "https://github.com/argmaxinc/WhisperKit.git", exact: "1.0.0")
```

and under `sAiity.dependencies` exactly `.product(name: "WhisperKit", package: "WhisperKit")`. In the new file import `WhisperKit`, define only `enum ModelChoice { case base, small }`, map `base`/`small` to the verified identifiers, derive `supportedLanguageCodes` from `LanguageCatalog.all`, canonicalize locale to a base code, and throw for an explicitly unsupported hint before transcription. Implement app-private per-identifier folders, a temporary download folder, marker written only after `WhisperKit.download(...)`, `WhisperKit.setupModels`, and `loadModels(prewarmMode: true)` succeed; cancellation removes the temporary folder; retry removes it first; remove uses `FileManager.removeItem` on folder and marker. Serialize operations by identifier with stored tasks in this concrete type. Do not add a global coordinator or call a nonexistent WhisperKit remove API.

- [ ] **Step 4: Run GREEN.** Run the two focused commands from Step 2. Expected: all model ID, locale, catalog, marker, cleanup, retry, remove, and single-flight tests pass; `Package.resolved` remains at WhisperKit 1.0.0 revision `25c62997041c134b03ca82731ce2f6fd2cae1eb9`.

- [ ] **Step 5: Commit.** Run `git add Package.swift Sources/sAiity/WhisperDictationBackend.swift Tests/sAiityTests/WhisperDictationBackendTests.swift Tests/sAiityTests/LanguageTests.swift && git commit -m "feat: add Whisper dictation model lifecycle"`.

### Task 2: Add concrete dictation-only batch recognition and audio cap

**Files:**
- Modify: `/Users/enrico/Documents/GitHub/saiity/Sources/sAiity/TranscriptionBackend.swift:93-139`
- Modify: `/Users/enrico/Documents/GitHub/saiity/Sources/sAiity/WhisperDictationBackend.swift`
- Modify: `/Users/enrico/Documents/GitHub/saiity/Sources/sAiity/DictationMicrophoneCapture.swift:28-105`
- Modify: `/Users/enrico/Documents/GitHub/saiity/Sources/sAiity/DictationState.swift:75-133`
- Test: `/Users/enrico/Documents/GitHub/saiity/Tests/sAiityTests/WhisperDictationBackendTests.swift`
- Test: `/Users/enrico/Documents/GitHub/saiity/Tests/sAiityTests/DictationMicrophoneCaptureTests.swift`
- Test: `/Users/enrico/Documents/GitHub/saiity/Tests/sAiityTests/DictationControllerTests.swift`

**Interfaces:** Consumes Task 1's concrete model choice/readiness/cache actions. Produces `WhisperDictationBackend` as the only batch holder, a dictation-only controller backend boundary, `DictationAudioSampleLimit.maximumSamples == 320000`, and a single terminal cap event. Existing streaming `ASRBackendPool` behavior remains unchanged.

- [ ] **Step 1: Write the failing tests.** Add tests for the exact `WhisperKit.setupModels`, `download`, `loadModels(prewarmMode: true)`, array-based `transcribe` with `DecodingOptions`, and `TranscriptionResult.text` use; authoritative audio sample collection in order; exactly 320000 accepted samples ending capture once; conversion errors leaving the count unchanged; release/cap/cancel/new-generation races selecting one terminal transition; and a stale callback draining without feeding a new session.

```swift
@Test("the cap counts only accepted 16 kHz mono samples")
func capCountsConvertedSamplesOnly() {
    var limit = DictationAudioSampleLimit()
    #expect(limit.accepted(sampleCount: 319999) == .continue)
    #expect(limit.accepted(sampleCount: 1) == .limit)
    #expect(limit.accepted(sampleCount: 10) == .alreadyTerminal)
    #expect(limit.acceptedConversionFailure() == .alreadyTerminal)
}
```

- [ ] **Step 2: Run RED.** Run `swift test -c release -Xswiftc -enable-testing -Xswiftc -DSAIITY_TEST_HOOKS --filter 'WhisperDictationBackendTests|DictationMicrophoneCaptureTests|DictationControllerTests'`. Expected: failure because no batch backend, sample limit, terminal event, or array transcription implementation exists.

- [ ] **Step 3: Implement the minimal batch path.** Give `WhisperDictationBackend` one configured WhisperKit instance, collect converted `[Float]` samples synchronously in order, pass a `DecodingOptions(language: hint, detectLanguage: hint == nil)` to the real array overload, and join returned `TranscriptionResult.text` values. Add only the narrow `TranscriptionBackend` default methods needed for dictation batch ownership; do not route this backend through streaming caption callbacks. In `DictationMicrophoneCapture`, count only `output.frameLength` after `error == nil`, stop immediately at 320000, and deliver one `.limit` terminal event. In controller state, make release, limit, cancel, and generation invalidation idempotent on the main actor so the first transition drains/releases once.

- [ ] **Step 4: Run GREEN.** Run the focused command from Step 2. Expected: all real-API contract, ordered sample, 320000 cap, conversion-failure, stale-drain, and terminal-race tests pass; existing streaming tests still pass when run as `--filter StreamingASRBackendTests`.

- [ ] **Step 5: Commit.** Run `git add Sources/sAiity/TranscriptionBackend.swift Sources/sAiity/WhisperDictationBackend.swift Sources/sAiity/DictationMicrophoneCapture.swift Sources/sAiity/DictationState.swift Tests/sAiityTests/WhisperDictationBackendTests.swift Tests/sAiityTests/DictationMicrophoneCaptureTests.swift Tests/sAiityTests/DictationControllerTests.swift && git commit -m "feat: add dictation-only Whisper batch recognition"`.

### Task 3: Add local cleanup, exact validation, fallback, ordering, and state

**Files:**
- Modify: `/Users/enrico/Documents/GitHub/saiity/Sources/sAiity/DictationState.swift:75-133`
- Modify: `/Users/enrico/Documents/GitHub/saiity/Sources/sAiity/DictationController.swift:29-365`
- Modify: `/Users/enrico/Documents/GitHub/saiity/Sources/sAiity/LocalModels.swift:220-268`
- Test: `/Users/enrico/Documents/GitHub/saiity/Tests/sAiityTests/DictationControllerTests.swift`
- Test: `/Users/enrico/Documents/GitHub/saiity/Tests/sAiityTests/LocalModelTests.swift`

**Interfaces:** Consumes authoritative text from Task 2 and existing `LocalModel.selected`/`LocalLLMTranslator`. Produces `DictationCleanupValidator.validate(_:)`, `DictationCleanupConfiguration(enabled:)`, cleanup phase/state, and controller ordering: cleanup success feeds translation; cleanup failure feeds original; translation failure after cleanup keeps cleaned text; only one final insertion.

- [ ] **Step 1: Write the failing tests.** Add validator tests for trimming controls, empty/fenced/explanatory-prefix/multiple-commentary rejection and plain-text acceptance. Add tests proving cleanup receives only authoritative completion, never partials; production cleanup source contains no `HyMT2Translator`, `MADLAD`, or `TranslationEngine.effective`; no compatible selected GGUF yields `Not ready`/Models navigation; success/failure fallback ordering; cancellation/new generation causes no insertion; and one insertion is made.

```swift
@Test("cleanup accepts only the specified plain-text shape")
func cleanupValidationContract() {
    #expect(DictationCleanupValidator.validate("  Hello. \n") == "Hello.")
    #expect(DictationCleanupValidator.validate(" ") == nil)
    #expect(DictationCleanupValidator.validate("```text\nHello\n```") == nil)
    #expect(DictationCleanupValidator.validate("Here is the cleaned text: Hello") == nil)
    #expect(DictationCleanupValidator.validate("Hello.\n\nNote: done") == nil)
}
```

- [ ] **Step 2: Run RED.** Run `swift test -c release -Xswiftc -enable-testing -Xswiftc -DSAIITY_TEST_HOOKS --filter DictationControllerTests` and `swift test -c release -Xswiftc -enable-testing -Xswiftc -DSAIITY_TEST_HOOKS --filter LocalModelTests`. Expected: compile/test failure because cleanup state, validator, compatibility/readiness, and pipeline ordering are absent.

- [ ] **Step 3: Implement the minimal existing-path changes.** Add the validator as a value type/function in `DictationState.swift`; add one cleanup closure to `DictationController` beside the existing translation closure. Extend concrete `LocalLLMTranslator` at `Sources/sAiity/Translators.swift:265-450` with one `cleanup(_ text: String) async -> String?` method that uses its existing `prepare(from:to:progress:)` loading path and private `generate(system:user:)` with the dedicated cleanup system/user prompts; do not expose a new protocol. The controller closure selects only a downloaded built-in/custom Qwen/Gemma-compatible model, invokes that concrete method with the authoritative transcript only, then validates exact output. Keep `TranslationEngine.effective` exclusively in the existing caption/dictation translation path. In `finish(session:)`, capture authoritative text, set `.cleaning` only when enabled/ready, choose validated cleaned text or original, then optionally translate that chosen text and call `inserter.insert(output)` once. Guard generation before every downstream await and before insertion.

- [ ] **Step 4: Run GREEN.** Run the focused commands from Step 2 plus `swift test -c release -Xswiftc -enable-testing -Xswiftc -DSAIITY_TEST_HOOKS --filter 'DictationControllerTests|LocalModelTests'`. Expected: validator, exclusion, Not-ready, fallback/order, cancellation, and one-insertion tests pass.

- [ ] **Step 5: Commit.** Run `git add Sources/sAiity/DictationState.swift Sources/sAiity/DictationController.swift Sources/sAiity/LocalModels.swift Tests/sAiityTests/DictationControllerTests.swift Tests/sAiityTests/LocalModelTests.swift && git commit -m "feat: add opt-in local dictation cleanup"`.

### Task 4: Integrate controller/AppDelegate, prewarm, toast phases, and caption independence

**Files:**
- Modify: `/Users/enrico/Documents/GitHub/saiity/Sources/sAiity/AppDelegate.swift:20-110,600-710`
- Modify: `/Users/enrico/Documents/GitHub/saiity/Sources/sAiity/DictationController.swift:48-190,285-365`
- Modify: `/Users/enrico/Documents/GitHub/saiity/Sources/sAiity/DictationState.swift:75-110`
- Test: `/Users/enrico/Documents/GitHub/saiity/Tests/sAiityTests/DictationControllerTests.swift`
- Test: `/Users/enrico/Documents/GitHub/saiity/Tests/sAiityTests/ModelLifecycleTests.swift`

**Interfaces:** Consumes Task 1 readiness/prewarm and Task 3 cleanup/phase contracts. Produces AppDelegate wiring that constructs Whisper only for dictation, prewarms it without altering caption backend state, maps every required phase, preserves captions independence, and keeps one insertion.

- [ ] **Step 1: Write the failing tests.** Add tests for prewarm on dictation enable/launch, Whisper creation only after recording release, all phases `permission/preparing/recording/transcribing/cleaning/translating/inserting/success/limit/failure/recovery`, captions continuing with their own backend/readiness, and exactly one insertion for cleanup+translation success.

- [ ] **Step 2: Run RED.** Run `swift test -c release -Xswiftc -enable-testing -Xswiftc -DSAIITY_TEST_HOOKS --filter 'DictationControllerTests|ModelLifecycleTests'`. Expected: failure because AppDelegate has no Whisper dictation dependency, no cleanup/prewarm phase wiring, and no explicit limit/recovery phase mapping.

- [ ] **Step 3: Implement the minimal wiring.** Add a concrete `WhisperDictationBackend` property/factory to `AppDelegate` only at the dictation boundary; call its prewarm/readiness action from existing dictation preparation hooks; pass it into `DictationController` after release while leaving `asrBackendPool` as the caption provider. Map controller phases to localized toast text without changing frame position. Route permission denied to actionable recovery, cap to `.limit`, and success/failure to existing feedback dismissal. Keep caption `ASREngine` and `CaptionSession` state untouched.

- [ ] **Step 4: Run GREEN.** Run the focused command from Step 2. Expected: prewarm, phase, caption independence, cleanup/translation ordering, and single-insertion tests pass.

- [ ] **Step 5: Commit.** Run `git add Sources/sAiity/AppDelegate.swift Sources/sAiity/DictationController.swift Sources/sAiity/DictationState.swift Tests/sAiityTests/DictationControllerTests.swift Tests/sAiityTests/ModelLifecycleTests.swift && git commit -m "feat: integrate Whisper dictation lifecycle"`.

### Task 5: Make the dictation toast draggable, stable, accessible, and multiscreen-safe

**Files:**
- Modify: `/Users/enrico/Documents/GitHub/saiity/Sources/sAiity/DictationToastWindow.swift:1-133`
- Modify: `/Users/enrico/Documents/GitHub/saiity/Sources/sAiity/OverlayWindow.swift:1-70` only if shared `FrameStore` access requires it
- Test: `/Users/enrico/Documents/GitHub/saiity/Tests/sAiityTests/DictationToastWindowTests.swift`
- Test: `/Users/enrico/Documents/GitHub/saiity/Tests/sAiityTests/BubbleGeometryTests.swift`

**Interfaces:** Consumes Task 4 `DictationPhase` updates and existing `FrameStore` persistence/clamping. Produces a separate toast with subtitle-bubble language, draggable saved frame, best-display placement, stable size during phase updates, role/status/value/live announcement, Reset Position, Reduced Motion direct dismissal, Reduced Transparency opaque surface, and Increase Contrast styling.

- [ ] **Step 1: Write the failing tests.** Add pure tests asserting phase text/accessibility mapping, phase updates preserve the saved frame, drag persists a clamped frame on the active display, a disconnected-display frame moves to the best available screen, `accessibilityRole == .status`/stable label/value/live announcement exist, Reset Position clears/restores the frame, and appearance flags change surface/border without altering layout.

- [ ] **Step 2: Run RED.** Run `swift test -c release -Xswiftc -enable-testing -Xswiftc -DSAIITY_TEST_HOOKS --filter 'DictationToastWindowTests|BubbleGeometryTests'`. Expected: failure because the current panel ignores mouse events, is not movable, has no frame persistence/accessibility contract, and phase updates only expose a plain label.

- [ ] **Step 3: Implement the minimal window/view changes.** Replace `ignoresMouseEvents = true` with a narrow draggable content view that updates `FrameStore.save(frame)` on movement and clamps with existing display helpers; keep phase updates from calling placement. Add a status accessibility element with stable label/value and announcement, a Reset Position action, and use `NSWorkspace.accessibilityDisplayShouldReduceMotion`, `accessibilityDisplayShouldReduceTransparency`, and `accessibilityDisplayShouldIncreaseContrast` to choose direct dismissal, opaque readable background, and stronger text/border. Preserve the current effect/spacing and use no new window abstraction.

- [ ] **Step 4: Run GREEN.** Run the focused command from Step 2. Expected: toast frame, drag, multiscreen, accessibility, and appearance tests pass without regressing existing timeout/order-front tests.

- [ ] **Step 5: Commit.** Run `git add Sources/sAiity/DictationToastWindow.swift Sources/sAiity/OverlayWindow.swift Tests/sAiityTests/DictationToastWindowTests.swift Tests/sAiityTests/BubbleGeometryTests.swift && git commit -m "feat: polish dictation toast window"`.

### Task 6: Add scoped Settings controls, readiness actions, recovery, and localization

**Files:**
- Modify: `/Users/enrico/Documents/GitHub/saiity/Sources/sAiity/SettingsWindow.swift:10-22,176-261,300-430,720-765`
- Modify: `/Users/enrico/Documents/GitHub/saiity/Sources/sAiity/SettingsPages.swift:139-290,423-640,1396-1535`
- Modify: `/Users/enrico/Documents/GitHub/saiity/Sources/sAiity/DictationState.swift`
- Modify: `/Users/enrico/Documents/GitHub/saiity/Resources/Localizable.xcstrings`
- Test: `/Users/enrico/Documents/GitHub/saiity/Tests/sAiityTests/SettingsWindowTests.swift`
- Test: `/Users/enrico/Documents/GitHub/saiity/Tests/sAiityTests/LocalizationTests.swift`

**Interfaces:** Consumes Task 1 model actions, Task 3 cleanup readiness, Task 4 permission/recovery hooks, and existing `ModelsView` navigation. Produces default-off cleanup toggle, existing streaming recognizer choice, exactly two Whisper choices, locale choice across `LanguageCatalog.all`, readiness badges/actions Download/Retry/Remove, Models recovery navigation, permission recovery, readable icon-and-label toolbar, and separate caption/Whisper state.

- [ ] **Step 1: Write the failing tests.** Add tests asserting cleanup defaults false, Whisper selection persists independently from `ASREngine.selected` and `TranslationEngine.selected`, Not ready opens the existing Models pane, Download/Retry/Remove invoke the concrete backend actions, permission recovery opens the existing System Settings destination, toolbar items have readable labels, caption readiness does not change when Whisper state changes, and every new `String(localized:)` key is present in `Localizable.xcstrings`.

- [ ] **Step 2: Run RED.** Run `swift test -c release -Xswiftc -enable-testing -Xswiftc -DSAIITY_TEST_HOOKS --filter 'SettingsWindowTests|LocalizationTests'`. Expected: failure because the new preferences, actions, recovery routing, and localized strings are absent.

- [ ] **Step 3: Implement the scoped UI.** Add only persisted properties to `AppState` for cleanup enabled, Whisper choice, and dictation locale. Keep the existing `engine` picker as the streaming recognizer choice; add a distinct dictation subsection with Base/Small, readiness, Download/Retry/Remove, and locale picker using `LanguageCatalog.all`. When no compatible local cleanup model or Whisper marker exists, show `Not ready` with a button that selects the existing Models tab rather than duplicating a model screen. Keep captions’ readiness screen and `ASREngine` state independent. Preserve the existing native `.preference` toolbar and `.iconAndLabel`, fixing copy/contrast through labels and solid backdrop rather than a new navigation structure. Add all new strings to the string catalog.

- [ ] **Step 4: Run GREEN.** Run the focused command from Step 2. Expected: persistence, actions, readiness/recovery, independence, toolbar readability, and localization tests pass.

- [ ] **Step 5: Commit.** Run `git add Sources/sAiity/SettingsWindow.swift Sources/sAiity/SettingsPages.swift Sources/sAiity/DictationState.swift Resources/Localizable.xcstrings Tests/sAiityTests/SettingsWindowTests.swift Tests/sAiityTests/LocalizationTests.swift && git commit -m "feat: add dictation cleanup and Whisper settings"`.

### Task 7: Run integration/regression suite, build the app, and perform manual UI gates

**Files:**
- Modify: none expected; only update earlier files if a verified test/build defect is found.
- Test: all existing and new tests under `/Users/enrico/Documents/GitHub/saiity/Tests/sAiityTests`
- Verify: `/Users/enrico/Documents/GitHub/saiity/build-app.sh`, built `.app`, launched app screenshots, and accessibility inspection.

**Interfaces:** Consumes all prior concrete types and committed behavior. Produces integration evidence for package resolution, full tests, release build, app packaging, launch, screenshots, multi-display placement, readable toolbar, toast phases, and accessibility. It produces no release upload or push.

- [ ] **Step 1: Write the failing integration checks before implementation is considered complete.** Add/retain an integration test that starts a dictation session with a partial and authoritative final, enables cleanup and translation, and asserts the authoritative-only one-insertion contract; add a regression test that captions remain active and use the streaming backend while Whisper is downloading/prewarming.

- [ ] **Step 2: Run the focused integration RED/GREEN gate.** Run `swift test -c release -Xswiftc -enable-testing -Xswiftc -DSAIITY_TEST_HOOKS --filter 'DictationControllerTests|WhisperDictationBackendTests|DictationMicrophoneCaptureTests|DictationToastWindowTests|SettingsWindowTests|ModelLifecycleTests|StreamingASRBackendTests'`. Expected after prior tasks: exit code 0 and all focused suites pass; if not, diagnose the named failing contract and make the smallest correction in its owning file before continuing.

- [ ] **Step 3: Run the full test suite and release build.** Run `swift test -c release -Xswiftc -enable-testing -Xswiftc -DSAIITY_TEST_HOOKS` and then `swift build -c release`. Expected: exit code 0 for both, no test disabled/skipped to hide a failure, and the executable links WhisperKit 1.0.0.

- [ ] **Step 4: Build the app with the repository script.** Run `./build-app.sh`. Expected: exit code 0 and the script reports a produced `.app`; record the exact output path from the script. Do not run `--install`, notarization, upload, release, or push.

- [ ] **Step 5: Launch and inspect the real app.** Launch the produced app from the recorded path, open Settings, and capture screenshots showing the readable toolbar, independent Captions/Dictation controls, Not ready -> Models recovery, and Base/Small readiness/actions. With one external display connected, move the toast on each display and capture its clamped position; press dictation through permission, preparation, recording, transcribing, cleaning, translating, inserting, success, limit, failure, and recovery states and capture representative frames. Confirm captions remain visible and unchanged while Whisper work occurs.

- [ ] **Step 6: Perform accessibility/manual gates.** In Accessibility Inspector verify the toast exposes role `AXStatus`, stable status label/value, live announcement, and Reset Position. Toggle Reduce Motion, Reduce Transparency, and Increase Contrast and verify direct dismissal, opaque readable surface, and stronger contrast. Verify no phase update moves the saved frame and no toolbar label is erased against the desktop.

- [ ] **Step 7: Self-review and commit the documentation-only plan.** Scan the complete plan for unresolved placeholder or future-work language and expect no matches; manually compare every spec section against Tasks 1-7, verify all referenced types/signatures agree, and confirm current symbols/line anchors were checked. Run `git diff --check`, `git status --short`, and `git diff --stat`. Expected: only `docs/superpowers/plans/2026-08-30-dictation-cleanup-whisper-ui.md` is uncommitted, with no whitespace errors. Then run `git add docs/superpowers/plans/2026-08-30-dictation-cleanup-whisper-ui.md && git commit -m "docs: plan dictation cleanup and Whisper implementation"`. Do not release or push.

## Coverage Review

- Spec processing contract, authoritative-only input, fallback ordering, cancellation, and one insertion: Tasks 2-4 and Task 7.
- Whisper identifiers, full locale union, base-language hinting, nil detection, explicit unsupported rejection, real APIs, marker readiness, temporary cleanup, retry, remove, and per-identifier single-flight: Tasks 1-2.
- 320000 accepted samples, conversion-failure accounting, terminal races, and stale drain: Task 2.
- Qwen/Gemma-only cleanup, exact validator, no HyMT2/MADLAD/effective, Not ready, and Models navigation: Tasks 3 and 6.
- AppDelegate integration, prewarm, phases, caption independence, and one insertion: Task 4.
- Toast style, drag/frame/multiscreen/accessibility/reduced-motion/transparency/contrast: Task 5 and Task 7.
- Settings controls, permissions recovery, recognizer/model/cleanup/readiness/localization and readable toolbar: Task 6 and Task 7.
- Focused tests, full suite, `build-app.sh`, app launch, screenshots, manual display/toolbar/toast/accessibility gates, self-review, and `git diff --check`: Task 7.
