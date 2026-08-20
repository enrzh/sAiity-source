import AVFoundation
import Foundation
import Testing

@testable import sAiity

@MainActor
@Suite struct DictationControllerTests {
    final class EventLog {
        var values: [String] = []
    }

    final class FakeCapture: DictationAudioCapture {
        let log: EventLog
        var started = false
        var stopped = false

        init(log: EventLog) { self.log = log }

        func start(targetFormat: AVAudioFormat,
                   onBuffer: @escaping @Sendable (AVAudioPCMBuffer) -> Void) throws {
            started = true
        }

        func stop() {
            stopped = true
            log.values.append("capture.stop")
        }
    }

    final class FakeBackend: TranscriptionBackend, @unchecked Sendable {
        let log: EventLog
        private let format = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!
        var starts = 0
        var stops = 0
        var prepares = 0
        var blockPreparation = false
        var preparationContinuation: CheckedContinuation<Void, Never>?
        var blockStop = false
        var stopContinuation: CheckedContinuation<Void, Never>?
        var onChunk: (@Sendable (TranscriptChunk) -> Void)?
        var detectedLanguageResult: String? = "en"
        var authoritativeResult: String?
        var finishDictationCalls = 0

        init(log: EventLog) { self.log = log }

        let name = "Test backend"
        var inputFormat: AVAudioFormat? { get async { format } }
        func prepare(locale: Locale, progress: @escaping @Sendable (String) -> Void) async throws {
            prepares += 1
            if blockPreparation {
                await withCheckedContinuation { continuation in
                    preparationContinuation = continuation
                }
            }
        }

        func finishPreparation() {
            preparationContinuation?.resume()
            preparationContinuation = nil
        }
        func start(onChunk: @escaping @Sendable (TranscriptChunk) -> Void) async throws {
            starts += 1
            self.onChunk = onChunk
        }
        func feed(_ buffer: AVAudioPCMBuffer) {}
        func flushPending() async {
            log.values.append("backend.flushPending")
            onChunk?(TranscriptChunk(text: "hello from dictation", isFinal: true))
        }
        func stop() async {
            stops += 1
            log.values.append("backend.stop")
            if blockStop {
                await withCheckedContinuation { continuation in
                    stopContinuation = continuation
                }
            }
        }
        func finishStop() {
            blockStop = false
            stopContinuation?.resume()
            stopContinuation = nil
        }
        func finishDictation() async -> String? {
            finishDictationCalls += 1
            if let authoritativeResult {
                log.values.append("backend.finishDictation")
                return authoritativeResult
            }
            await flushPending()
            await stop()
            return nil
        }
        func detectedLanguage() async -> String? { detectedLanguageResult }
    }

    final class FakeInserter: DictationTextInsertion {
        var inserted: [String] = []

        func insert(_ text: String) -> TextInsertionResult {
            inserted.append(text)
            return TextInsertionResult(outcome: .copied)
        }
    }

    @Test("release stops capture before stopping the backend and inserts final text")
    func releaseOrderAndInsertion() async {
        let log = EventLog()
        let backend = FakeBackend(log: log)
        let capture = FakeCapture(log: log)
        let inserter = FakeInserter()
        let controller = DictationController(
            makeBackend: { backend },
            capture: capture,
            inserter: inserter,
            captionsActive: { false })

        controller.press()
        await controller.waitForWorkForTests()
        controller.release()
        await controller.waitForWorkForTests()

        #expect(log.values == ["capture.stop", "backend.flushPending", "backend.stop"])
        #expect(inserter.inserted == ["hello from dictation"])
        #expect(controller.phase == .result("Copied to Clipboard"))
    }

    @Test("dictation inserts the authoritative completion instead of an early rolling final")
    func authoritativeCompletionReplacesEarlyHypothesis() async {
        let log = EventLog()
        let backend = FakeBackend(log: log)
        backend.authoritativeResult = "Schedule a meeting with Sarah."
        let inserter = FakeInserter()
        let controller = DictationController(
            makeBackend: { backend },
            capture: FakeCapture(log: log),
            inserter: inserter,
            captionsActive: { false })

        controller.press()
        await controller.waitForWorkForTests()
        backend.onChunk?(TranscriptChunk(
            text: "Schedule a meeting with Sara", isFinal: true))
        controller.release()
        await controller.waitForWorkForTests()

        #expect(backend.finishDictationCalls == 1)
        #expect(log.values == ["capture.stop", "backend.finishDictation"])
        #expect(inserter.inserted == ["Schedule a meeting with Sarah."])
    }

