# Task 4 Report

## STATUS

GREEN. Task 4 生命周期修复完成，commit `fd37e44`。

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

`git diff --check` passed before commit.

## Scope

No Task6 Settings UI/control was changed; the explicit production action exists for Task6 to call. No Task5 UI, toast, accessibility, or localization work was included.
