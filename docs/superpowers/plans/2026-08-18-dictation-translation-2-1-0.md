# Dictation Translation 2.1.0 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add an opt-in, fully local translation stage to macOS press-to-talk dictation and prepare the feature as sAiity 2.1.0.

**Architecture:** Keep the existing microphone, streaming ASR, translation engine, toast, clipboard, and Accessibility insertion components. Extend `DictationController` with an injected translation configuration provider and async translation handler so it remains testable and does not know about AppDelegate settings. AppDelegate prepares the existing translator on demand for dictation; failed or unavailable translation always falls back to the original dictated text.

**Tech Stack:** Swift 6 / SwiftPM, AppKit, SwiftUI, Swift Testing, existing `Translating` engines, `Resources/Localizable.xcstrings`, Sparkle release scripts.

## Global Constraints

- macOS-only; do not add Windows code or dependencies.
- Translation is opt-in and uses the same target language and local model selected for caption translation.
- The microphone remains open only while the press-to-talk key is held.
- Dictated output is always copied to the clipboard; focused-field insertion remains best effort.
- Translation failure inserts or copies the original transcription and is visible in the toast.
- Dictation remains independent from live captions.
- Every user-facing string gets finished German, French, Spanish, and Japanese localizations.
- Validate with `swift test -c release -Xswiftc -enable-testing -Xswiftc -DSAIITY_TEST_HOOKS`.
- Version identity comes from the annotated `v2.1.0` tag used by the existing release scripts.

---

### Task 1: Add the tested dictation translation seam

**Files:**
- Modify: `Tests/sAiityTests/DictationControllerTests.swift`
- Modify: `Sources/sAiity/DictationState.swift`
- Modify: `Sources/sAiity/DictationController.swift`

**Interfaces:**
- Add `DictationTranslationConfiguration`, a Sendable value containing `enabled` and an optional target language.
- Extend `DictationController` with a main-actor configuration provider and async translation handler; defaults keep translation disabled.
- Add `DictationPhase.translating`.

- [ ] **Step 1: Write failing tests**

Add fake translation configuration and handler tests:

```swift
@Test("enabled dictation translates before inserting and copying")
func translatesBeforeInsertion() async { /* target de; handler returns Hallo; inserter gets Hallo */ }

@Test("translation failure preserves the original dictated text")
func translationFailureFallsBackToOriginal() async { /* handler returns nil; original is inserted */ }

@Test("translation is skipped when dictation translation is disabled")
func disabledTranslationSkipsTranslator() async { /* handler is never called */ }
```

The success test must assert the phase sequence contains `.transcribing`, `.translating`, and `.inserting`. The fallback test must assert the original text is inserted and the final phase reports unavailable translation.

- [ ] **Step 2: Run the focused tests and verify RED**

```bash
swift test -c release -Xswiftc -enable-testing -Xswiftc -DSAIITY_TEST_HOOKS --filter DictationControllerTests
```

Expected: compilation or assertion failure because the new phase and injected translation behavior do not exist.

- [ ] **Step 3: Implement the minimal controller behavior**

In `finish(session:)`, get the backend language before stopping, then after final ASR text is collected:

```swift
let configuration = translationConfiguration()
var output = text
var translationFailed = false
if configuration.enabled, let target = configuration.target, !target.isEmpty {
    phase = .translating
    if let translated = await translate(text, source: sourceLanguage, target: target),
       !translated.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        output = translated.trimmingCharacters(in: .whitespacesAndNewlines)
    } else {
        translationFailed = true
    }
}
phase = .inserting
let result = inserter.insert(output)
```

Use `await backend.detectedLanguage()` with `Locale.current.identifier(.bcp47)` as fallback. Map insertion outcome plus `translationFailed` to explicit localized result messages. Never discard the original transcription.

- [ ] **Step 4: Run the focused tests and verify GREEN**

