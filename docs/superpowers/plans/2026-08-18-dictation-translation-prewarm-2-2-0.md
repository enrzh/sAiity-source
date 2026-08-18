# Dictation Translation and Startup Feedback Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship sAiity 2.2.0 with an independent dictation translation target, scoped menu controls, truthful dictation readiness feedback, and reusable ASR prewarming without opening the microphone before a press.

**Architecture:** Keep one `AppState` preference for captions and add one persisted dictation target with a one-time migration from the captions target. Generalize the existing language picker and menu builder to accept a target binding/value, so captions and dictation share the catalog and support checks while remaining independent. Extend `DictationController` with a single-flight prepared backend and explicit `preparing`, `ready`, and `starting` phases; retain the backend between short sessions and release it through the existing model lifecycle before deletion.

**Tech Stack:** Swift 6 / Swift Package Manager, AppKit, SwiftUI, AVFoundation, existing `TranscriptionBackend` implementations, Swift Testing, Apple String Catalog localization, existing `build-app.sh`, `scripts/make-dmg.sh`, and `scripts/release.sh`.

## Global Constraints

- Work in `/Users/enrico/Documents/GitHub/saiity` on `main`; re-read overlapping files immediately before each edit because other sessions may touch this checkout.
- Preserve the supported release test command: `swift test -c release -Xswiftc -enable-testing -Xswiftc -DSAIITY_TEST_HOOKS`.
- Dictation translation is opt-in and remains lazy; opening Settings or warming ASR must not load the translation model.
- The first dictation-target initialization copies the current captions target exactly once, including `nil`; later captions changes never mutate the dictation target.
- Prewarming may download and load ASR, but must never instantiate `AVAudioEngine.inputNode`, install a tap, request microphone access, or start microphone capture.
- A prepared backend is single-flight and may be reused across presses only after its prior session has been stopped and flushed.
- A prepared backend must be invalidated before recognition engine/tier changes, dictation disablement, cancellation teardown, and model deletion.
- Do not claim visual behavior from source inspection; launch the built app and inspect screenshots before release claims.
- Keep all user-visible strings in `Resources/Localizable.xcstrings`; preserve placeholder multisets for every locale.
- No Windows work, new translation engine, or unrelated refactor is part of 2.2.0.

## Files and Responsibilities

- `Sources/sAiity/DictationState.swift`: phase cases and a small testable preference-migration helper for the independent dictation target.
- `Sources/sAiity/SettingsWindow.swift`: persisted `dictationTranslateTo`, one-time initialization, notification, and dictation-specific recent-target source.
- `Sources/sAiity/SettingsPages.swift`: Dictation translation toggle plus disabled/enabled independent language control and explanatory copy.
- `Sources/sAiity/TranslationTargetPicker.swift`: target binding and scoped title/copy; one catalog and one support query for both settings surfaces.
- `Sources/sAiity/AppDelegate.swift`: dictation configuration source, ASR preparation/invalidation wiring, two scoped menu subtrees, picker routing, and release-before-delete ordering.
- `Sources/sAiity/DictationController.swift`: preparation task, cached backend, phase transitions, reuse, cancellation, and explicit invalidation API.
- `Tests/sAiityTests/SettingsWindowTests.swift`: migration and independent persistence tests.
- `Tests/sAiityTests/DictationControllerTests.swift`: preparation, reuse, pre-readiness press, invalidation, and microphone lifecycle tests.
- `Tests/sAiityTests/DictationToastWindowTests.swift`: phase-to-toast behavior for preparing, ready, and starting states.
- `Resources/Localizable.xcstrings`: new English strings and translated German/French/Spanish/Japanese values with matching placeholders.
- `README.md` and release notes/appcast inputs only if the existing release workflow requires a 2.2.0 user-facing entry; do not invent release claims before build evidence exists.

## Implementation Tasks

### Task 1: Add the one-time dictation target migration

- [ ] **Step 1: Write failing persistence tests.** In `Tests/sAiityTests/SettingsWindowTests.swift`, add tests using a snapshot/restoration helper for `translateTo`, `dictationTranslateTo`, and a boolean migration key:

