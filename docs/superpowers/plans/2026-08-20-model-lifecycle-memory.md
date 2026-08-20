# Model Lifecycle Memory Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Keep one resident ASR model shared by captions and push-to-talk dictation, evict the translation model after a short idle grace period, and measure the resulting memory and startup trade-offs.

**Architecture:** A main-actor `ASRBackendPool` owns the only cached ASR backend. Captions and dictation ask it to prepare, acquire, and return the backend; a return keeps the model warm briefly, while invalidation releases it. `DictationController` no longer retains a prepared backend between presses, so the pool can actually evict it. A small main-actor idle eviction helper gives the translator the same delayed-release behavior without unloading during active work.

**Tech Stack:** Swift 6, Swift Testing, AVFoundation, existing `TranscriptionBackend` protocol, existing MLX/MADLAD memory policy.

## Global Constraints

- Keep captions and dictation mutually exclusive at runtime; a second ASR lease must fail clearly rather than loading a second model.
- Keep the existing rolling caption commit behavior and authoritative dictation completion behavior unchanged.
- Keep model downloads and translation fully on-device; do not add a dependency.
- Release model resources immediately when Settings deletes model files or the system reports critical memory pressure and the model is idle.
- Use `phys_footprint`/Activity Monitor-style physical footprint for memory measurements; RSS is not an acceptable proxy for this app.
- Preserve the required release test command: `swift test -c release -Xswiftc -enable-testing -Xswiftc -DSAIITY_TEST_HOOKS`.

---

### Task 1: Add lifecycle regression tests

**Files:**
- Create: `Tests/sAiityTests/ModelLifecycleTests.swift`
- Modify: `Tests/sAiityTests/DictationControllerTests.swift`

**Interfaces:**
- Tests consume the new `ASRBackendProvider` contract and `ASRBackendPool` behavior.
- Tests produce executable proof that a warm dictation preparation is reused by captions, that a second active consumer is rejected, and that idle eviction releases the backend.

- [x] **Step 1: Write the failing pool tests**

Add a `FakeLifecycleBackend` implementing `TranscriptionBackend` with counters for `prepares`, `starts`, `stops`, and `releases`, plus a stable 16 kHz format. Add these tests:

```swift
@MainActor
@Suite struct ModelLifecycleTests {
    @Test("captions reuse a backend prewarmed for dictation")
    func warmBackendIsShared() async throws {
        var created = 0
        let backend = FakeLifecycleBackend()
        let pool = ASRBackendPool(
            makeBackend: {
                created += 1
                return backend
            },
            idleEvictionDelay: .seconds(5))

        try await pool.prepare(locale: Locale(identifier: "en-US")) { _ in }
        let captionBackend = try await pool.acquire(locale: Locale(identifier: "en-US")) { _ in }
        await pool.release(captionBackend, discard: false)

        #expect(created == 1)
        #expect(backend.prepares == 1)
        #expect(backend.releases == 0)
    }

    @Test("a second ASR consumer cannot acquire while the first is active")
    func activeLeaseIsExclusive() async throws {
        let pool = ASRBackendPool(makeBackend: { FakeLifecycleBackend() },
                                  idleEvictionDelay: .seconds(5))
        let first = try await pool.acquire(locale: Locale(identifier: "en-US")) { _ in }

        await #expect(throws: ASRBackendPool.Error.busy) {
            _ = try await pool.acquire(locale: Locale(identifier: "en-US")) { _ in }
        }

        await pool.release(first, discard: false)
    }

    @Test("idle ASR eviction releases the model after the grace period") async throws {
        let backend = FakeLifecycleBackend()
        let pool = ASRBackendPool(makeBackend: { backend },
                                  idleEvictionDelay: .milliseconds(20))
        let lease = try await pool.acquire(locale: Locale(identifier: "en-US")) { _ in }
        await pool.release(lease, discard: false)
        try await Task.sleep(for: .milliseconds(80))

        #expect(backend.releases == 1)
    }
}
```

Add a controller regression test that prepares the controller, lets the pool evict, then presses again and verifies that a fresh backend is created. This proves the controller does not retain the evicted model:

