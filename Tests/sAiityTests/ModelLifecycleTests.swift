import AVFoundation
import Testing

@testable import sAiity

// AppDelegate preparation observes the process-wide CaptionSession admission.
// Keep its tests in the same serial namespace as model-removal operations.
extension SavedTranscriptOperationTests {
@MainActor
@Suite struct ModelLifecycleTests {
    @Test("Post-eviction evidence and reacquisition wait for actual native release acknowledgement")
    func evictionEvidenceWaitsForNativeRelease() async throws {
        final class ReleaseGate: @unchecked Sendable {
            private let lock = NSLock()
            private var continuation: CheckedContinuation<Void, Never>?
            var entered: Bool { lock.withLock { continuation != nil } }
            func wait() async {
                await withCheckedContinuation { value in lock.withLock { continuation = value } }
            }
            func open() {
                let value = lock.withLock { let value = continuation; continuation = nil; return value }
                value?.resume()
            }
        }
        let gate = ReleaseGate(), backend = FakeLifecycleBackend()
        backend.onRelease = { await gate.wait() }
        let pool = ASRBackendPool(makeBackend: { backend }, idleEvictionDelay: .milliseconds(5))
        try await pool.prepare(locale: Locale(identifier: "en")) { _ in }
        let deadline = ContinuousClock.now + .seconds(2)
        while !gate.entered, ContinuousClock.now < deadline { await Task.yield() }
        try #require(gate.entered)
        #expect(pool.warmState == nil)
        var acquired = false
        let next = Task {
            let lease = try await pool.acquire(locale: Locale(identifier: "en")) { _ in }
            acquired = true
            return lease
        }
        try await Task.sleep(for: .milliseconds(15))
        #expect(!acquired && backend.prepares == 1)
        gate.open()
        let lease = try await next.value
        #expect(acquired && backend.prepares == 2 && pool.warmState == "warm")
        backend.onRelease = nil
        await pool.release(lease, discard: true)
    }
    @Test("warm-state evidence follows preparation and confirmed idle eviction, not loop index")
    func actualWarmState() async throws {
        let backend = FakeLifecycleBackend()
        let pool = ASRBackendPool(makeBackend: { backend }, idleEvictionDelay: .milliseconds(20))
        #expect(pool.warmState == "cold-start")
        let lease = try await pool.acquire(locale: Locale(identifier: "en")) { _ in }
        #expect(pool.warmState == "warm")
        await pool.release(lease, discard: false)
        let deadline = ContinuousClock.now + .seconds(2)
        while pool.warmState != "post-eviction", ContinuousClock.now < deadline { await Task.yield() }
        #expect(backend.releases == 1)
        #expect(pool.warmState == "post-eviction")
        let second = try await pool.acquire(locale: Locale(identifier: "en")) { _ in }
        #expect(pool.warmState == "warm")
        await pool.release(second, discard: true)
        #expect(pool.warmState == nil, "manual invalidation is not an idle eviction or a fresh process")
    }
    @Test("changing a supported target keeps the same resident translation model and native leases")
    func targetChangeKeepsResidentTranslator() {
        let runtime = TranslationRuntime()
        let translator = TranslationProcedureTests.Engine()
        runtime.active = translator
        runtime.engine = .hyMT2
        runtime.ready = true
        runtime.preparedTarget = "de"
        runtime.beginUse()
        #expect(runtime.retargetPreparedModel(to: "en"))
        #expect(runtime.preparedTarget == "en")
        #expect(runtime.active === translator)
        #expect(runtime.users == 1)
        #expect(!runtime.retargetPreparedModel(to: "unsupported-language"))
        #expect(runtime.preparedTarget == "en")
        runtime.endUse()
        runtime.ready = false
        #expect(!runtime.retargetPreparedModel(to: "de"))
    }