```swift
@Test("first dictation target initialization inherits captions once, including Off")
func dictationTargetMigratesOnce() {
    let defaults = UserDefaults.standard
    let keys = ["translateTo", "dictationTranslateTo", "dictationTranslateToMigrated"]
    let snapshot = keys.map { ($0, defaults.object(forKey: $0)) }
    defer { snapshot.forEach { key, value in
        if let value { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) }
    } }

    defaults.set("de", forKey: "translateTo")
    defaults.removeObject(forKey: "dictationTranslateTo")
    defaults.removeObject(forKey: "dictationTranslateToMigrated")
    let inherited = AppState()
    #expect(inherited.dictationTranslateTo == "de")
    #expect(defaults.bool(forKey: "dictationTranslateToMigrated"))

    inherited.dictationTranslateTo = "fr"
    inherited.translateTo = "ja"
    let independent = AppState()
    #expect(independent.dictationTranslateTo == "fr")
    #expect(independent.translateTo == "ja")

    defaults.removeObject(forKey: "dictationTranslateTo")
    defaults.removeObject(forKey: "dictationTranslateToMigrated")
    defaults.removeObject(forKey: "translateTo")
    let off = AppState()
    #expect(off.dictationTranslateTo == nil)
    #expect(defaults.bool(forKey: "dictationTranslateToMigrated"))
}
```

- [ ] **Step 2: Run the focused test and verify the expected failure.** Run:

```bash
swift test -c release -Xswiftc -enable-testing -Xswiftc -DSAIITY_TEST_HOOKS --filter SettingsWindowTests/dictationTargetMigratesOnce
```

It must fail because `AppState` has no independent dictation target or migration yet.

- [ ] **Step 3: Implement the smallest preference helper.** In `Sources/sAiity/DictationState.swift`, add one helper that receives `UserDefaults`, copies `translateTo` to `dictationTranslateTo` only when `dictationTranslateToMigrated` is false, removes the destination when the inherited value is `nil`, then writes the marker. Keep the keys in this helper so migration logic has one source of truth:

```swift
enum DictationTargetPreference {
    static let targetKey = "dictationTranslateTo"
    static let migratedKey = "dictationTranslateToMigrated"

    static func load(from defaults: UserDefaults = .standard) -> String? {
        if !defaults.bool(forKey: migratedKey) {
            if let inherited = defaults.string(forKey: "translateTo") {
                defaults.set(inherited, forKey: targetKey)
            } else {
                defaults.removeObject(forKey: targetKey)
            }
            defaults.set(true, forKey: migratedKey)
        }
        return defaults.string(forKey: targetKey)
    }

    static func save(_ value: String?, to defaults: UserDefaults = .standard) {
        if let value { defaults.set(value, forKey: targetKey) }
        else { defaults.removeObject(forKey: targetKey) }
    }
}
```

- [ ] **Step 4: Add the independent observable property.** In `Sources/sAiity/SettingsWindow.swift`, initialize `dictationTranslateTo` from `DictationTargetPreference.load()`, persist changes through `save`, and post `.saiityDictationSettingChanged`. Add a separate `recentDictationTargetsForMenu` property based on `dictationTranslateTo` and `recentDictationTranslateTargets`; do not reuse the captions recent-target key.

- [ ] **Step 5: Run the focused tests and the existing dictation persistence test.** Confirm both pass, then commit:

```bash
swift test -c release -Xswiftc -enable-testing -Xswiftc -DSAIITY_TEST_HOOKS --filter SettingsWindowTests
git add Sources/sAiity/DictationState.swift Sources/sAiity/SettingsWindow.swift Tests/sAiityTests/SettingsWindowTests.swift
git commit -m "feat: persist an independent dictation translation target"
```

### Task 2: Generalize the language picker and Dictation settings page

- [ ] **Step 1: Add a failing binding test at the state boundary.** Extend the settings tests so setting `dictationTranslateTo` does not alter `translateTo`, and make the planned `TranslationTargetPicker` initializer compile only after the binding change is implemented.

- [ ] **Step 2: Generalize the picker without duplicating its catalog.** In `Sources/sAiity/TranslationTargetPicker.swift`, replace direct writes/read checks of `state.translateTo` with an injected `@Binding var target: String?`, and add a `LocalizedStringKey` title/subtitle pair. Preserve the single `LanguageCatalog.all` list, one engine support query, the Off button, searchable list, and `AlternativeEngines`; when an alternate engine is selected, update the injected target rather than the captions property.

Use call sites with explicit scope:

```swift
TranslationTargetPicker(state: state,
                        target: $state.translateTo,
                        title: "Translate captions to",
                        subtitle: "Using \(engine.displayName)")
TranslationTargetPicker(state: state,
                        target: $state.dictationTranslateTo,
                        title: "Translate dictation to",
                        subtitle: "Dictation uses its own target")
```

The initializer may derive the subtitle from the selected engine, but it must not use the captions target to render the dictation sheet.

