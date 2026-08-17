# Hy-MT2 Translation Specialist Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add Hy-MT2-1.8B Q4_K_M as an opt-in translation-specialized engine while preserving MADLAD as the default.

**Architecture:** Give Hy-MT2 its own translator and fixed model asset instead of treating it as a Qwen variant. Add a shared output validator and explicit Hunyuan template so model-specific behavior is not hidden in the generic local-LLM path.

**Tech Stack:** Swift 6 / SwiftPM, Swift Testing, LLM.swift/llama.cpp, AppKit/SwiftUI, Apple String Catalogs.

## Global Constraints

- Do not modify, stage, commit, or revert the existing dictation changes.
- Keep `TranslationEngine.recommended == .madlad`.
- Add only the 1.8B Q4_K_M model (`1,133,080,448` bytes); do not add STQ 1.25-bit or 2-bit variants.
- Do not claim runtime compatibility or performance until a real model load/generation test has run.
- Use the existing `ModelRegistry`, `DownloadCoordinator`, `FileDownloader`, and translation lifecycle.
- Keep all user-facing additions localized and preserve the existing English, German, French, Spanish, and Japanese catalog structure.

---

### Task 1: Lock the public behavior with failing tests

**Files:**
- Modify: `Tests/sAiityTests/LanguageTests.swift`
- Modify: `Tests/sAiityTests/ModelRegistryTests.swift`
- Create: `Tests/sAiityTests/HyMT2TranslationTests.swift`

**Interfaces:**
- Consumes: the currently missing `TranslationEngine.hyMT2`, `HyMT2LanguageProvider`, `HyMT2Translator.template`, and `TranslationOutputValidator` APIs.
- Produces: executable assertions for engine selection, asset metadata, language mapping, prompt framing, and output rejection.

- [ ] **Step 1: Add failing engine and language assertions**

Add tests that assert:

```swift
#expect(TranslationEngine.recommended == .madlad)
#expect(TranslationEngine.hyMT2.displayName == "Hy-MT2")
#expect(HyMT2LanguageProvider.nativeCode(for: "de-DE") == "German")
#expect(HyMT2LanguageProvider.nativeCode(for: "zh-Hant") == "Traditional Chinese")
#expect(HyMT2LanguageProvider.nativeCode(for: "sw") == nil)
```

- [ ] **Step 2: Add failing registry assertions**

Assert that `ModelRegistry.assets()` contains exactly one `AssetID.hyMT2`, that its advertised size is `1_133_080_448`, that its storage is a file below `ModelRegistry.root`, and that its install and removal closures are present.

- [ ] **Step 3: Add failing template and validator assertions**

Add tests for:

```swift
let prompt = HyMT2Translator.prompt(targetName: "English", source: "guten morgen")
#expect(prompt.contains("<｜hy_User｜>"))
#expect(prompt.contains("<｜hy_Assistant｜>"))
#expect(prompt.contains("Translate into English"))

#expect(TranslationOutputValidator.sanitize("", input: "hello", target: "en") == .rejected(why: "empty", retryable: false))
#expect(TranslationOutputValidator.sanitize("hello", input: "hello", target: "en") == .rejected(why: "echoed input", retryable: true))
```

- [ ] **Step 4: Run the focused tests and verify the expected RED state**

Run:

```bash
swift test -c release -Xswiftc -enable-testing -Xswiftc -DSAIITY_TEST_HOOKS --filter 'LanguageTests|ModelRegistryTests|HyMT2TranslationTests'
```

Expected: compilation fails because the Hy-MT2 types and asset case do not exist yet. No production implementation is written before this RED check.

---

### Task 2: Add the Hy-MT2 engine and fixed asset

**Files:**
- Modify: `Sources/sAiity/DownloadCoordinator.swift:138-145`
- Modify: `Sources/sAiity/TranslationEngine.swift:45-145`
- Modify: `Sources/sAiity/EngineLanguages.swift:19-28`
- Create: `Sources/sAiity/HyMT2Translator.swift`

**Interfaces:**
- Consumes: `ModelAsset`, `DownloadCoordinator.shared`, `FileDownloader.download`, `LLM`, and `TranslationOutputValidator`.
- Produces: `TranslationEngine.hyMT2`, `AssetID.hyMT2`, `HyMT2Translator`, `HyMT2LanguageProvider`, and one downloadable registry row.

- [ ] **Step 1: Add the fixed asset identity and language provider**

Use:

```swift
static let hyMT2 = "mt.hymt2.1.8b.q4"
```

and define the exact 37 model-card language codes/variants as base BCP-47 codes. Resolve `de-DE`, `en-GB`, `pt-BR`, and script variants to the English full language names required by the Hy-MT2 prompt. Return `nil` for languages outside the set.

- [ ] **Step 2: Add the translator lifecycle**

Implement `HyMT2Translator` with:

```swift
static let modelBytes: Int64 = 1_133_080_448
static let modelFile = "Hy-MT2-1.8B-Q4_K_M.gguf"
static let modelURL = URL(string: "https://huggingface.co/tencent/Hy-MT2-1.8B-GGUF/resolve/main/Hy-MT2-1.8B-Q4_K_M.gguf?download=true")!
```

Download through `DownloadCoordinator.shared.run(AssetID.hyMT2)`, validate `FileDownloader.ggufMagic`, load with `LLM(from:template:maxTokenCount:)`, and set Hy-MT2's documented sampling defaults (`topK = 20`, `topP = 0.6`, `temp = 0.7`, `repeatPenalty = 1.05`). Keep the model's context cap at 2048 for sAiity's short sentence workload.

- [ ] **Step 3: Add the explicit Hunyuan template and prompt**