    @Test("An expired waiter cannot acquire a model whose earlier shared load finishes later")
    func existingLoadStillHonorsWaiterDeadline() async throws {
        let gate = DictationControllerTests.ContinuationGate(), backend = FakeLifecycleBackend()
        backend.preparationGate = gate
        let pool = ASRBackendPool(makeBackend: { backend })
        let loading = Task { try await pool.prepare(locale: Locale(identifier: "en")) { _ in } }
        let waitingUntil = ContinuousClock.now + .seconds(2)
        while !gate.entered, ContinuousClock.now < waitingUntil { await Task.yield() }
        try #require(gate.entered)
        let expired = Task {
            try await LocalGeneration.$deadline.withValue(.now + .milliseconds(5)) {
                try await pool.acquire(locale: Locale(identifier: "en")) { _ in }
            }
        }
        try await Task.sleep(for: .milliseconds(15))
        gate.open()
        try await loading.value
        do {
            let unexpected = try await expired.value
            Issue.record("Expired waiter acquired the native model")
            await pool.release(unexpected, discard: false)
        } catch { #expect(error is CancellationError) }
        #expect(backend.prepares == 1 && backend.releases == 0 && !pool.hasActiveLeaseForTests)
        let lease = try await pool.acquire(locale: Locale(identifier: "en")) { _ in }
        await pool.release(lease, discard: true)
    }
    @Test("separate consumers reuse one preparation only for matching recognition configurations")
    func scopedPoolsShareIdenticalModel() async throws {
        let captionBackend = FakeLifecycleBackend()
        let dictationBackend = FakeLifecycleBackend()
        let captions = ASRBackendPool(makeBackend: { captionBackend })
        var matching = true
        let dictation = ASRBackendPool(makeBackend: { dictationBackend }, sharingWith: captions,
                                       matchesSharedConfiguration: { matching })
        try await dictation.prepare(locale: Locale(identifier: "en")) { _ in }
        let captionLease = try await captions.acquire(locale: Locale(identifier: "en")) { _ in }
        await captions.release(captionLease, discard: false)
        let dictationLease = try await dictation.acquire(locale: Locale(identifier: "en")) { _ in }
        #expect(captionLease === dictationLease)
        #expect(captionBackend.prepares == 1)
        #expect(dictationBackend.prepares == 0)
        // A changed selection cannot reroute the lease that already owns native state.
        matching = false
        await dictation.release(dictationLease, discard: false)
        #expect(!captions.hasActiveLeaseForTests)
        let different = try await dictation.acquire(locale: Locale(identifier: "en")) { _ in }
        #expect(different === dictationBackend)
        #expect(dictationBackend.prepares == 1)
        await dictation.release(different, discard: false)
        await dictation.invalidate()
        await captions.invalidate()
        #expect(captionBackend.releases == 1 && dictationBackend.releases == 1)
    }

    @Test("matching child consumers cannot steal or invalidate another consumer's native lease")
    func matchingConsumerCannotStealLease() async throws {
        let backend = FakeLifecycleBackend()
        let captions = ASRBackendPool(makeBackend: { backend })
        let dictation = ASRBackendPool(makeBackend: { FakeLifecycleBackend() }, sharingWith: captions,
                                       matchesSharedConfiguration: { true })
        let lease = try await captions.acquire(locale: Locale(identifier: "en")) { _ in }
        await #expect(throws: ASRBackendPool.Error.busy) {
            _ = try await dictation.acquire(locale: Locale(identifier: "en")) { _ in }
        }
        await dictation.invalidate()
        #expect(backend.releases == 0)
        #expect(captions.hasActiveLeaseForTests)
        await captions.release(lease, discard: true)
        #expect(backend.releases == 1)
    }
    @Test("translator lifetime waits for every native user before allowing teardown")
    func translatorWaitsForAllUsers() async {
        let runtime = TranslationRuntime()
        runtime.beginUse()
        runtime.beginUse()
        var finished = false
        let wait = Task { @MainActor in await runtime.waitUntilIdle(); finished = true }
        await Task.yield()
        runtime.endUse()
        await Task.yield()
        #expect(!finished)
        #expect(runtime.users == 1)
        runtime.endUse()
        await wait.value
        #expect(finished)
        #expect(runtime.users == 0)
    }