- [ ] **Step 3: Add the independent Dictation language control.** In the Dictation section of `Sources/sAiity/SettingsPages.swift`, keep `Toggle("Translate dictated text", isOn: $state.translateDictation)` and add a `LabeledContent("Language")` button immediately below it. The button displays the independent target or `Off`, is disabled while the toggle is off, and sets a new `showDictationTranslationPicker` state flag. The explanatory text must say that the target is independent from captions after initial setup.

- [ ] **Step 4: Add the dictation picker sheet and test it from the settings test hook.** Keep the captions sheet bound to `showTranslationPicker`; add a separate sheet bound to `showDictationTranslationPicker` with `$state.dictationTranslateTo`. Run the settings tests and the supported release test command.

- [ ] **Step 5: Commit the settings surface.**

```bash
git add Sources/sAiity/TranslationTargetPicker.swift Sources/sAiity/SettingsPages.swift Sources/sAiity/SettingsWindow.swift Tests/sAiityTests/SettingsWindowTests.swift
git commit -m "feat: add independent dictation translation settings"
```

### Task 3: Add explicit ASR preparation and reuse to the controller

- [ ] **Step 1: Extend the fake backend and add failing lifecycle tests.** In `Tests/sAiityTests/DictationControllerTests.swift`, make `FakeBackend` count `prepare` calls, expose a preparation gate/continuation, and add tests for:

```swift
@Test("preparation emits preparing then ready without opening the microphone")
func preparationProducesTruthfulReadyState() async { /* assert prepare == 1, capture.started == false, phases == [.preparing, .ready] */ }

@Test("two presses reuse one prepared backend")
func preparedBackendIsReused() async { /* prepare == 1, starts == 2, stops == 2 */ }

@Test("a press before readiness waits and starts only after preparation")
func earlyPressWaitsForPreparation() async { /* phases include .starting; capture remains stopped until the gate opens */ }

@Test("invalidating preparation releases the cached backend")
func invalidationAllowsFreshPreparation() async { /* invalidate; next prepare creates a fresh backend */ }
```

Use real `DictationController` calls and the existing fake capture; do not make the test assert private implementation details beyond call counts and observable phases.

- [ ] **Step 2: Verify the lifecycle tests fail for the missing API.** Run the focused controller suite and confirm the failures identify missing preparation/invalidation behavior rather than test setup errors.

- [ ] **Step 3: Add phases and the single-flight preparation state.** In `Sources/sAiity/DictationState.swift`, add `.preparing` and `.starting` between input-monitoring and ready/dictating. Keep `.preparing` and `.starting` non-auto-dismissing. In `Sources/sAiity/DictationController.swift`, add:

```swift
private var preparationTask: Task<TranscriptionBackend, Error>?
private var preparedBackend: TranscriptionBackend?
private var preparedFormat: AVAudioFormat?

func prepare() {
    guard preparationTask == nil, preparedBackend == nil else { return }
    phase = .preparing
    preparationTask = Task { @MainActor [weak self] in
        guard let self else { throw CancellationError() }
        let backend = self.makeBackend()
        try await backend.prepare(locale: Locale.current) { _ in }
        guard let format = await backend.inputFormat else { throw BackendError.notPrepared }
        try Task.checkCancellation()
        return (backend, format)
    }
    // Install the result only if this preparation is still current; on success
    // set .ready, on cancellation return to .idle, and on error clear the cache
    // and surface .failure without opening DictationMicrophoneCapture.
}

func invalidatePreparedBackend() {
    generation += 1
    preparationTask?.cancel()
    preparationTask = nil
    let old = preparedBackend
    preparedBackend = nil
    preparedFormat = nil
    Task { await old?.stop() }
    if !state.isActive { phase = .idle }
}
```

The concrete implementation may use a private result tuple/helper to keep `preparedFormat` and the backend installed atomically. Only one task may own preparation, and a cancelled/superseded task must never install its backend.

- [ ] **Step 4: Change press/start/release to use the prepared backend.** `press()` must set `.starting`, obtain the same preparation task if preparation is active, then call `backend.start`, verify `inputFormat`, and only after `capture.start` succeeds set `.dictating`. `release()` waits for startup and then flushes/stops only the active session; it must leave `preparedBackend` cached for the next press. Reset the collector and per-session callback at every press. A release before capture starts must not open the microphone.

- [ ] **Step 5: Update cancellation and test hooks.** `cancel()` must stop capture, cancel startup/release/preparation tasks, stop and clear both active and prepared backends, and never let a stale task install a backend. `waitForWorkForTests()` must await preparation as well as startup/release/cleanup.

- [ ] **Step 6: Run the focused controller and toast tests.** Confirm the new phase sequence, one prepare call across two presses, no microphone during prewarm, and cleanup behavior. Commit:

