# Task 4 Report

## STATUS

GREEN. Task 4 最终 integration boundary 修复完成；提交范围 `e78ad5b..HEAD`。

## Behavior

- AppDelegate exposes `prepareSelectedWhisperModelForUse(progress:)` for the deferred Task6 control. It runs the explicit Whisper setup/load lifecycle and only succeeds when required files plus `.saiity-ready` are present.
- Normal controller preparation remains separate from caption streaming and does not open the microphone; the selected Whisper action is the production entry point for Task6.
- During Whisper dictation, the microphone capture stores only successfully converted mono 16 kHz samples and installs the sample-limit handler.
- Release, cancellation and failure explicitly stop capture and drain samples exactly once per session before batch Whisper transcription or error completion; no concrete capture downcast is used.
- Whisper mode and locale are snapshotted at press time, so later selection changes do not affect the active session. Audio format creation is injectable for failure tests.
- Nemotron and Parakeet continue using the existing `ASRBackendPool` and streaming `finishDictation()` path.
- The batch result enters the existing authoritative cleanup, translation, generation guard, and single insertion pipeline.
- Whisper selection/readiness is separate from caption engine selection and pool state.

## Verification

RED was observed first with the new cancellation-during-transcription test:

```text
swift test -c release -Xswiftc -enable-testing -Xswiftc -DSAIITY_TEST_HOOKS --jobs 2 --filter DictationControllerTests
结果：24 个测试中 1 个失败；stopCalls=2，takeCalls=2。
```

最小实现后，五个 focused suites 通过：

```text
swift test -c release -Xswiftc -enable-testing -Xswiftc -DSAIITY_TEST_HOOKS --jobs 2 --filter 'DictationControllerTests|ModelLifecycleTests|WhisperDictationBackendTests|StreamingASRBackendTests|DictationMicrophoneCaptureTests'
```

结果：63 tests in 5 suites passed。

## Task 4 Audit Fix Evidence

- RED: Whisper-selected ordinary preparation called `prepareWhisper`, and an unready Whisper press auto-prepared; the new counter/readiness tests failed before the fix.
- GREEN: ordinary preparation now remains on the streaming backend path; Whisper press requires the injected AppDelegate readiness check and reports a clear Settings preparation failure when unavailable.
- GREEN: converted sample ownership now checks lifecycle and appends under the same lock as limit accounting; delayed old-session handlers remain generation-guarded.
- Focused verification after audit fixes: 67 tests in 5 suites passed with `--jobs 2`.
- Commit: `fix: isolate Whisper preparation and sample ownership`.

## Final Re-review Evidence

- RED: selected-Whisper ordinary preparation and unready shortcut tests failed before isolation; the late-callback ownership regression was also added before the lock-boundary implementation.
- GREEN: ordinary preparation no longer invokes Whisper preparation, unready Whisper shortcut input fails clearly, and controller injection of `prepareWhisper` was removed.
- GREEN: sample ownership checks running state and performs limit accounting plus sample append under one lock; delayed old-session handlers remain generation guarded.
- Focused verification: 67 tests in 5 suites passed with `--jobs 2`; `git diff --check` passed.
- Commit: `test: prove Whisper preparation isolation`.
- Concern: the production AppDelegate method delegates to `WhisperDictationBackend.prepareModelForUse`, whose existing tests exercise the real backend lifecycle and marker cleanup but avoid loading a real WhisperKit model in unit tests; physical/runtime acceptance remains outside this focused run.

## Final Integration Boundary Evidence

- RED: direct AppDelegate delegation and running capture late-callback tests were added before the new seams; the former had no observable production delegation path and the latter could not establish a running lifecycle.
- GREEN: AppDelegate now has a test-only delegation seam whose default is the real `WhisperDictationBackend.prepareModelForUse`; tests verify selected model, progress/error propagation, marker preservation, and unchanged caption engine/readiness/pool lease snapshots.
- GREEN: capture tests enter `running` through `beginForTesting`, then stop/take before a controlled late sample callback; no sample crosses the session boundary.
- Final focused verification: 69 tests in 5 suites passed with `--jobs 2`; `git diff --check` passed.

`git diff --check` passed before commit.

## Scope

No Task6 Settings UI/control was changed; the explicit production action exists for Task6 to call. No Task5 UI, toast, accessibility, or localization work was included.
