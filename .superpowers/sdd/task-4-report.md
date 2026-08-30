# Task 4 Report

## STATUS

GREEN. Release-only Whisper dictation is wired independently from caption streaming.

## Behavior

- Normal Whisper preparation calls only the readiness/download closure; it does not acquire the caption pool, construct/load WhisperKit, or open the microphone.
- During Whisper dictation, the microphone capture stores only successfully converted mono 16 kHz samples.
- Release stops capture before invoking batch Whisper transcription. The streaming backend's `finishDictation()` is not called on the Whisper path.
- Nemotron and Parakeet continue using the existing `ASRBackendPool` and streaming `finishDictation()` path.
- The batch result enters the existing authoritative cleanup, translation, generation guard, and single insertion pipeline.
- Whisper selection/readiness is separate from caption engine selection and pool state.

## Verification

RED was observed first: the new release-order test failed to compile because the controller had no Whisper boundary. After the minimal implementation, the focused command passed:

```text
swift test -c release -Xswiftc -enable-testing -Xswiftc -DSAIITY_TEST_HOOKS --jobs 2 --filter 'DictationControllerTests|ModelLifecycleTests|StreamingASRBackendTests'
```

Result: 33 tests in 3 suites passed.

`git diff --check` passed before commit.

## Scope

No Task 5/6 UI, toast, accessibility, or localization work was included.
