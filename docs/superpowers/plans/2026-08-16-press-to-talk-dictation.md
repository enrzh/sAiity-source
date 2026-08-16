# Press-to-Talk Dictation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a macOS-only, fully local press-to-talk dictation mode that records from the microphone while Control is held, transcribes on release, cleans the result, and inserts it into the focused text field with the same small animated toast language as the existing app.

**Architecture:** Dictation is a separate pipeline from captions. A CGEvent tap observes Control press/release, a dedicated `AVAudioEngine` microphone capture feeds a newly-created sAiity backend, and a `@MainActor` controller owns the short session from permission request through insertion. A focused status toast reports `Dictating`, `Transcribing`, `Inserted`, `Copied`, and failures; dictation never writes to `TranscriptStore` and never shares a running caption backend.

**Tech Stack:** Swift 6 package in Swift 5 language mode, AppKit, CoreGraphics CGEvent tap, AVFoundation `AVAudioEngine`, existing `TranscriptionBackend`/`ASREngine`, SwiftUI/AppKit overlay styling, Swift Testing.

## Global Constraints

- macOS only; do not extend or modify the Windows overlay spike.
- No cloud transcription, network upload, account, or API key.
- The microphone opens only after the user presses the dictation key and stops immediately after release.
- Holding Control is the default interaction: press begins capture, release ends capture and starts transcription.
- Dictation is not a saved meeting transcript and must not change caption session state.
- The first version rejects dictation while captions are active; it must not own two ASR sessions accidentally.
- Preserve the complete pasteboard and restore it after insertion; never silently discard dictated text.
- Add user-facing strings to `Resources/Localizable.xcstrings` for English, German, French, Spanish, and Japanese.
- Use `swift test -c release -Xswiftc -enable-testing -Xswiftc -DSAIITY_TEST_HOOKS` for verification.
- Verify the real app manually in TextEdit before claiming the feature works.
- Do not copy Ghost Pepper wholesale. Directly reused source fragments require MIT attribution.

---

### Task 1: Add pure dictation state and text assembly

**Files:**
- Create: `Sources/sAiity/DictationState.swift`
- Create: `Tests/sAiityTests/DictationStateTests.swift`

**Interfaces:** `DictationSessionState.begin()`, `.release()`, `.cancel()`; `DictationTextAssembler.append(_:)`, `.reset()`, and `.finalText`; `DictationPhase` with idle, dictating, transcribing, inserting, result, and failure states.

- [ ] **Step 1: Write failing tests**

Test that duplicate presses start only one session, duplicate releases are ignored, final chunks join with one space while empty chunks are ignored, and reset discards partial text.

- [ ] **Step 2: Verify red**

Run `swift test -c release -Xswiftc -enable-testing -Xswiftc -DSAIITY_TEST_HOOKS --filter DictationStateTests`. It must fail because the types do not exist.

- [ ] **Step 3: Implement minimal value types**

Make begin/release transition methods idempotent. Trim each chunk and join non-empty chunks with one space. Do not rewrite model punctuation or casing.

- [ ] **Step 4: Verify green**

Run the filtered command again; all `DictationStateTests` must pass.

- [ ] **Step 5: Commit**

`git add Sources/sAiity/DictationState.swift Tests/sAiityTests/DictationStateTests.swift && git commit -m "feat: add testable dictation state and text assembly"`

### Task 2: Add microphone-only capture

**Files:**
- Create: `Sources/sAiity/DictationMicrophoneCapture.swift`
- Create: `Tests/sAiityTests/DictationMicrophoneCaptureTests.swift`

**Interface:** `DictationMicrophoneCapture.start(targetFormat:onBuffer:) throws`, `.stop()`, and `.isRunning`.

- [ ] **Step 1: Write failing tests**

Test that stopping before starting is safe, starting twice cannot install a second tap, and a zero-rate/zero-channel input reports a user-readable error. Use a small injectable capture factory so these lifecycle rules do not require real hardware.

- [ ] **Step 2: Verify red**

Run `swift test -c release -Xswiftc -enable-testing -Xswiftc -DSAIITY_TEST_HOOKS --filter DictationMicrophoneCaptureTests`; it must fail because the type and seam do not exist.

- [ ] **Step 3: Implement capture**