```bash
swift test -c release -Xswiftc -enable-testing -Xswiftc -DSAIITY_TEST_HOOKS --filter DictationControllerTests
swift test -c release -Xswiftc -enable-testing -Xswiftc -DSAIITY_TEST_HOOKS --filter DictationToastWindowTests
git add Sources/sAiity/DictationState.swift Sources/sAiity/DictationController.swift Tests/sAiityTests/DictationControllerTests.swift Tests/sAiityTests/DictationToastWindowTests.swift
git commit -m "feat: prewarm and reuse the dictation ASR backend"
```

### Task 4: Wire preparation, truthful toasts, and invalidation in AppDelegate

- [ ] **Step 1: Change the dictation configuration source.** In `Sources/sAiity/AppDelegate.swift`, return `settings.dictationTranslateTo` from `dictationTranslationConfiguration()`. In `translateDictatedText`, wait for the translator swap but compare against the dictation target/configuration, not the captions target; captions target changes must not cancel or redirect dictation translation.

- [ ] **Step 2: Start preparation after the shortcut is registered.** Replace `dictationController.markReady()` in `startDictationHotkey()` with `dictationController.prepare()`. Keep Input Monitoring failure as `.waitingForInputMonitoring`. Repeated retry calls must not start a second preparation task.

- [ ] **Step 3: Map all new phases to visible toast copy.** In `updateDictationToast(_:)`, add localized messages:

```swift
case .preparing:
    dictationToast.show(text: String(localized: "Preparing Dictation…"), animated: true)
case .ready:
    let chord = SettingsWindowController.state.dictationChord.displayString
    dictationToast.show(text: String(localized: "Ready to Dictate · Hold \(chord)"),
                        animated: false, autoDismissAfter: .seconds(4.5))
case .starting:
    dictationToast.show(text: String(localized: "Starting Dictation…"), animated: true)
case .dictating:
    dictationToast.show(text: String(localized: "Dictating…"), animated: true)
```

The ready state is emitted only by completed ASR preparation/input-format resolution; it is not set when the monitor merely registers.

- [ ] **Step 4: Invalidate on disable, engine/tier changes, and model deletion.** On `.saiityDictationSettingChanged` disablement, call `invalidatePreparedBackend()` before stopping the monitor and dismissing the toast. In `engineChanged(to:)`, invalidate before any selection swap. In `releaseModels()`, invalidate and await the controller’s release before deleting/rebuilding caption models. Ensure application termination uses the same invalidation path.

- [ ] **Step 5: Add a regression assertion for target independence.** Extend `DictationControllerTests` or an AppDelegate-facing test seam so the configuration passed into translation can be changed independently from the captions target; the controller must receive only the dictation target.

- [ ] **Step 6: Run focused app/controller tests and commit.**

```bash
swift test -c release -Xswiftc -enable-testing -Xswiftc -DSAIITY_TEST_HOOKS --filter 'Dictation|SettingsWindow|DictationToast'
git add Sources/sAiity/AppDelegate.swift Tests/sAiityTests/DictationControllerTests.swift
git commit -m "feat: show truthful dictation readiness and isolate lifecycle"
```

### Task 5: Split the status-item translation menu by scope

- [ ] **Step 1: Add failing menu behavior tests or a pure helper test.** Extract the menu data calculation into a small value-oriented helper in `AppDelegate.swift` or `DictationState.swift` that accepts `scope`, `currentTarget`, `recentTargets`, and preferred languages. Test that captions and dictation produce separate labels, selected states, Off entries, and recent lists.

- [ ] **Step 2: Generalize menu item construction.** Replace `translationMenuItem()` with `translationMenuItem(title:target:recentTargets:scope:)`. Each language item carries a represented object containing the scope and code, for example:

```swift
struct TranslationMenuSelection: Equatable {
    enum Scope { case captions, dictation }
    let scope: Scope
    let code: String?
}
```

Use the same language catalog/recent/preferred-language helper for both menus. The visible submenus must be titled exactly `Captions: Translate to` and `Dictation: Translate to`.

- [ ] **Step 3: Route selection to the correct preference.** In `pickTranslation(_:)`, decode `TranslationMenuSelection`; captions selections keep posting `.saiityTranslateTargetChanged` and remembering `recentTranslateTargets`, while dictation selections update `SettingsWindowController.state.dictationTranslateTo` and remember `recentDictationTranslateTargets`. An Off selection must persist `nil` in the chosen scope.

- [ ] **Step 4: Route “All languages…” to the correct picker.** Encode the scope on the action item or use separate selectors. `showLanguagePicker` must open the captions picker; `showDictationLanguagePicker` must open the dictation picker. Add the two state booleans if the sheets cannot be selected by one scoped enum.

