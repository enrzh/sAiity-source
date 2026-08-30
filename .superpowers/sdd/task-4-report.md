# Task 4 Report

## STATUS

GREEN. Task4 runtime boundaries are enforced; commit pending final verification.

## Behavior

- AppDelegate exposes `prepareSelectedWhisperModelForUse(progress:)` for the deferred Task6 control. It runs the explicit Whisper setup/load lifecycle and only succeeds when required files plus `.saiity-ready` are present.
- Normal controller preparation remains separate from caption streaming and does not open the microphone; the selected Whisper action is the production entry point for Task6.
- During Whisper dictation, the microphone capture stores only successfully converted mono 16 kHz samples.
- Release stops capture, takes samples exactly once through `DictationAudioCapture`, then invokes batch Whisper transcription. Cancellation and failure clear ownership; no concrete capture downcast is used.
- Nemotron and Parakeet continue using the existing `ASRBackendPool` and streaming `finishDictation()` path.
- The batch result enters the existing authoritative cleanup, translation, generation guard, and single insertion pipeline.
- Whisper selection/readiness is separate from caption engine selection and pool state.

## Verification

RED was observed first: the protocol-boundary test failed because the controller downcast fake capture and passed empty samples. After the minimal implementation, the focused command passed:

```text
swift test -c release -Xswiftc -enable-testing -Xswiftc -DSAIITY_TEST_HOOKS --jobs 2 --filter 'DictationControllerTests|ModelLifecycleTests|WhisperDictationBackendTests|StreamingASRBackendTests|DictationMicrophoneCaptureTests'
```

Result: 58 tests in 5 suites passed.

`git diff --check` passed before commit.

## Scope

No Task6 Settings UI/control was changed; the explicit production action exists for Task6 to call. No Task5 UI, toast, accessibility, or localization work was included.