    @Test("an empty authoritative completion falls back to rolling finals")
    func emptyAuthoritativeCompletionUsesFallback() async {
        let log = EventLog()
        let backend = FakeBackend(log: log)
        backend.authoritativeResult = "   "
        let inserter = FakeInserter()
        let controller = DictationController(
            makeBackend: { backend },
            capture: FakeCapture(log: log),
            inserter: inserter,
            captionsActive: { false })

        controller.press()
        await controller.waitForWorkForTests()
        backend.onChunk?(TranscriptChunk(text: "Rolling final", isFinal: true))
        controller.release()
        await controller.waitForWorkForTests()

        #expect(backend.finishDictationCalls == 1)
        #expect(inserter.inserted == ["Rolling final"])
    }

    @Test("enabled dictation translates before inserting and copying")
    func translatesBeforeInsertion() async {
        let log = EventLog()
        let backend = FakeBackend(log: log)
        let capture = FakeCapture(log: log)
        let inserter = FakeInserter()
        var phases: [String] = []
        var calls: [(String, String, String)] = []
        let controller = DictationController(
            makeBackend: { backend },
            capture: capture,
            inserter: inserter,
            captionsActive: { false },
            translationConfiguration: {
                DictationTranslationConfiguration(enabled: true, target: "de")
            },
            translate: { text, source, target in
                calls.append((text, source, target))
                return "Hallo aus dem Diktat"
            },
            onPhaseChanged: { phases.append(String(describing: $0)) })

        controller.press()
        await controller.waitForWorkForTests()
        controller.release()
        await controller.waitForWorkForTests()

        #expect(calls.map { $0.0 } == ["hello from dictation"])
        #expect(calls.map { $0.1 } == ["en"])
        #expect(calls.map { $0.2 } == ["de"])
        #expect(inserter.inserted == ["Hallo aus dem Diktat"])
        #expect(phases.contains("transcribing"))
        #expect(phases.contains("translating"))
        #expect(phases.contains("inserting"))
        #expect(controller.phase == .result("Translated and copied"))
    }

    @Test("cancellation during translation cannot insert stale output")
    func cancellationDuringTranslationDiscardsOutput() async {
        final class TranslationGate: @unchecked Sendable {
            var started = false
            var continuation: CheckedContinuation<String?, Never>?

            func resolve(_ value: String?) {
                continuation?.resume(returning: value)
                continuation = nil
            }
        }

        let gate = TranslationGate()
        let inserter = FakeInserter()
        let controller = DictationController(
            makeBackend: { FakeBackend(log: EventLog()) },
            capture: FakeCapture(log: EventLog()),
            inserter: inserter,
            captionsActive: { false },
            translationConfiguration: {
                DictationTranslationConfiguration(enabled: true, target: "de")
            },
            translate: { _, _, _ in
                gate.started = true
                return await withCheckedContinuation { continuation in
                    gate.continuation = continuation
                }
            })

        controller.press()
        await controller.waitForWorkForTests()
        controller.release()
        for _ in 0..<100 where !gate.started { await Task.yield() }

        controller.cancel()
        gate.resolve("stale translation")
        await controller.waitForWorkForTests()

        #expect(inserter.inserted.isEmpty)
        #expect(!controller.isActive)
    }

