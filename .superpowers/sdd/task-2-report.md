# Task 2 Report

## Base / Head / Commit

- Review range: `c63b156..HEAD`
- Implementation commit: this Task 2 fix (`fix: release Whisper lock after cancellation race`)

## Files

- `Sources/sAiity/WhisperDictationBackend.swift`
- `Tests/sAiityTests/WhisperDictationBackendTests.swift`

## Cancellation Race Fix

The FIFO mutex now installs `defer { release() }` immediately after a successful
`acquire`, before the post-acquire cancellation check and operation. Therefore
every post-acquire path releases exactly once, including cancellation after a
waiter continuation has been resumed. Test-only enqueue/acquire barriers make
the A-held, B-queued, B-resumed-then-cancelled, C-follow-up sequence
deterministic without sleeps; the test also proves B does not execute and C
eventually executes.

## Root Cause / Fix RED

The reviewed pre-fix implementation stored heterogeneous operations as `Task<Any, Error>` and force-cast every result back to `T`. The existing review evidence identified the mixed `Void`/`String` operation crash risk. The cancellation review finding was reproduced with a queued B operation: under the old lock, cancelling B still let release wake it and enter the operation. The new RED test failed on that behavior.

```text
swift test -c release -Xswiftc -enable-testing -Xswiftc -DSAIITY_TEST_HOOKS --jobs 2 --filter 'WhisperDictationBackendTests'
```

Result: the new queued-cancellation test reached the runner and failed because the cancelled B operation was not skipped. The initial compile also required correcting a test-only Task value access; no production code was changed before the behavioral RED.

The fix replaces the heterogeneous tail with a concrete FIFO async mutex: one mutex is retained per `root.path:identifier`, with `locked`, UUID-keyed throwing continuations, and FIFO order only. Cancellation removes and resumes exactly one waiter; release skips removed waiters. `run` checks cancellation after acquisition, so a queued cancelled task never executes its operation. Explicit Settings preparation checks cancellation before setup/load and before the final marker, preserving existing final files and marker state while removing only partial state.

## Fix GREEN

Command:

```text
swift test -c release -Xswiftc -enable-testing -Xswiftc -DSAIITY_TEST_HOOKS --jobs 2 --filter 'WhisperDictationBackendTests'
```

Result: exit 0. The focused race test passed.

Final focused command:

```text
swift test -c release -Xswiftc -enable-testing -Xswiftc -DSAIITY_TEST_HOOKS --jobs 2 --filter 'WhisperDictationBackendTests|LanguageTests'
```

Result: exit 0. The real focused command executed 30 tests in 2 suites; all passed. `git diff --check` also passed.

## Concerns

- SwiftPM continues to emit the pre-existing conflicting `swift-syntax` identity warning and existing Sendable-capture warnings.
- Lifecycle tests use concrete injected closures; they verify setup/load/marker order only. Production lifecycle sharing on one backend instance is established by code review, not claimed as injected-test proof.
- No network model download was attempted. A separate documentation-only commit may be made later if needed; this report records the implementation range as `233fb84..HEAD`.
- No Task 3 integration was made; no network model download was attempted.