    @Test("caption teardown returns its lease once and retains warm model weights")
    func captionResourcesReturnLease() async throws {
        let backend = FakeLifecycleBackend()
        let resources = CaptionSessionResources(makeBackend: { backend })
        resources.backend = try await resources.pool.acquire(locale: Locale(identifier: "en")) { _ in }
        await resources.stopAudio()
        await resources.stopAudio()
        #expect(backend.stops == 1)
        #expect(backend.releases == 0)
        #expect(resources.backend == nil)
        #expect(resources.pool.preparedForTests)
        #expect(!resources.pool.hasActiveLeaseForTests)
        await resources.pool.invalidate()
    }
    @Test("cleanup compatibility requires a downloaded supported GGUF")
    func cleanupCompatibilityIsRestricted() {
        let qwen = LocalModel(source: .url("https://example.invalid/qwen.gguf"), file: "qwen.gguf", label: "Qwen", bytes: 1, recommended: false, note: "", licence: "")
        #expect(!qwen.isCleanupCompatible())
    }

    @Test("downloaded custom GGUF compatibility matches labels case-insensitively")
    func downloadedCustomGGUFCompatibilityUsesLabel() throws {
        let directory = LocalModel.directory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let prefix = "model-lifecycle-\(UUID().uuidString)"
        let files = ["\(prefix)-alpha.gguf", "\(prefix)-beta.gguf", "\(prefix)-other.gguf"]
        defer { for file in files { try? FileManager.default.removeItem(at: directory.appendingPathComponent(file)) } }
        for file in files { try Data([0]).write(to: directory.appendingPathComponent(file)) }

        let gemma = LocalModel(source: .url("https://example.invalid/gemma.gguf"), file: files[0], label: "Gemma", bytes: 1, recommended: false, note: "", licence: "")
        let qwen = LocalModel(source: .url("https://example.invalid/qwen.gguf"), file: files[1], label: "QWEN", bytes: 1, recommended: false, note: "", licence: "")
        let other = LocalModel(source: .url("https://example.invalid/other.gguf"), file: files[2], label: "Mistral", bytes: 1, recommended: false, note: "", licence: "")

        #expect(gemma.isCleanupCandidate())
        #expect(qwen.isCleanupCandidate())
        #expect(!other.isCleanupCandidate())
        #expect(gemma.isCleanupCompatible())
        #expect(qwen.isCleanupCompatible())
        #expect(!other.isCleanupCompatible())
    }

    final class FakeLifecycleBackend: TranscriptionBackend, @unchecked Sendable {
        let name = "Lifecycle test backend"
        let format = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!
        var prepares = 0
        var starts = 0
        var stops = 0
        var releases = 0
        var preparationGate: DictationControllerTests.ContinuationGate?
        var onRelease: (@Sendable () async -> Void)?

        var inputFormat: AVAudioFormat? { get async { format } }

        func prepare(locale: Locale,
                     progress: @escaping @Sendable (String) -> Void) async throws {
            prepares += 1
            if let preparationGate { await preparationGate.wait() }
        }

        func start(onChunk: @escaping @Sendable (TranscriptChunk) -> Void) async throws {
            starts += 1
        }

        func feed(_ buffer: AVAudioPCMBuffer) {}

        func stop() async {
            stops += 1
        }

        func release() async {
            releases += 1
            await onRelease?()
        }

        func finishDictation() async -> String? { nil }
    }

    final class FakeCapture: DictationAudioCapture {
        var started = false

        func start(targetFormat: AVAudioFormat,
                   onBuffer: @escaping @Sendable (AVAudioPCMBuffer) -> Void) throws {
            started = true
        }