    @Test("translation failure preserves the original dictated text")
    func translationFailureFallsBackToOriginal() async {
        let backend = FakeBackend(log: EventLog())
        let inserter = FakeInserter()
        let controller = DictationController(
            makeBackend: { backend },
            capture: FakeCapture(log: EventLog()),
            inserter: inserter,
            captionsActive: { false },
            translationConfiguration: {
                DictationTranslationConfiguration(enabled: true, target: "de")
            },
            translate: { _, _, _ in nil })

        controller.press()
        await controller.waitForWorkForTests()
        controller.release()
        await controller.waitForWorkForTests()

        #expect(inserter.inserted == ["hello from dictation"])
        #expect(controller.phase == .result(
            "Translation unavailable — original copied to Clipboard"))
    }

    @Test("translation is skipped when dictation translation is disabled")
    func disabledTranslationSkipsTranslator() async {
        let backend = FakeBackend(log: EventLog())
        let inserter = FakeInserter()
        let controller = DictationController(
            makeBackend: { backend },
            capture: FakeCapture(log: EventLog()),
            inserter: inserter,
            captionsActive: { false },
            translationConfiguration: { .disabled },
            translate: { _, _, _ in
                Issue.record("translator should not be called")
                return "unexpected"
            })

        controller.press()
        await controller.waitForWorkForTests()
        controller.release()
        await controller.waitForWorkForTests()

        #expect(inserter.inserted == ["hello from dictation"])
        #expect(controller.phase == .result("Copied to Clipboard"))
    }

    @Test("dictation is rejected while captions are active")
    func rejectsCaptionOverlap() {
        let controller = DictationController(
            makeBackend: { Issue.record("backend should not be created"); return FakeBackend(log: EventLog()) },
            capture: FakeCapture(log: EventLog()),
            inserter: FakeInserter(),
            captionsActive: { true })

        controller.press()

        #expect(controller.phase == .failure("Captions are already running."))
        #expect(!controller.isActive)
    }

    @Test("ready state is visible without opening the microphone")
    func readyState() {
        let phases = EventLog()
        let controller = DictationController(
            makeBackend: { Issue.record("backend should not be created"); return FakeBackend(log: phases) },
            capture: FakeCapture(log: phases),
            inserter: FakeInserter(),
            captionsActive: { false },
            onPhaseChanged: { phases.values.append(String(describing: $0)) })

        controller.markReady()

        #expect(controller.phase == .ready)
        #expect(!controller.isActive)
        #expect(phases.values == ["ready"])
    }

    @Test("input monitoring wait is visible without opening the microphone")
    func inputMonitoringWaitState() {
        let phases = EventLog()
        let controller = DictationController(
            makeBackend: { Issue.record("backend should not be created"); return FakeBackend(log: phases) },
            capture: FakeCapture(log: phases),
            inserter: FakeInserter(),
            captionsActive: { false },
            onPhaseChanged: { phases.values.append(String(describing: $0)) })

        controller.markWaitingForInputMonitoring()

        #expect(controller.phase == .waitingForInputMonitoring)
        #expect(!controller.isActive)
        #expect(phases.values == ["waitingForInputMonitoring"])
    }

    @Test("completed feedback returns to the ready state for the next dictation")
    func feedbackReturnsToReady() async {
        let controller = DictationController(
            makeBackend: { FakeBackend(log: EventLog()) },
            capture: FakeCapture(log: EventLog()),
            inserter: FakeInserter(),
            captionsActive: { false })

        controller.press()
        await controller.waitForWorkForTests()
        controller.release()
        await controller.waitForWorkForTests()

        #expect(controller.phase == .result("Copied to Clipboard"))
        controller.markReadyAfterFeedback()
        #expect(controller.phase == .ready)
    }

    @Test("cancellation stops an active microphone session")
    func cancellationTeardown() async {
        let log = EventLog()
        let backend = FakeBackend(log: log)
        let capture = FakeCapture(log: log)
        let controller = DictationController(
            makeBackend: { backend },
            capture: capture,
            inserter: FakeInserter(),
            captionsActive: { false })

        controller.press()
        await controller.waitForWorkForTests()
        controller.cancel()
        await controller.waitForWorkForTests()

        #expect(capture.stopped)
        #expect(!controller.isActive)
    }

    @Test("preparation emits preparing then ready without opening the microphone")
    func preparationProducesTruthfulReadyState() async {
        let backend = FakeBackend(log: EventLog())
        let capture = FakeCapture(log: EventLog())
        var phases: [DictationPhase] = []
        let controller = DictationController(
            makeBackend: { backend },
            capture: capture,
            inserter: FakeInserter(),
            captionsActive: { false },
            onPhaseChanged: { phases.append($0) })

        controller.prepare()
        await controller.waitForWorkForTests()

        #expect(backend.prepares == 1)
        #expect(!capture.started)
        #expect(phases == [.preparing, .ready])
    }

    @Test("two presses reuse one prepared backend")
    func preparedBackendIsReused() async {
        let backend = FakeBackend(log: EventLog())
        let controller = DictationController(
            makeBackend: { backend },
            capture: FakeCapture(log: EventLog()),
            inserter: FakeInserter(),
            captionsActive: { false })

        controller.prepare()
        await controller.waitForWorkForTests()
        controller.press()
        await controller.waitForWorkForTests()
        controller.release()
        await controller.waitForWorkForTests()
        controller.press()
        await controller.waitForWorkForTests()
        controller.release()
        await controller.waitForWorkForTests()

        #expect(backend.prepares == 1)
        #expect(backend.starts == 2)
        #expect(backend.stops == 2)
    }

    @Test("preparation waits for cancellation cleanup")
    func preparationWaitsForCancellationCleanup() async {
        var backends: [FakeBackend] = []
        let controller = DictationController(
            makeBackend: {
                let backend = FakeBackend(log: EventLog())
                backends.append(backend)
                return backend
            },
            capture: FakeCapture(log: EventLog()),
            inserter: FakeInserter(),
            captionsActive: { false })

        controller.prepare()
        await controller.waitForWorkForTests()
        let first = backends[0]
        first.blockStop = true
        controller.cancel()
        for _ in 0..<100 where first.stops == 0 { await Task.yield() }

        controller.prepare()
        for _ in 0..<20 { await Task.yield() }
        #expect(backends.count == 1)

        first.finishStop()
        await controller.waitForWorkForTests()

        #expect(backends.count == 2)
        #expect(backends[1].prepares == 1)
    }

    @Test("a press before readiness waits and starts only after preparation")
    func earlyPressWaitsForPreparation() async {
        let backend = FakeBackend(log: EventLog())
        backend.blockPreparation = true
        let capture = FakeCapture(log: EventLog())
        let controller = DictationController(
            makeBackend: { backend },
            capture: capture,
            inserter: FakeInserter(),
            captionsActive: { false })

        controller.prepare()
        for _ in 0..<100 where backend.prepares == 0 {
            await Task.yield()
        }
        controller.press()
        #expect(controller.phase == .starting)
        #expect(!capture.started)

        backend.finishPreparation()
        await controller.waitForWorkForTests()

        #expect(capture.started)
        #expect(controller.phase == .dictating)
    }

    @Test("release before readiness never opens the microphone")
    func releaseBeforeReadinessDoesNotStartCapture() async {
        let backend = FakeBackend(log: EventLog())
        backend.blockPreparation = true
        let capture = FakeCapture(log: EventLog())
        let inserter = FakeInserter()
        let controller = DictationController(
            makeBackend: { backend },
            capture: capture,
            inserter: inserter,
            captionsActive: { false })

        controller.press()
        for _ in 0..<100 where backend.prepares == 0 {
            await Task.yield()
        }
        controller.release()
        backend.finishPreparation()
        await controller.waitForWorkForTests()

        #expect(!capture.started)
        #expect(inserter.inserted.isEmpty)
        #expect(!controller.isActive)
    }

    @Test("invalidating preparation releases the cached backend")
    func invalidationAllowsFreshPreparation() async {
        var backends: [FakeBackend] = []
        let controller = DictationController(
            makeBackend: {
                let backend = FakeBackend(log: EventLog())
                backends.append(backend)
                return backend
            },
            capture: FakeCapture(log: EventLog()),
            inserter: FakeInserter(),
            captionsActive: { false })

        controller.prepare()
        await controller.waitForWorkForTests()
        await controller.invalidatePreparedBackend()
        controller.prepare()
        await controller.waitForWorkForTests()

        #expect(backends.count == 2)
        #expect(backends[0].stops == 1)
        #expect(backends[1].prepares == 1)
    }
}
