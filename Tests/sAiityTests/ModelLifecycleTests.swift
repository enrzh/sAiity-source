import AVFoundation
import Testing

@testable import sAiity

@MainActor
@Suite struct ModelLifecycleTests {
    @Test("cleanup compatibility requires a downloaded Qwen or Gemma GGUF")
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

        var inputFormat: AVAudioFormat? { get async { format } }

        func prepare(locale: Locale,
                     progress: @escaping @Sendable (String) -> Void) async throws {
            prepares += 1
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

    @Test("AppDelegate Whisper preparation delegates through the production seam")
    func appDelegateWhisperPreparationBoundary() async throws {
        let selected = WhisperDictationBackend.model
        let app = AppDelegate()
        let before = (app.captionEngineForTests, app.captionPoolPreparedForTests, app.captionPoolLeaseForTests)
        var received: WhisperDictationBackend.ModelChoice?
        var progressCalls = 0
        AppDelegate.testWhisperPreparation = { choice, progress in
            received = choice
            progress(Progress(totalUnitCount: 1))
        }
        defer { AppDelegate.testWhisperPreparation = nil }
        try await app.prepareSelectedWhisperModelForUse { _ in progressCalls += 1 }
        let after = (app.captionEngineForTests, app.captionPoolPreparedForTests, app.captionPoolLeaseForTests)
        #expect(received == selected)
        #expect(progressCalls == 1)
        #expect(before.0 == after.0)
        #expect(before.1 == after.1)
        #expect(before.2 == after.2)
    }

    @Test("AppDelegate Whisper preparation failure propagates without readiness")
    func appDelegateWhisperPreparationFailureBoundary() async {
        let app = AppDelegate()
        let wasReady = WhisperDictationBackend.isReady(WhisperDictationBackend.model)
        AppDelegate.testWhisperPreparation = { _, _ in throw BackendError.notPrepared }
        defer { AppDelegate.testWhisperPreparation = nil }
        do {
            try await app.prepareSelectedWhisperModelForUse()
            #expect(Bool(false))
        } catch {
            #expect((error as? BackendError) == .notPrepared)
        }
        #expect(WhisperDictationBackend.isReady(WhisperDictationBackend.model) == wasReady)
    }
}