- [ ] **Step 5: Rebuild the menu on both target changes and run AppKit-capable tests.** Ensure the existing menu retains only captions/dictation controls, Settings, updates, and Quit. Commit:

```bash
swift test -c release -Xswiftc -enable-testing -Xswiftc -DSAIITY_TEST_HOOKS --filter SettingsWindowTests
git add Sources/sAiity/AppDelegate.swift Sources/sAiity/SettingsWindow.swift Tests/sAiityTests
git commit -m "feat: split captions and dictation translation menus"
```

### Task 6: Update the localization catalog

- [ ] **Step 1: Add every new literal to the English catalog.** Include the Dictation language label/copy, independent-target explanation, scoped menu titles, and `Preparing Dictation…` / `Starting Dictation…`. Keep placeholder tokens identical to source strings, including the `%@` chord in `Ready to Dictate · Hold %@`.

- [ ] **Step 2: Translate the added units.** Add German, French, Spanish, and Japanese values using the existing catalog terminology. Do not translate product/model names, key glyphs, URLs, or model identifiers. Keep the source sample subtitle behavior unchanged.

- [ ] **Step 3: Run localization tests and source/catalog audit.**

```bash
swift test -c release -Xswiftc -enable-testing -Xswiftc -DSAIITY_TEST_HOOKS --filter LocalizationTests
```

Resolve every missing key, stale key, or placeholder mismatch before continuing.

### Task 7: Full verification and visual release candidate

- [ ] **Step 1: Re-read the approved spec and inspect the complete diff.** Check that every requirement maps to code/tests and that no unrelated files or generated secrets entered the diff.

- [ ] **Step 2: Run the full supported release suite.**

```bash
swift test -c release -Xswiftc -enable-testing -Xswiftc -DSAIITY_TEST_HOOKS
```

Record the actual test count and exit status; do not rely on earlier background task output.

- [ ] **Step 3: Build the release app.** Run `./build-app.sh` with the repository’s supported release arguments after reading the script, and verify the produced `.app` exists and embeds the new version/build metadata.

- [ ] **Step 4: Launch the app through its test hooks and inspect screenshots.** Verify all of the following in the running app:
  - Dictation settings show a separate translation toggle and language control.
  - The dictation language control is disabled when translation is off and does not change when the Captions target changes.
  - The status item contains separate Captions and Dictation translation submenus with correct checkmarks.
  - The toast visibly shows Preparing, Ready, and Starting states above the frontmost app.
  - Preparing does not trigger a microphone permission prompt or active microphone capture.

- [ ] **Step 5: Run the release scripts only after visual and test verification.** Inspect `scripts/make-dmg.sh` and `scripts/release.sh`, then prepare the 2.2.0 notarized artifacts. Verify the actual served bytes/appcast and release metadata before publishing.

### Task 8: Commit and publish v2.2.0

- [ ] **Step 1: Run a final status/diff/secret check.** Confirm the intended files only, no untracked credentials, and no uncommitted generated build artifacts that belong outside the repository.

- [ ] **Step 2: Create the production commit.** Use a focused message such as:

```bash
git add Sources Tests Resources docs README.md
git commit -m "feat: improve dictation translation and startup readiness"
```

- [ ] **Step 3: Push and tag only after the full suite and build are fresh.** Verify `git remote -v`, push `main`, create annotated tag `v2.2.0`, and push the tag. Do not force-push.

- [ ] **Step 4: Notarize and publish the macOS artifacts.** Run the existing release path for `2.2.0`, confirm notarization/stapling, upload the DMG/appcast through the existing script, and verify the public download URL returns the expected bytes and signature.

- [ ] **Step 5: Report exact evidence.** Include the release commit/tag, test command/result, artifact names and hashes, notarization result, appcast verification, and any external publishing step that could not be verified locally. Do not claim a public release or X post without direct evidence.

## Plan Self-Review

- Independent target migration, including inherited Off, is covered by Task 1.
- Settings selector and one shared language catalog are covered by Task 2.
- Preparing/ready/starting phases, single-flight preparation, reuse, early press, and invalidation are covered by Tasks 3 and 4.
- Captions/dictation menu split and scoped picker routing are covered by Task 5.
- Translator laziness and original-text fallback remain explicit in the global constraints and Task 4.
- Localization, full tests, visual verification, notarization, appcast, and release evidence are covered by Tasks 6–8.
- No unspecified implementation placeholder is required to execute the plan; each task names its files, behavior, tests, and command.