```swift
@Test("dictation controller does not retain an evicted prepared backend")
func controllerAllowsPoolEviction() async throws {
    var backends: [FakeLifecycleBackend] = []
    let pool = ASRBackendPool(makeBackend: {
        let backend = FakeLifecycleBackend()
        backends.append(backend)
        return backend
    }, idleEvictionDelay: .milliseconds(20))
    let controller = DictationController(
        backendProvider: pool,
        capture: FakeCapture(log: EventLog()),
        inserter: FakeInserter(),
        captionsActive: { false })

    controller.prepare()
    await controller.waitForWorkForTests()
    try await Task.sleep(for: .milliseconds(60))
    controller.press()
    await controller.waitForWorkForTests()
    controller.release()
    await controller.waitForWorkForTests()

    #expect(backends.count == 2)
    #expect(backends[0].releases == 1)
    #expect(backends[1].prepares == 1)
}
```

The test uses the existing `FakeCapture` and `FakeInserter` helpers. The final test body must assert concrete counters rather than implementation details such as private fields.

- [x] **Step 2: Write idle scheduler tests**

Add tests for the idle eviction helper:

```swift
@Test("cancelling idle eviction keeps the resource warm") async throws {
    let evictor = IdleEviction()
    var evictions = 0
    evictor.schedule(after: .milliseconds(20), shouldEvict: { true }) { evictions += 1 }
    evictor.cancel()
    try await Task.sleep(for: .milliseconds(60))
    #expect(evictions == 0)
}

@Test("idle eviction runs only when the resource is still idle") async throws {
    let evictor = IdleEviction()
    var evictions = 0
    evictor.schedule(after: .milliseconds(20), shouldEvict: { false }) { evictions += 1 }
    try await Task.sleep(for: .milliseconds(60))
    #expect(evictions == 0)
}
```

- [ ] **Step 3: Run the tests and verify the expected red state**

The red-state run is historical context from the implementation session and
was not independently reproduced during this continuation; the tests are now
green in the fresh release-suite verification below.

Run:

```bash
swift test -c release -Xswiftc -enable-testing -Xswiftc -DSAIITY_TEST_HOOKS --filter ModelLifecycleTests
```

Expected: compilation fails because `ASRBackendPool`, `ASRBackendProvider`, and `IdleEviction` do not exist yet. Do not add production code before observing this failure.

### Task 2: Implement the shared ASR pool

**Files:**
- Create: `Sources/sAiity/ASRBackendPool.swift`
- Modify: `Sources/sAiity/DictationController.swift`

**Interfaces:**
- `@MainActor protocol ASRBackendProvider` exposes `prepare`, `acquire`, `release(_:discard:)`, and `invalidate`.
- `@MainActor final class ASRBackendPool` owns at most one backend and one preparation task, rejects an active second lease with `ASRBackendPool.Error.busy`, and schedules delayed idle eviction.
- `@MainActor final class SingleBackendProvider` preserves the existing test initializer behavior for controller tests.

- [x] **Step 1: Add the minimal provider and pool implementation**

Implement these signatures:

```swift
@MainActor
protocol ASRBackendProvider: AnyObject {
    func prepare(locale: Locale,
                 progress: @escaping @Sendable (String) -> Void) async throws
    func acquire(locale: Locale,
                 progress: @escaping @Sendable (String) -> Void) async throws -> TranscriptionBackend
    func release(_ backend: TranscriptionBackend, discard: Bool) async
    func invalidate() async
}

@MainActor
final class ASRBackendPool: ASRBackendProvider {
    enum Error: LocalizedError, Equatable {
        case busy

        var errorDescription: String? {
            switch self {
            case .busy: return String(localized: "Speech recognition is already in use.")
            }
        }
    }

    init(makeBackend: @escaping () -> TranscriptionBackend,
         idleEvictionDelay: Duration = .seconds(45))
    // `prepare` creates at most one backend and shares its in-flight task.
    // `acquire` cancels an idle eviction and marks that backend in use.
    // `release(discard: false)` clears the lease but keeps the backend warm.
    // `release(discard: true)` and `invalidate` await `backend.release()` and
    // drop every strong reference held by the pool.
    func replace(with backend: TranscriptionBackend) async
}
```

When the pool evicts, check that no active lease exists and that the generation still matches the scheduled task. `release` must be idempotent for an already discarded backend. `prepare` must release a candidate if preparation is cancelled or fails.

- [x] **Step 2: Refactor `DictationController` to use a provider**

Add an initializer taking `backendProvider: any ASRBackendProvider`, keep the existing `makeBackend:` initializer by wrapping it in `SingleBackendProvider`, and replace `preparedBackend`/`preparedFormat` with provider calls:

