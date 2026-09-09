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
        var stopCalls = 0
        var takeCalls = 0
        var limitHandler: (@Sendable () -> Void)?
        var waveformHandler: (@Sendable ([Float]) -> Void)?

        init(log: EventLog) { self.log = log }

        func start(targetFormat: AVAudioFormat,
                   onBuffer: @escaping @Sendable (AVAudioPCMBuffer) -> Void) throws {
            started = true
        }

        func stop() {
            stopCalls += 1
            stopped = true
            log.values.append("capture.stop")
        }

        var samples: [Float] = []
        func takeCollectedSamples() -> [Float] {
            takeCalls += 1
            defer { samples.removeAll() }
            return samples
        }
        func setLimitHandler(_ handler: (@Sendable () -> Void)?) { limitHandler = handler }
        func setWaveformHandler(_ handler: (@Sendable ([Float]) -> Void)?) { waveformHandler = handler }

        func emitWaveform(_ values: [Float]) { waveformHandler?(values) }
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
        var authoritativeResult: String? = "hello from dictation"
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

        #expect(log.values == ["capture.stop", "backend.finishDictation"])
        #expect(inserter.inserted == ["hello from dictation"])
        #expect(controller.phase == .result("Copied to Clipboard"))
    }

    @Test("Whisper dictation transcribes only after capture release")
    func whisperTranscribesAfterCaptureRelease() async {
        let log = EventLog()
        let capture = FakeCapture(log: log)
        let inserter = FakeInserter()
        let controller = DictationController(
            makeBackend: { Issue.record("streaming backend must not be created"); return FakeBackend(log: log) },
            capture: capture,
            inserter: inserter,
            captionsActive: { false },
            dictationUsesWhisper: { true },
            transcribeWhisper: { samples, _ in
                log.values.append("whisper.transcribe")
                #expect(samples == [[1, 2, 3]])
                return "whisper final"
            })

        capture.samples = [1, 2, 3]

        controller.markReady()
        controller.press()
        await controller.waitForWorkForTests()
        controller.release()
        await controller.waitForWorkForTests()

        #expect(log.values == ["capture.stop", "whisper.transcribe"])
        #expect(inserter.inserted == ["whisper final"])
        #expect(capture.takeCalls == 1)
    }

    @Test("Whisper limit finishes once and drains samples")
    func whisperLimitFinishesOnce() async {
        let capture = FakeCapture(log: EventLog())
        capture.samples = [4, 5]
        var transcriptions = 0
        let controller = DictationController(
            makeBackend: { FakeBackend(log: EventLog()) }, capture: capture,
            inserter: FakeInserter(), captionsActive: { false },
            dictationUsesWhisper: { true },
            transcribeWhisper: { samples, _ in
                transcriptions += 1
                #expect(samples == [[4, 5]])
                return "limited"
            })
        controller.markReady(); controller.press(); await controller.waitForWorkForTests()
        for _ in 0..<100 where capture.limitHandler == nil { await Task.yield() }
        capture.limitHandler?(); capture.limitHandler?()
        for _ in 0..<100 { await Task.yield() }
        await controller.waitForWorkForTests()
        #expect(transcriptions == 1)
        #expect(capture.stopCalls == 1)
        #expect(capture.takeCalls == 1)
    }

    @Test("Whisper cancellation drains exactly once")
    func whisperCancellationDrainsOnce() async {
        let capture = FakeCapture(log: EventLog()); capture.samples = [1]
        let controller = DictationController(
            makeBackend: { FakeBackend(log: EventLog()) }, capture: capture,
            inserter: FakeInserter(), captionsActive: { false },
            dictationUsesWhisper: { true })
        controller.markReady(); controller.press(); await controller.waitForWorkForTests()
        controller.cancel(); await controller.waitForWorkForTests()
        #expect(capture.stopCalls == 1); #expect(capture.takeCalls == 1); #expect(capture.samples.isEmpty)
    }

    @Test("Whisper format failure never starts the microphone and drains samples")
    func whisperFormatFailure() async {
        let capture = FakeCapture(log: EventLog()); capture.samples = [9]
        let controller = DictationController(
            makeBackend: { FakeBackend(log: EventLog()) }, capture: capture,
            inserter: FakeInserter(), captionsActive: { false },
            dictationUsesWhisper: { true }, audioFormatFactory: { nil })
        controller.markReady(); controller.press(); await controller.waitForWorkForTests()
        #expect(!capture.started); #expect(capture.takeCalls == 1); #expect(capture.samples.isEmpty)
        #expect(controller.phase != .dictating)
    }

    @Test("ordinary preparation never prepares selected Whisper")
    func ordinaryPreparationDoesNotPrepareWhisper() async {
        let capture = FakeCapture(log: EventLog())
        let controller = DictationController(
            makeBackend: { FakeBackend(log: EventLog()) }, capture: capture,
            inserter: FakeInserter(), captionsActive: { false },
            dictationUsesWhisper: { true }, whisperIsReady: { false })
        controller.prepare(); await controller.waitForWorkForTests()
        #expect(!capture.started)
    }

    @Test("Whisper press before explicit readiness fails without preparing")
    func whisperPressBeforeReadinessDoesNotAutoPrepare() async {
        let controller = DictationController(
            makeBackend: { FakeBackend(log: EventLog()) }, capture: FakeCapture(log: EventLog()),
            inserter: FakeInserter(), captionsActive: { false },
            dictationUsesWhisper: { true }, whisperIsReady: { false })
        controller.press(); await controller.waitForWorkForTests()
        #expect(controller.phase == .failure("Not ready"))
    }

    @Test("a delayed limit handler from an old session cannot finish the new session")
    func oldSessionLimitCannotFinishNewSession() async {
        let capture = FakeCapture(log: EventLog())
        let controller = DictationController(
            makeBackend: { FakeBackend(log: EventLog()) }, capture: capture,
            inserter: FakeInserter(), captionsActive: { false },
            dictationUsesWhisper: { true })
        controller.markReady(); controller.press(); await controller.waitForWorkForTests()
        for _ in 0..<100 where capture.limitHandler == nil { await Task.yield() }
        let oldHandler = capture.limitHandler
        controller.cancel(); await controller.waitForWorkForTests()
        controller.markReady(); controller.press(); await controller.waitForWorkForTests()
        oldHandler?(); await Task.yield(); await controller.waitForWorkForTests()
        #expect(controller.phase == .dictating)
    }

    @Test("Whisper cancellation during transcription does not drain samples twice")
    func whisperCancellationDuringTranscriptionDrainsOnce() async {
        let capture = FakeCapture(log: EventLog()); capture.samples = [7]
        var transcriptionContinuation: CheckedContinuation<String?, Never>?
        let controller = DictationController(
            makeBackend: { FakeBackend(log: EventLog()) }, capture: capture,
            inserter: FakeInserter(), captionsActive: { false },
            dictationUsesWhisper: { true },
            transcribeWhisper: { _, _ in
                _ = await withCheckedContinuation { continuation in
                    transcriptionContinuation = continuation
                }
                return nil
            })
        controller.markReady(); controller.press(); await controller.waitForWorkForTests()
        controller.release()
        while transcriptionContinuation == nil {
            await Task.yield()
        }
        controller.cancel()
        transcriptionContinuation?.resume(returning: nil)
        await controller.waitForWorkForTests()
        #expect(capture.stopCalls == 1)
        #expect(capture.takeCalls == 1)
        #expect(capture.samples.isEmpty)
    }

    @Test("Whisper transcription failure leaves capture samples drained")
    func whisperTranscriptionFailureDrainsSamples() async {
        let capture = FakeCapture(log: EventLog()); capture.samples = [8]
        let controller = DictationController(
            makeBackend: { FakeBackend(log: EventLog()) }, capture: capture,
            inserter: FakeInserter(), captionsActive: { false },
            dictationUsesWhisper: { true },
            transcribeWhisper: { _, _ in throw BackendError.notPrepared })
        controller.markReady(); controller.press(); await controller.waitForWorkForTests()
        controller.release(); await controller.waitForWorkForTests()
        #expect(capture.stopCalls == 1)
        #expect(capture.takeCalls == 1)
        #expect(capture.samples.isEmpty)
        #expect(controller.phase != .dictating)
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

    @Test("an empty authoritative completion does not use rolling finals")
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
        #expect(inserter.inserted.isEmpty)
        #expect(controller.phase == .result("No speech detected"))
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

    @Test("dictation forwards live microphone levels to its waveform")
    func forwardsWaveformLevels() async {
        let capture = FakeCapture(log: EventLog())
        final class WaveformBox: @unchecked Sendable {
            var levels: [[Float]] = []
        }
        let box = WaveformBox()
        let controller = DictationController(
            makeBackend: { FakeBackend(log: EventLog()) },
            capture: capture,
            inserter: FakeInserter(),
            captionsActive: { false },
            onWaveform: { box.levels.append($0) })

        controller.markReady()
        controller.press()
        await controller.waitForWorkForTests()
        capture.emitWaveform([0.1, 0.8])
        #expect(box.levels == [[0.1, 0.8]])
        controller.cancel()
        await controller.waitForWorkForTests()
    }

    @Test("cleanup falls back when the model drops a protected token")
    func cleanupPreservesOriginalWhenProtectedTokenIsDropped() async {
        let input = "Send the project report to team@example.com on 2026-08-31 today."
        let backend = FakeBackend(log: EventLog())
        backend.authoritativeResult = input
        let inserter = FakeInserter()
        let controller = DictationController(
            makeBackend: { backend },
            capture: FakeCapture(log: EventLog()),
            inserter: inserter,
            captionsActive: { false },
            cleanupConfiguration: { DictationCleanupConfiguration(enabled: true) },
            cleanup: { _, _ in "Send the project report to another address on 2026-08-31 today." })

        controller.press()
        await controller.waitForWorkForTests()
        controller.release()
        await controller.waitForWorkForTests()

        #expect(inserter.inserted == [input])
    }

    @Test("cleanup never translates when dictation translation is disabled")
    func cleanupCannotReplaceTranscriptWithAnotherLanguage() async {
        let input = "Please send the revised contract to the legal team before Friday morning."
        let backend = FakeBackend(log: EventLog())
        backend.authoritativeResult = input
        let inserter = FakeInserter()
        let controller = DictationController(
            makeBackend: { backend },
            capture: FakeCapture(log: EventLog()),
            inserter: inserter,
            captionsActive: { false },
            translationConfiguration: { .disabled },
            cleanupConfiguration: { DictationCleanupConfiguration(enabled: true) },
            cleanup: { _, _ in
                "Bitte senden Sie den überarbeiteten Vertrag vor Freitagmorgen an das Rechtsteam."
            })

        controller.press()
        await controller.waitForWorkForTests()
        controller.release()
        await controller.waitForWorkForTests()

        #expect(inserter.inserted == [input])
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
        #expect(backend.stops == 0)
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