Use the model tokens:

```swift
Template(
    prefix: "<｜hy_begin▁of▁sentence｜>",
    user: ("<｜hy_User｜>", "<｜hy_EOT｜>"),
    bot: ("<｜hy_Assistant｜>", "<｜hy_EOT｜>"),
    stopSequence: "<｜hy_EOT｜>",
    systemPrompt: nil
)
```

The user prompt must require translation only, include the target language’s English name, and preserve the ASR text exactly inside delimiters. Do not use a system prompt because the model card explicitly says the model has no default system prompt.

- [ ] **Step 4: Wire the engine and registry descriptor**

Add `.hyMT2` to `TranslationEngine`, keep `.madlad` as `recommended`, return the new translator from `makeTranslator()`, map its supported languages, and add a `ModelAsset` with `recommended: false`, Apache-2.0 attribution, the exact byte count, a file storage path, `AssetUse.whenTranslator(.hyMT2)`, and an install closure.

- [ ] **Step 5: Run the focused tests and verify GREEN**

Run the focused command from Task 1. Expected: all new and existing focused tests pass.

---

### Task 3: Centralize output validation and preserve the Qwen behavior

**Files:**
- Create: `Sources/sAiity/TranslationOutputValidator.swift`
- Modify: `Sources/sAiity/Translators.swift:450-525`
- Modify: `Tests/sAiityTests/HyMT2TranslationTests.swift`

**Interfaces:**
- Consumes: the current Qwen sanitizer behavior.
- Produces: `TranslationOutputValidator.Verdict` and `TranslationOutputValidator.sanitize(raw:input:target:)`, used by both Qwen and Hy-MT2.

- [ ] **Step 1: Move the existing Qwen sanitizer tests/logic into the shared type without changing behavior**

Preserve removal of thinking tags, role delimiters, labels, excess newlines, empty sentinel, length ratio, exact echo, and recognizable-language mismatch. Keep the existing retryable classification for copied or wrong-language output.

- [ ] **Step 2: Update Qwen to call the shared validator**

Replace `LocalLLMTranslator.sanitize` calls with `TranslationOutputValidator.sanitize` and leave its retry prompt and generation policy unchanged.

- [ ] **Step 3: Use the same validator in Hy-MT2**

On rejection, return `nil` for non-retryable output. Retry only copied/wrong-language output once with an explicit correction prompt. Never display an unvalidated model response as a translation.

- [ ] **Step 4: Run the focused test suite**

Run the Task 1 command and then:

```bash
swift test -c release -Xswiftc -enable-testing -Xswiftc -DSAIITY_TEST_HOOKS --filter 'LocalModelTests|LanguageTests|HyMT2TranslationTests'
```

Expected: existing Qwen behavior and all Hy-MT2 validation tests pass.

---

### Task 4: Add localized settings and model-page copy

**Files:**
- Modify: `Sources/sAiity/SettingsPages.swift:514-580`
- Modify: `Resources/Localizable.xcstrings`

**Interfaces:**
- Consumes: `TranslationEngine.hyMT2.summary`, `.licence`, and the registry descriptor.
- Produces: an honest third engine choice and model row without changing the default or exposing unsupported quantizations.

- [ ] **Step 1: Add the Hy-MT2 engine picker copy**

Use localized text that states it is a translation specialist for the 37 language codes/variants listed by the model card, that MADLAD remains the broad-coverage choice, and that Hy-MT2 is opt-in. Do not call it faster or better than MADLAD.

- [ ] **Step 2: Ensure the Models page displays one Hy-MT2 asset**

Rely on the registry-driven `ModelsView`; do not add a second hard-coded model row or reuse the Qwen sheet for Hy-MT2.

- [ ] **Step 3: Add English, German, French, Spanish, and Japanese catalog values**

Preserve placeholders and mark model/product names as non-translatable only where appropriate. Run the existing localization tests after editing.

---

### Task 5: Verify compatibility and release readiness boundary

**Files:**
- Modify: `docs/ROADMAP-2.0.md` only if the repository’s existing roadmap has a translation-engine section that needs the new beta status.
- Do not modify: any current dictation file.

- [ ] **Step 1: Run the complete required test suite**

```bash
swift test -c release -Xswiftc -enable-testing -Xswiftc -DSAIITY_TEST_HOOKS
```

Expected: zero test failures.

- [ ] **Step 2: Build the release configuration**

```bash
swift build -c release
```

Expected: exit code 0.

- [ ] **Step 3: Run static hygiene checks**

```bash
git diff --check
git diff --stat -- Sources/sAiity/HyMT2Translator.swift Sources/sAiity/TranslationOutputValidator.swift Sources/sAiity/TranslationEngine.swift Sources/sAiity/EngineLanguages.swift Sources/sAiity/DownloadCoordinator.swift Sources/sAiity/SettingsPages.swift Resources/Localizable.xcstrings Tests/sAiityTests/HyMT2TranslationTests.swift
```

Expected: no whitespace errors and no changes outside the Hy-MT2 scope plus the pre-existing dirty dictation files.

- [ ] **Step 4: Perform a real Q4 model smoke test before claiming support**

Download the exact Q4 file into the app’s model directory through the Models UI, select Hy-MT2, translate one German→English sentence and one English→German sentence, and record whether load, output language, stop behavior, and latency are valid. If the bundled llama framework rejects the file or uses the wrong template, report Hy-MT2 as catalogue-visible but runtime-unverified and do not release it as supported.

- [ ] **Step 5: Inspect the final diff**

Confirm all pre-existing dictation paths remain present and unstaged. Report model-runtime results separately from compile/test results.