Use `AVAudioEngine.inputNode`, validate its format before `installTap`, convert to the backend `inputFormat` with `AVAudioConverter`, and deliver converted buffers. On stop, remove the tap first, then stop the engine and release the converter. Do not reference ScreenCaptureKit, `MicMixer`, or `TranscriptStore`.

- [ ] **Step 4: Verify**

Run the focused tests and the complete release test command. Both must exit 0.

- [ ] **Step 5: Commit**

`git add Sources/sAiity/DictationMicrophoneCapture.swift Tests/sAiityTests/DictationMicrophoneCaptureTests.swift && git commit -m "feat: capture microphone audio for dictation"`

### Task 3: Add global press/release monitoring

**Files:**
- Create: `Sources/sAiity/DictationHotkeyMonitor.swift`
- Create: `Tests/sAiityTests/DictationHotkeyMonitorTests.swift`
- Modify: `Resources/Info.plist` only if a confirmed macOS accessibility metadata key is needed; do not invent one.

**Interface:** `@MainActor DictationHotkeyMonitor`, `init(keyCode:)`, `start(onPress:onRelease:) -> Bool`, `stop()`, and `static isControlDown(flags:)`.

- [ ] **Step 1: Write failing tests**

Cover no-Control to Control, Control remaining held, Control release, duplicate releases, and no callbacks after stop.

- [ ] **Step 2: Verify red**

Run `swift test -c release -Xswiftc -enable-testing -Xswiftc -DSAIITY_TEST_HOOKS --filter DictationHotkeyMonitorTests`; it must fail because the monitor does not exist.

- [ ] **Step 3: Implement the tap**

Use a listen-only `CGEventTap` for modifier transitions. Return each original event unchanged, dispatch only Control state transitions to the main actor, tear down if macOS disables the tap, and clear callbacks on stop. Check `AXIsProcessTrusted()` before starting and return false without starting when Accessibility is unavailable.

- [ ] **Step 4: Verify and commit**

Run the focused test and the complete release suite, then commit with `git add Sources/sAiity/DictationHotkeyMonitor.swift Tests/sAiityTests/DictationHotkeyMonitorTests.swift Resources/Info.plist && git commit -m "feat: monitor press-to-talk control transitions"`.

### Task 4: Add pasteboard-preserving insertion

**Files:**
- Create: `Sources/sAiity/TextInsertion.swift`
- Create: `Tests/sAiityTests/TextInsertionTests.swift`

**Interface:** `TextInsertionResult` with `.inserted`/`.copied`, and `@MainActor TextInserter.insert(_:)`/`.copy(_:)`.

- [ ] **Step 1: Write failing tests**

Test a pasteboard with multiple types, preservation after insertion, and copied fallback when Accessibility is unavailable. Use a pasteboard abstraction; do not depend on a real editor in unit tests.

- [ ] **Step 2: Verify red**

Run `swift test -c release -Xswiftc -enable-testing -Xswiftc -DSAIITY_TEST_HOOKS --filter TextInsertionTests`; it must fail because the inserter does not exist.

- [ ] **Step 3: Implement**

Snapshot every pasteboard item and representation, write the dictated text, send Command+V only when trusted, and restore the exact items in `defer`. If writing or Accessibility is unavailable, leave the result copied and return `.copied`; never report `.inserted` without sending the event.

- [ ] **Step 4: Verify and commit**

Run the focused tests and full release suite, then commit with `git add Sources/sAiity/TextInsertion.swift Tests/sAiityTests/TextInsertionTests.swift && git commit -m "feat: preserve clipboard while inserting dictation"`.

### Task 5: Add the controller and compact animated toast

**Files:**
- Create: `Sources/sAiity/DictationController.swift`
- Create: `Sources/sAiity/DictationToast.swift` only if the existing overlay cannot express this without changing caption behavior.
- Create: `Tests/sAiityTests/DictationControllerTests.swift`
- Modify: `Sources/sAiity/AppDelegate.swift`

**Interface:** `@MainActor DictationController.press()`, `.release()`, `.cancel()`, `.phase`, and `.isActive`.

- [ ] **Step 1: Write failing controller tests**

With test doubles, cover one session per press, release stopping capture before backend flush, empty text not pasting, cancellation tearing down both resources, caption-active rejection, and backend failure releasing the microphone.

- [ ] **Step 2: Verify red**

Run `swift test -c release -Xswiftc -enable-testing -Xswiftc -DSAIITY_TEST_HOOKS --filter DictationControllerTests`; it must fail because the controller does not exist.

