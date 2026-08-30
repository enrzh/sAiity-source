# Final Verification

## Root cause

`WhisperDictationBackendTests` used `nonisolated(unsafe)` static test hooks on
`FIFOAsyncMutex`. Swift Testing can execute suites concurrently, so another
test instance could overwrite or clear those hooks while the unstructured
enqueue callback was still scheduled. The production mutex cancellation path
was not the cause; the failure was test-global timing/interference.

## Change

Marked `WhisperDictationBackendTests` as `@Suite(.serialized)`, keeping the
production mutex unchanged and making the hook-driven synchronization
deterministic.

## Verification

- Target test, serial repeated 20 times: pass, 20/20.
- Whisper suite: pass, 21/21.
- Related concurrent filter: pass, 66/66.
- Full suite: pass, 242/242.

Commands:

```sh
swift test -c release --skip-build --no-parallel --maximum-repetitions 20 --filter 'WhisperDictationBackendTests.cancellationAfterWaiterResumeReleasesMutex'
swift test -c release --skip-build --no-parallel --filter 'WhisperDictationBackendTests'
swift test -c release --skip-build --no-parallel --filter 'WhisperDictationBackendTests|DictationControllerTests|StreamingASRBackendTests|ModelLifecycleTests'
swift test -c release --skip-build --no-parallel
```

No push or release performed.