- `prepare()` awaits `backendProvider.prepare` and retains no backend reference.
- `start(session:)` awaits the preparation task, then calls `backendProvider.acquire`, reads `inputFormat`, and stores only the active backend for the microphone session.
- `finish(session:)` calls `finishDictation`, then `backendProvider.release(backend, discard: false)` before clearing the active reference.
- `cancel()` and `failStart` call `backendProvider.invalidate()` or `release(..., discard: true)` so no controller-owned reference survives cancellation.
- `invalidatePreparedBackend()` awaits the controller cleanup and then invalidates the provider.

Keep all existing phase transitions and authoritative completion fallback behavior unchanged.

- [x] **Step 3: Run targeted tests to green**

Run:

```bash
swift test -c release -Xswiftc -enable-testing -Xswiftc -DSAIITY_TEST_HOOKS --filter ModelLifecycleTests
swift test -c release -Xswiftc -enable-testing -Xswiftc -DSAIITY_TEST_HOOKS --filter DictationControllerTests
```

Expected: the new lifecycle tests and all existing dictation tests pass.

### Task 3: Integrate captions with the shared pool

**Files:**
- Modify: `Sources/sAiity/AppDelegate.swift`

**Interfaces:**
- `AppDelegate` owns one `ASRBackendPool` and passes it into `DictationController`.
- Caption start acquires the pool backend; caption teardown returns it warm; model deletion and engine changes invalidate/replace it.

- [x] **Step 1: Route both consumers through the pool**

Replace the independently prepared caption backend and dictation factory with:

```swift
private lazy var asrBackendPool = ASRBackendPool(makeBackend: AppDelegate.makeActiveBackend)

private lazy var dictationController = DictationController(
    backendProvider: asrBackendPool,
    capture: dictationCapture,
    inserter: TextInserter(),
    captionsActive: { [weak self] in self?.state.isActive ?? false },
    translationConfiguration: { [weak self] in
        self?.dictationTranslationConfiguration() ?? .disabled
    },
    translate: { [weak self] text, source, target in
        guard let self else { return nil }
        return await self.translateDictatedText(text, source: source, target: target)
    },
    onPhaseChanged: { [weak self] phase in self?.updateDictationToast(phase) })
```

Caption start must call `try await asrBackendPool.acquire(...)` before `backend.start`, and point `captureSink` at that acquired backend only after acquisition succeeds. Caption teardown must point the sink at `nil` before returning the backend. Do not retain a second long-lived strong `backend` property outside the pool.

- [x] **Step 2: Preserve model-switch and deletion semantics**

Engine changes must cancel/invalidate dictation preparation, stop the current caption session as today, call `await asrBackendPool.replace(with: new.makeBackend())`, repoint the sink, and restart only if the previous caption state was running. `releaseModels()` must await dictation invalidation, stop captions, invalidate the pool, and install an unprepared backend for the newly selected engine.

When a second consumer attempts to acquire the pool, show the existing caption error overlay/status path with the pool's localized error rather than allowing a second model load.

- [x] **Step 3: Run caption and full tests**

Run:

```bash
swift test -c release -Xswiftc -enable-testing -Xswiftc -DSAIITY_TEST_HOOKS --filter StreamingASRBackendTests
swift test -c release -Xswiftc -enable-testing -Xswiftc -DSAIITY_TEST_HOOKS
```

Expected: exit code 0 with no new failures.

### Task 4: Add delayed translator eviction

**Files:**
- Create: `Sources/sAiity/IdleEviction.swift`
- Modify: `Sources/sAiity/AppDelegate.swift`
- Modify: `Sources/sAiity/MemoryPolicy.swift`

**Interfaces:**
- `@MainActor final class IdleEviction` owns a cancellable delayed task and runs an async eviction callback only when its `shouldEvict` closure still returns true.
- `AppDelegate` uses one instance for the shared translator, with a 45-second idle grace period.

- [x] **Step 1: Implement the idle scheduler**

Implement cancellation, generation guarding, and `Duration`-based sleeping. The scheduler must not retain the app through a stale task after `cancel()`.

- [x] **Step 2: Schedule translator release only after work finishes**

Cancel the translator eviction when preparation or translation begins. After caption teardown and after dictation translation completes, schedule eviction only when there is no active caption session, no active dictation phase, no translator swap, and `translatorReady` is true. The callback must set `activeTranslator` to `nil`, set `translatorReady = false`, call `stop()`, then call `MemoryPolicy.releaseCaches()`.

Do not call `activeTranslator?.stop()` unconditionally from normal caption teardown anymore; that path should schedule the grace-period eviction. Keep immediate release for translator swaps, model deletion, and critical memory pressure. A critical pressure event must cancel the idle task before unloading.