        func stop() {}
    }

    final class FakeInserter: DictationTextInsertion {
        func insert(_ text: String) -> TextInsertionResult {
            TextInsertionResult(outcome: .copied)
        }
    }

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

    @Test("concurrent cold root and child acquisition preserves exactly one native owner")
    func concurrentColdConsumersAreExclusive() async throws {
        let backend = FakeLifecycleBackend()
        let gate = DictationControllerTests.ContinuationGate()
        backend.preparationGate = gate
        let captions = ASRBackendPool(makeBackend: { backend })
        let dictation = ASRBackendPool(makeBackend: { FakeLifecycleBackend() }, sharingWith: captions,
                                       matchesSharedConfiguration: { true })
        let first = Task { try await captions.acquire(locale: Locale(identifier: "en")) { _ in } }
        let deadline = ContinuousClock.now + .seconds(2)
        while !gate.entered, ContinuousClock.now < deadline { await Task.yield() }
        let second = Task { try await dictation.acquire(locale: Locale(identifier: "en")) { _ in } }
        await Task.yield()
        gate.open()
        var winners: [TranscriptionBackend] = []
        var busy = 0
        for task in [first, second] {
            do { winners.append(try await task.value) }
            catch ASRBackendPool.Error.busy { busy += 1 }
        }
        #expect(winners.count == 1)
        #expect(busy == 1)
        #expect(backend.prepares == 1)
        #expect(backend.releases == 0)
        if let winner = winners.first { await dictation.release(winner, discard: false); await captions.release(winner, discard: true) }
    }