- [ ] **Step 3: Implement serialized orchestration**

On press, reject if captions are active, create and prepare `ASREngine.effective.makeBackend()`, read `inputFormat`, start the backend callback, then start microphone capture. On release, stop capture synchronously before awaiting backend stop/flush, collect final chunks, clear references, and insert/copy the cleaned result. Guard async continuations with a session generation so an old release cannot update a newer press. Never write to `TranscriptStore`.

- [ ] **Step 4: Implement the toast**

Use the existing app material, typography, corner radius, and animation primitives. Show a small stable-width capsule with microphone/waveform symbol and one short localized label. Animate state changes only: appear on press, subtle live waveform/progress while dictating, replace with `Transcribing…`, then show `Inserted` or `Copied` briefly and disappear. No decorative gradient, continuous background fade, or second large panel. Keep it separate from the caption bubble.

- [ ] **Step 5: Verify and commit**

Run the focused tests and full release suite, then commit with `git add Sources/sAiity/DictationController.swift Sources/sAiity/DictationToast.swift Sources/sAiity/AppDelegate.swift Tests/sAiityTests/DictationControllerTests.swift && git commit -m "feat: add local press-to-talk dictation"`.

### Task 6: Integrate lifecycle, menu, permissions, and localization

**Files:**
- Modify: `Sources/sAiity/AppDelegate.swift`
- Modify: `Sources/sAiity/SettingsPages.swift` only if the existing shortcut/settings area is the correct home.
- Modify: `Resources/Localizable.xcstrings`
- Modify: `README.md`
- Modify: `Resources/Info.plist` only for confirmed permission metadata.

- [ ] **Step 1: Add failing localization/integration tests**

Assert every new key exists with placeholder parity and English, German, French, Spanish, and Japanese values. Assert monitor stop clears active dictation state.

- [ ] **Step 2: Verify red**

Run the relevant localization and dictation filters; they must fail on the missing keys before integration is added.

- [ ] **Step 3: Integrate lifecycle**

Instantiate one controller, register monitor callbacks in `applicationDidFinishLaunching`, stop the monitor and cancel the controller at termination, and route phase changes through the existing status mechanism. Do not use `HotKeyCenter`: its Carbon API is press-only and cannot represent release.

- [ ] **Step 4: Add concise localized copy**

Add only the strings actually shown: `Hold Control to Dictate`, `Dictating…`, `Transcribing…`, `Inserted`, `Copied to Clipboard`, `No speech detected`, `Accessibility permission is needed to dictate into other apps`, `Open Accessibility Settings`, and microphone failure text. Preserve all placeholders exactly.

- [ ] **Step 5: Verify and commit**

Run the localization filter and complete release suite, then commit with `git add Sources/sAiity/AppDelegate.swift Sources/sAiity/SettingsPages.swift Resources/Localizable.xcstrings README.md Resources/Info.plist && git commit -m "feat: expose press-to-talk dictation in the app"`.

### Task 7: Build and verify the real app

**Files:** Modify only files implicated by a reproduced failure; add a regression test before fixing it.

- [ ] **Step 1: Build and lint the tree**

Run `swift build -c release && git diff --check`. Expected: exit 0 and no diff-check errors.

- [ ] **Step 2: Test in TextEdit**

Verify: idle sAiity does not request mic permission; Control press starts permission and the toast; release produces `Transcribing…` then inserts text; clipboard content and representations are restored; Accessibility denial leaves text copied; rapid press/release never leaves the mic active; captions reject dictation; stopping/quit during dictation removes the input tap; silence produces no empty paste.

- [ ] **Step 3: Re-run the complete verification**

Run `swift test -c release -Xswiftc -enable-testing -Xswiftc -DSAIITY_TEST_HOOKS && swift build -c release && git diff --check && git status --short`. Only after fresh output confirms all commands succeed may the feature be called ready.

- [ ] **Step 4: Commit verified hardening**

`git add Sources Tests Resources README.md && git commit -m "test: harden press-to-talk dictation teardown"`

## Self-Review

This plan covers microphone gating, key-up handling, local ASR, conservative text cleaning, clipboard preservation, compact toast animation, lifecycle teardown, localization, tests, and real-app verification. It intentionally excludes Windows, saved transcript storage, simultaneous caption/dictation, and configurable shortcuts from the first implementation. No direct Ghost Pepper source reuse is assumed; MIT attribution is required if that changes.

