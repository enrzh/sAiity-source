# Task 6 Report

Implemented the scoped dictation settings and localization contract, including the review runtime wiring.

## Changes

- Added persisted, default-off dictation cleanup state independent from captions.
- Added an independent dictation streaming recognizer selection.
- The picker now drives `DictationRecognizer.selected`; Whisper selection mirrors `WhisperDictationBackend.isSelected`, while streaming uses a separate backend pool and engine preference.
- Added Whisper Base/Small, locale coverage from `LanguageCatalog.all`, readiness, Download/Retry/Remove, and Models recovery navigation.
- Download and retry use `AppDelegate.prepareSelectedWhisperModelForUse`; captions remain on their existing selection.
- Whisper removal invalidates the prepared dictation backend before deleting files and refreshes readiness afterward.
- The test target enables `SAIITY_TEST_HOOKS`, matching the focused test command.
- Added the exact 23 Task6 catalog keys with complete `de`, `fr`, `es`, and `ja` entries.
- Added RED tests for settings persistence, locale/model scope, readiness, and localization coverage.
- Review fix: replaced the inert recognizer preference with `DictationRecognizer.selected`, wired to a separate dictation streaming pool and Whisper `isSelected` state.
- Review fix: preparation errors propagate to the settings UI; removal invalidates `DictationController` before deleting Whisper files.
- Final review fix: preparation accepts an explicit captured `ModelChoice`, so a later model picker change cannot redirect the in-flight action.
- Task6 fresh fixer: extracted the existing Dictation settings actions as internal static functions with closure injection; Buttons call the same functions used by tests. Removal invalidates before deleting the captured choice, and download/retry/remove refresh readiness and surface errors.
- Reused localized `Engine` for the recognizer picker and added the missing localized `Automatic` key in `de`, `fr`, `es`, and `ja`.

## Verification

- RED: the review-fix run caught and corrected one stale readiness assertion.
- GREEN: `swift test -c release --jobs 2 -Xswiftc -enable-testing -Xswiftc -DSAIITY_TEST_HOOKS --filter 'SettingsWindowTests|LocalizationTests|ModelLifecycleTests|DictationControllerTests|StreamingASRBackendTests'` passed: 59 tests in 5 suites.
- GREEN smoke: the same flags with `--filter 'SettingsWindowTests|LocalizationTests'` passed: 14 tests in 2 suites.
- GREEN: `swift build -c release --jobs 2` passed.
- Catalog JSON validation passed; all 23 keys are present in all four shipped locales.
- `git diff --check` passed.

## Fresh fixer action contract tests

- `downloadActionUsesCapturedModelAndRefreshesReadiness`: passed
- `downloadFailureSetsModelErrorAndRefreshesState`: passed
- `retryClearsFailureThenUsesCapturedModel`: passed
- `removeInvalidatesBeforeDeletingAndRefreshesReadiness`: passed
- `permissionRecoveryOpensInputMonitoringSettings`: passed
- `notReadyActionSelectsExistingModelsPane`: passed

Focused run: `swift test -c release --jobs 2 -Xswiftc -enable-testing -Xswiftc -DSAIITY_TEST_HOOKS --filter 'SettingsWindowTests|LocalizationTests|ModelLifecycleTests'` — 35 tests in 3 suites passed.

No push or release was performed.