Run the same focused command; all DictationControllerTests must pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/sAiity/DictationController.swift Sources/sAiity/DictationState.swift Tests/sAiityTests/DictationControllerTests.swift
git commit -m "feat: translate dictated text locally"
```

---

### Task 2: Wire the existing local translator and settings UI

**Files:**
- Modify: `Sources/sAiity/AppDelegate.swift`
- Modify: `Sources/sAiity/SettingsWindow.swift`
- Modify: `Sources/sAiity/SettingsPages.swift`
- Modify: `Resources/Localizable.xcstrings`
- Modify: `Tests/sAiityTests/DictationToastWindowTests.swift` if phase coverage needs extension

**Interfaces:**
- Add `AppState.translateDictation`, persisted and default-off, using the existing dictation setting notification.
- Inject AppDelegate's configuration and translation closures into `DictationController`.
- Generalize translator preparation with an `allowWithoutCaptions` path and source-language argument.
- Display the existing localized `Translating…` string for the new toast phase.

- [ ] **Step 1: Add failing setting, toast, and catalog assertions**

Add phase coverage and source references for the new Dictation setting and result messages before adding catalog entries.

- [ ] **Step 2: Run focused tests and confirm RED**

```bash
swift test -c release -Xswiftc -enable-testing -Xswiftc -DSAIITY_TEST_HOOKS --filter 'Dictation|Localization|Settings'
```

Expected: failure for missing phase/settings/catalog behavior.

- [ ] **Step 3: Implement**

Add a Dictation section toggle labelled `Translate dictated text` with copy explaining that it uses the same target language and local model as captions. If no caption target exists, show an inline instruction to choose one under Captions.

The AppDelegate translation handler must await an in-flight translator swap, prepare the existing `activeTranslator` without requiring caption state to be running, and return nil on missing model, unsupported target, cancellation, or load failure. The controller then inserts the original text and reports the fallback.

Add finished catalog entries for:

- `Translate dictated text`
- `Uses the same target language and local translation model as captions.`
- `Choose a translation target under Captions first.`
- `Translated and inserted`
- `Translated and copied`
- `Translation unavailable — original inserted and copied`
- `Translation unavailable — original copied to Clipboard`

Keep the existing `Translating…` catalog key for the toast and preserve placeholder sets across all shipped languages.

- [ ] **Step 4: Run focused tests and verify GREEN**

```bash
swift test -c release -Xswiftc -enable-testing -Xswiftc -DSAIITY_TEST_HOOKS --filter 'Dictation|Localization|Settings'
```

Expect no missing or unfinished catalog localizations.

- [ ] **Step 5: Commit**

```bash
git add Sources/sAiity/AppDelegate.swift Sources/sAiity/SettingsWindow.swift Sources/sAiity/SettingsPages.swift Resources/Localizable.xcstrings Tests/sAiityTests
git commit -m "feat: add opt-in dictation translation"
```

---

### Task 3: Prepare and verify sAiity 2.1.0

**Files:**
- Modify: `README.md` only if the feature description is stale.
- Create: release artifacts under `build/` through existing scripts; generated binaries are not committed.

- [ ] **Step 1: Run the complete supported test suite**

```bash
swift test -c release -Xswiftc -enable-testing -Xswiftc -DSAIITY_TEST_HOOKS
```

Expected: all tests pass with zero failures.

- [ ] **Step 2: Build and inspect the app bundle**

```bash
./build-app.sh
/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' build/sAiity.app/Contents/Info.plist
```

The version must be `2.1.0` after the annotated tag is created, and the notarized path must compile without test hooks.

- [ ] **Step 3: Create the local version tag after verification**

```bash
git tag -a v2.1.0 -m "sAiity 2.1.0"
```

Do not publish the tag or release assets until explicitly requested. If publication is requested, use `scripts/release.sh 2.1.0` and `scripts/make-dmg.sh 2.1.0`, then verify notarization, checksums, and the public product release separately.

- [ ] **Step 4: Final diff and readiness review**

```bash
git diff --check v2.0.1...HEAD
git status --short --branch
git log --oneline --decorate -8
```

Confirm the feature is opt-in, original-text fallback is covered, microphone lifecycle is unchanged, and no Windows or unrelated public-repository changes entered the diff.