    @Test("refreshing an unused matching child preserves captions' in-progress cold load")
    func childRefreshPreservesCaptionPreparation() async throws {
        let backend = FakeLifecycleBackend()
        let gate = DictationControllerTests.ContinuationGate()
        backend.preparationGate = gate
        let captions = ASRBackendPool(makeBackend: { backend })
        let dictation = ASRBackendPool(makeBackend: { FakeLifecycleBackend() }, sharingWith: captions,
                                       matchesSharedConfiguration: { true })
        let first = Task { try await captions.acquire(locale: Locale(identifier: "en")) { _ in } }
        let deadline = ContinuousClock.now + .seconds(2)
        while !gate.entered, ContinuousClock.now < deadline { await Task.yield() }
        let invalidated = Task { await dictation.invalidate() }
        await Task.yield()
        gate.open()
        await invalidated.value
        let winner = try? await first.value
        #expect(winner != nil)
        #expect(backend.prepares == 1 && backend.releases == 0)
        if let winner { await captions.release(winner, discard: true) }
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

    @Test("invalidating a shared pool does not steal an active lease")
    func invalidationDoesNotReleaseActiveLease() async throws {
        let backend = FakeLifecycleBackend()
        let pool = ASRBackendPool(makeBackend: { backend },
                                  idleEvictionDelay: .seconds(5))
        let lease = try await pool.acquire(locale: Locale(identifier: "en-US")) { _ in }

        await pool.invalidate()

        #expect(backend.releases == 0)
        await pool.release(lease, discard: true)
        #expect(backend.releases == 1)
    }

    @Test("cancelling prepared dictation leaves a shared caption lease alone")
    func cancellingPreparedDictationPreservesActiveLease() async throws {
        let backend = FakeLifecycleBackend()
        let pool = ASRBackendPool(makeBackend: { backend },
                                  idleEvictionDelay: .seconds(5))
        let controller = DictationController(
            backendProvider: pool,
            capture: FakeCapture(),
            inserter: FakeInserter(),
            captionsActive: { false })

        controller.prepare()
        await controller.waitForWorkForTests()
        let captionLease = try await pool.acquire(locale: Locale(identifier: "en-US")) { _ in }

        controller.cancel()
        await controller.waitForWorkForTests()

        #expect(backend.releases == 0)
        await pool.release(captionLease, discard: true)
        #expect(backend.releases == 1)
    }

    @Test("idle ASR eviction releases the model after the grace period")
    func idleASREvictionReleasesModel() async throws {
        let backend = FakeLifecycleBackend()
        let pool = ASRBackendPool(makeBackend: { backend },
                                  idleEvictionDelay: .milliseconds(100))
        let lease = try await pool.acquire(locale: Locale(identifier: "en-US")) { _ in }
        await pool.release(lease, discard: false)
        for _ in 0..<40 {
            if backend.releases == 1 { break }
            try await Task.sleep(for: .milliseconds(50))
        }

        #expect(backend.releases == 1)
    }

    @Test("dictation controller does not retain an evicted prepared backend")
    func controllerAllowsPoolEviction() async throws {
        var backends: [FakeLifecycleBackend] = []
        let pool = ASRBackendPool(makeBackend: {
            let backend = FakeLifecycleBackend()
            backends.append(backend)
            return backend
        }, idleEvictionDelay: .milliseconds(100))
        let controller = DictationController(
            backendProvider: pool,
            capture: FakeCapture(),
            inserter: FakeInserter(),
            captionsActive: { false })

        controller.prepare()
        await controller.waitForWorkForTests()
        for _ in 0..<40 {
            if backends.first?.releases == 1 { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        controller.press()
        await controller.waitForWorkForTests()
        controller.release()
        await controller.waitForWorkForTests()

        #expect(backends.count == 2)
        #expect(backends[0].releases == 1)
        #expect(backends[1].prepares == 1)
    }

    @Test("cancelling idle eviction keeps the resource warm")
    func cancellingIdleEvictionKeepsResourceWarm() async throws {
        let evictor = IdleEviction()
        var evictions = 0
        evictor.schedule(after: .milliseconds(100), shouldEvict: { true }) { evictions += 1 }
        evictor.cancel()
        try await Task.sleep(for: .milliseconds(300))

        #expect(evictions == 0)
    }

    @Test("idle eviction runs only when the resource is still idle")
    func idleEvictionChecksEligibility() async throws {
        let evictor = IdleEviction()
        var evictions = 0
        evictor.schedule(after: .milliseconds(100), shouldEvict: { false }) { evictions += 1 }
        try await Task.sleep(for: .milliseconds(300))

        #expect(evictions == 0)
    }

    @Test("critical memory pressure cancels a pending translator eviction")
    func criticalPressureCancelsTranslatorEviction() async throws {
        let app = AppDelegate()
        app.armTranslatorEvictionForTests(after: .milliseconds(100))

        #expect(app.translatorEvictionScheduledForTests)
        app.handleMemoryPressureForTests(.critical)
        try await Task.sleep(for: .milliseconds(300))

        #expect(!app.translatorEvictionScheduledForTests)
        #expect(!app.translatorReadyForTests)
    }

    @Test("dictation cleanup prepares an independent local translator")
    func dictationCleanupPreparesIndependentLocalTranslator() async {
        let events = EventLog()

        let result = await AppDelegate.performDictationCleanup(
            "clean this text",
            prepare: { await events.append("prepare") },
            cleanup: { text in await events.append("cleanup:\(text)"); return "Cleaned text." },
            stop: { await events.append("stop") })

        #expect(result == "Cleaned text.")
        #expect(await events.value == ["prepare", "cleanup:clean this text", "stop"])
    }

    @Test("AppDelegate Whisper preparation delegates through the production seam")
    func appDelegateWhisperPreparationBoundary() async throws {
        let selected = WhisperDictationBackend.model
        let app = AppDelegate()
        let before = (app.captionEngineForTests, app.captionPoolPreparedForTests, app.captionPoolLeaseForTests)
        let received = ValueBox<WhisperDictationBackend.ModelChoice?>(nil)
        let progressCalls = LockedCounter()
        app.whisperPreparationForTests = { choice, progress in
            await received.set(choice)
            progress(Progress(totalUnitCount: 1))
        }
        defer { app.whisperPreparationForTests = nil }
        try await app.prepareSelectedWhisperModelForUse { _ in progressCalls.increment() }
        let after = (app.captionEngineForTests, app.captionPoolPreparedForTests, app.captionPoolLeaseForTests)
        #expect(await received.value == selected)
        #expect(progressCalls.value == 1)
        #expect(before.0 == after.0)
        #expect(before.1 == after.1)
        #expect(before.2 == after.2)
    }

    @Test("explicit Whisper preparation freezes the clicked choice")
    func explicitWhisperChoiceIsNotReread() async throws {
        let app = AppDelegate()
        let received = ValueBox<WhisperDictationBackend.ModelChoice?>(nil)
        app.whisperPreparationForTests = { choice, _ in await received.set(choice) }
        defer { app.whisperPreparationForTests = nil }
        try await app.prepareSelectedWhisperModelForUse(.base)
        WhisperDictationBackend.model = .small
        #expect(await received.value == .base)
        await received.set(nil)
        try await app.prepareSelectedWhisperModelForUse(.small)
        WhisperDictationBackend.model = .base
        #expect(await received.value == .small)
    }

    @Test("AppDelegate Whisper preparation failure propagates without readiness")
    func appDelegateWhisperPreparationFailureBoundary() async {
        let app = AppDelegate()
        let selected = WhisperDictationBackend.model
        let wasReady = WhisperDictationBackend.isReady(selected)
        app.whisperPreparationForTests = { _, _ in throw BackendError.notPrepared }
        defer { app.whisperPreparationForTests = nil }
        do {
            try await app.prepareSelectedWhisperModelForUse()
            #expect(Bool(false))
        } catch {
            #expect((error as? BackendError) == .notPrepared)
        }
        #expect(WhisperDictationBackend.isReady(selected) == wasReady)
    }

    @Test("Whisper preparation does not mutate caption state while blocked")
    func appDelegateWhisperPreparationPreservesStateMidpoint() async {
        final class Gate: @unchecked Sendable {
            var entered = false
            var continuation: CheckedContinuation<Void, Never>?
        }

        let gate = Gate()
        let app = AppDelegate()
        let before = (app.captionEngineForTests, app.captionPoolPreparedForTests, app.captionPoolLeaseForTests)
        app.whisperPreparationForTests = { _, _ in
            gate.entered = true
            await withCheckedContinuation { continuation in
                gate.continuation = continuation
            }
        }
        defer { app.whisperPreparationForTests = nil }

        let task = Task { @MainActor in
            try await app.prepareSelectedWhisperModelForUse()
        }
        for _ in 0..<100 where !gate.entered { await Task.yield() }
        #expect(gate.entered)
        let during = (app.captionEngineForTests, app.captionPoolPreparedForTests, app.captionPoolLeaseForTests)
        #expect(during.0 == before.0)
        #expect(during.1 == before.1)
        #expect(during.2 == before.2)

        gate.continuation?.resume()
        _ = await task.result
        let after = (app.captionEngineForTests, app.captionPoolPreparedForTests, app.captionPoolLeaseForTests)
        #expect(after.0 == before.0)
        #expect(after.1 == before.1)
        #expect(after.2 == before.2)
    }

    private actor EventLog {
        private(set) var value: [String] = []

        func append(_ event: String) {
            value.append(event)
        }
    }

    private actor Counter {
        private(set) var value = 0

        func increment() {
            value += 1
        }
    }

    private final class LockedCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0

        var value: Int {
            lock.withLock { count }
        }

        func increment() {
            lock.withLock { count += 1 }
        }
    }

    private actor ValueBox<Value: Sendable> {
        private(set) var value: Value

        init(_ value: Value) {
            self.value = value
        }

        func set(_ value: Value) {
            self.value = value
        }
    }
}
}