- [x] **Step 3: Add memory-pressure coverage**

Expose a small test hook for the scheduler or use the existing `MemoryPolicy.Pressure` handler seam to prove a critical event cancels idle retention. Do not make tests depend on Activity Monitor or MLX being loaded.

- [x] **Step 4: Run focused and full tests**

Run:

```bash
swift test -c release -Xswiftc -enable-testing -Xswiftc -DSAIITY_TEST_HOOKS --filter ModelLifecycleTests
swift test -c release -Xswiftc -enable-testing -Xswiftc -DSAIITY_TEST_HOOKS
```

Expected: exit code 0.

### Task 5: Measure before and after

**Files:**
- Modify: `docs/superpowers/plans/2026-08-20-model-lifecycle-memory.md`

- [x] **Step 1: Capture the baseline memory snapshots from the installed app**

Record the process ID, `phys_footprint`, peak physical footprint, and
`IOAccelerator` contribution. The exact baseline memory snapshot is recorded
in the table below. Shortcut-to-ready latency and cross-feature startup timing
were not captured because they require a real global hot-key event, microphone
permission, and spoken audio.

- [x] **Step 2: Build the changed app**

Use the repository's normal release build path. The changed app was built and
signed at `build/sAiity.app`; it was launched locally for the memory sample but
was not copied over `/Applications`. Do not compare a debug build with the
release baseline.

- [x] **Step 3: Record the results and limits**

Add a short table to this plan with before/after values for physical footprint,
peak physical footprint, idle physical footprint after 60 seconds, and
`IOAccelerator`. State separately which numbers were measured and which paths
remain unverified because they require real audio/model downloads.

#### Observed measurement results (2026-08-20)

These are `phys_footprint` snapshots from the `footprint` tool, not RSS. The
active snapshots were taken from the installed baseline and the locally built
tree after Nemotron and MADLAD had been loaded. They were not a controlled
benchmark with identical audio, so the active values show direction rather than
a release-quality performance claim. The idle result is directly useful: it was
captured after the local process stopped using the models and the 45-second
eviction grace period elapsed.

| Snapshot | Installed baseline | Changed local build |
| --- | ---: | ---: |
| Physical footprint while models were active | 2,101,643,760 B | 2,057,521,624 B |
| Peak physical footprint | 2,316,356,080 B | 2,100,742,592 B |
| IOAccelerator contribution | 1,842,020,352 B | 1,860,321,280 B |
| Physical footprint after 60 s idle | not captured | 113,624,456 B |

The changed process logged `session released - active 1753 MB, cached 0 MB`
after caption teardown and later `released translator (idle grace period) -
active 0 MB, cached 0 MB`. Its post-eviction snapshot still reported about
571 MB as neural-engine `nofootprint`/mapped state, but only 113.6 MB in
physical footprint. This confirms that the lifecycle code releases resident
model memory; it does not prove that the operating system immediately returns
every mapped allocation to zero.

Shortcut-to-ready latency was not measured in this run because it requires a
real global hot-key event, microphone permission, and a spoken utterance. Real
model dictation insertion and simultaneous captions/dictation contention also
remain unverified by this runtime pass; the lifecycle and contention seams are
covered by unit tests.

### Task 6: Final verification and handoff

- [x] **Step 1: Re-read every modified file and inspect the diff**

Run `git diff --check`, `git diff --stat`, and inspect all changed lifecycle code and tests. Confirm no unrelated UI, localization, release, or repository changes are included.

- [x] **Step 2: Run the required release test command fresh**

```bash
swift test -c release -Xswiftc -enable-testing -Xswiftc -DSAIITY_TEST_HOOKS
```

- [x] **Step 3: Report evidence without overstating it**

Report the exact test result, exact measured memory values, whether the installed build was manually exercised, and any unverified model-specific behavior. Do not create a release until the fresh test/build/measurement evidence supports it.

## Self-Review

- The duplicate ASR residency requirement is covered by Tasks 1–3: one pool, exclusive acquisition, no controller-held prepared reference, and replacement/invalidation paths.
- Translator idle retention and critical-pressure release are covered by Task 4.
- Startup latency and physical-memory evidence are covered by Task 5.
- Existing rolling captions, authoritative dictation completion, model deletion, and engine switching are explicitly preserved and tested by the full suite in Tasks 2–4.
- The later `sessionLines` memory cap is intentionally excluded; it needs its own product decision because it trades transcript completeness for bounded live-session memory.
