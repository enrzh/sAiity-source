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

    final class FakeSegmentedBackend: TranscriptionBackend, DictationSegmentTranscriber, @unchecked Sendable {
        let log: EventLog
        let format = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!
        let name = "Segmented test backend"
        var starts = 0
        var prepares = 0
        var receivedSamples: [Float] = []
        var receivedRegions: [DictationSpeechRegion] = []
        var result = DictationTranscriptionResult(regions: [])
        var transcriptionStarted = false
        var blockTranscription = false
        /// Held open so a test can keep a session genuinely mid-transcription,
        /// which is the window a second press used to fall into.
        var transcriptionGate: ContinuationGate?
        var transcriptionError: Error?
        var onChunk: (@Sendable (TranscriptChunk) -> Void)?
        var streamingResult: String?
        var finishDictationCalls = 0

        init(log: EventLog) { self.log = log }

        var inputFormat: AVAudioFormat? { get async { format } }
        func prepare(locale: Locale, progress: @escaping @Sendable (String) -> Void) async throws {
            prepares += 1
        }
        func start(onChunk: @escaping @Sendable (TranscriptChunk) -> Void) async throws {
            starts += 1
            self.onChunk = onChunk
        }
        func feed(_ buffer: AVAudioPCMBuffer) {}
        func stop() async {}
        func release() async {}
        func finishDictation() async -> String? {
            finishDictationCalls += 1
            return streamingResult
        }
        func emitDraft(_ chunk: TranscriptChunk) { onChunk?(chunk) }
        func transcribeDictation(samples: [Float],
                                 regions: [DictationSpeechRegion]) async throws -> DictationTranscriptionResult {
            receivedSamples = samples
            receivedRegions = regions
            transcriptionStarted = true
            if let transcriptionGate { await transcriptionGate.wait() }
            if let transcriptionError { throw transcriptionError }
            if blockTranscription {
                try await Task.sleep(nanoseconds: 60_000_000_000)
            }
            return result
        }
        func detectedLanguage() async -> String? { nil }
    }

    /// A gate a test opens by hand, so work can be held open without a sleep.
    final class ContinuationGate: @unchecked Sendable {
        private var continuation: CheckedContinuation<Void, Never>?
        private(set) var entered = false

        func wait() async {
            entered = true
            await withCheckedContinuation { continuation in
                self.continuation = continuation
            }
        }

        func open() {
            continuation?.resume()
            continuation = nil
        }
    }

    /// Stands in for the real pool, and records what the controller asked of it.
    /// A shared backend is leased exclusively, so "who released what, and with
    /// which intent" is the only way to see a lease being taken away from a
    /// session that still owns it.
    @MainActor
    final class RecordingProvider: ASRBackendProvider {
        struct Release {
            let discard: Bool
            /// True while this provider still considered the backend leased —
            /// i.e. the release came from a session that did not own it.
            let whileLeased: Bool
        }

        let backend: TranscriptionBackend
        var acquireError: (any Error)?
        var prepareError: (any Error)?
        private(set) var prepareCalls = 0
        private(set) var acquireCalls = 0
        private(set) var invalidateCalls = 0
        private(set) var releases: [Release] = []
        /// A lease this provider hands out to somebody else, to model the
        /// "someone else is transcribing right now" state.
        var foreignLease = false

        init(backend: TranscriptionBackend) { self.backend = backend }

        func prepare(locale: Locale,
                     progress: @escaping @Sendable (String) -> Void) async throws {
            prepareCalls += 1
            if let prepareError { throw prepareError }
        }

        func acquire(locale: Locale,
                     progress: @escaping @Sendable (String) -> Void) async throws -> TranscriptionBackend {
            acquireCalls += 1
            if let acquireError { throw acquireError }
            return backend
        }

        func release(_ backend: TranscriptionBackend, discard: Bool) async {
            releases.append(Release(discard: discard, whileLeased: foreignLease))
            if !discard { foreignLease = false }
        }

        func invalidate() async { invalidateCalls += 1 }
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
        var snapshot: DictationResultSnapshot?
        let controller = DictationController(
            makeBackend: { backend },
            capture: capture,
            inserter: inserter,
            captionsActive: { false },
            onResult: { snapshot = $0 })

        controller.press()
        await controller.waitForWorkForTests()
        controller.release()
        await controller.waitForWorkForTests()

        #expect(log.values == ["capture.stop", "backend.finishDictation"])
        #expect(inserter.inserted == ["hello from dictation"])
        #expect(snapshot == DictationResultSnapshot(rawText: "hello from dictation",
                                                     outputText: "hello from dictation",
                                                     wasCleaned: false,
                                                     wasTranslated: false,
                                                     languageMetadata: .init(regions: [
                                                         .init(text: "hello from dictation", language: "en")
                                                     ])))
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
        let backend = FakeBackend(log: EventLog())
        let capture = FakeCapture(log: EventLog())
        let controller = DictationController(
            makeBackend: { backend }, capture: capture,
            inserter: FakeInserter(), captionsActive: { false },
            dictationUsesWhisper: { true }, whisperIsReady: { false })
        controller.prepare(); await controller.waitForWorkForTests()
        #expect(!capture.started)
        #expect(backend.prepares == 0)
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
        var snapshot: DictationResultSnapshot?
        var issues: [String] = []
        let controller = DictationController(
            makeBackend: { backend },
            capture: FakeCapture(log: EventLog()),
            inserter: inserter,
            captionsActive: { false },
            cleanupConfiguration: { DictationCleanupConfiguration(enabled: true) },
            cleanup: { _, _ in "Send the project report to another address on 2026-08-31 today." },
            onResult: { snapshot = $0 },
            onIssue: { operation, _ in issues.append(operation) })

        controller.press()
        await controller.waitForWorkForTests()
        controller.release()
        await controller.waitForWorkForTests()

        #expect(inserter.inserted == [input])
        #expect(snapshot?.cleanupUnavailable == true)
        #expect(issues == ["dictation.cleanup"])
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

    @Test("deferred segmented dictation keeps the backend idle until release")
    func deferredSegmentedBackendTranscribesOnRelease() async {
        let backend = FakeSegmentedBackend(log: EventLog())
        backend.result = DictationTranscriptionResult(regions: [
            DictationRegionTranscript(text: "Ich denke", language: "de"),
            DictationRegionTranscript(text: "we should ship", language: "en"),
        ])
        let capture = FakeCapture(log: EventLog())
        capture.samples = [0.4, 0.4, 0.4]
        let inserter = FakeInserter()
        let controller = DictationController(
            makeBackend: { backend },
            capture: capture,
            inserter: inserter,
            captionsActive: { false })

        controller.press()
        await controller.waitForWorkForTests()
        #expect(backend.starts == 0)
        #expect(backend.prepares == 1)

        controller.release()
        await controller.waitForWorkForTests()

        #expect(backend.transcriptionStarted)
        #expect(backend.receivedSamples == [0.4, 0.4, 0.4])
        #expect(backend.receivedRegions.count == 1)
        #expect(inserter.inserted == ["Ich denke we should ship"])
    }

    @Test("fast streaming dictation flushes the warm session instead of replaying audio")
    func fastStreamingDictationUsesDraftSession() async {
        let backend = FakeSegmentedBackend(log: EventLog())
        backend.streamingResult = "Hallo world"
        let capture = FakeCapture(log: EventLog())
        capture.samples = [0.4, 0.4, 0.4]
        let inserter = FakeInserter()
        var draft = ""
        let controller = DictationController(
            makeBackend: { backend },
            capture: capture,
            inserter: inserter,
            captionsActive: { false },
            onDraft: { draft = $0 },
            dictationStreamingDraftEnabled: { true })

        controller.press()
        await controller.waitForWorkForTests()
        #expect(backend.starts == 1)
        backend.emitDraft(.init(text: "Hallo", isFinal: true))
        backend.emitDraft(.init(text: "world", isFinal: false))
        await Task.yield()

        controller.release()
        await controller.waitForWorkForTests()

        #expect(draft == "Hallo world")
        #expect(backend.finishDictationCalls == 1)
        #expect(!backend.transcriptionStarted)
        #expect(inserter.inserted == ["Hallo world"])
    }

    @Test("controller cancellation during segmented transcription drops the result")
    func cancellationDuringControllerSegmentation() async {
        let backend = FakeSegmentedBackend(log: EventLog())
        backend.blockTranscription = true
        let capture = FakeCapture(log: EventLog())
        capture.samples = [0.4, 0.4]
        let inserter = FakeInserter()
        let controller = DictationController(
            makeBackend: { backend },
            capture: capture,
            inserter: inserter,
            captionsActive: { false })

        controller.press()
        await controller.waitForWorkForTests()
        controller.release()
        for _ in 0..<100 where !backend.transcriptionStarted { await Task.yield() }
        controller.cancel()
        await controller.waitForWorkForTests()

        #expect(inserter.inserted.isEmpty)
        #expect(!controller.isActive)
    }

    @Test("cleaned mixed regions are the source of independent translation")
    func cleanedRegionsReachMixedTranslation() async {
        let backend = FakeBackend(log: EventLog())
        backend.authoritativeResult = "Ich denke we should ship"
        let inserter = FakeInserter()
        var translatedRegions: [[String]] = []
        let cleaned = DictationTranscriptionResult(regions: [
            DictationRegionTranscript(text: "Ich denke", language: "de"),
            DictationRegionTranscript(text: "we should ship today", language: "en"),
        ])
        let controller = DictationController(
            makeBackend: { backend },
            capture: FakeCapture(log: EventLog()),
            inserter: inserter,
            captionsActive: { false },
            translationConfiguration: { DictationTranslationConfiguration(enabled: true, target: "de") },
            detailedTranslate: { _, transcription, _ in
                translatedRegions.append(transcription.regions.map(\.text))
                return "Ich denke wir sollten heute versenden"
            },
            cleanupConfiguration: { DictationCleanupConfiguration(enabled: true) },
            detailedCleanup: { _ in cleaned })

        controller.press()
        await controller.waitForWorkForTests()
        controller.release()
        await controller.waitForWorkForTests()

        #expect(translatedRegions == [["Ich denke", "we should ship today"]])
        #expect(inserter.inserted == ["Ich denke wir sollten heute versenden"])
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
        var issues: [String] = []
        let controller = DictationController(
            makeBackend: { backend },
            capture: FakeCapture(log: EventLog()),
            inserter: inserter,
            captionsActive: { false },
            translationConfiguration: {
                DictationTranslationConfiguration(enabled: true, target: "de")
            },
            translate: { _, _, _ in nil },
            onIssue: { operation, _ in issues.append(operation) })

        controller.press()
        await controller.waitForWorkForTests()
        controller.release()
        await controller.waitForWorkForTests()

        #expect(inserter.inserted == ["hello from dictation"])
        #expect(controller.phase == .result(
            "Translation unavailable — original copied to Clipboard"))
        #expect(issues == ["dictation.translation"])
    }

    @Test("transcription failure is visible to diagnostics")
    func transcriptionFailureReportsIssue() async {
        let backend = FakeSegmentedBackend(log: EventLog())
        backend.transcriptionError = BackendError.notPrepared
        var issues: [String] = []
        let controller = DictationController(
            makeBackend: { backend },
            capture: FakeCapture(log: EventLog()),
            inserter: FakeInserter(),
            captionsActive: { false },
            onIssue: { operation, reason in issues.append("\(operation):\(reason)") })

        controller.press()
        await controller.waitForWorkForTests()
        controller.release()
        await controller.waitForWorkForTests()

        #expect(issues.count == 1)
        #expect(issues[0].hasPrefix("dictation.transcription:"))
        #expect(controller.phase == .failure(BackendError.notPrepared.localizedDescription))
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

    @Test("a press during transcription neither starts a session nor discards the live backend")
    func pressWhilePreviousReleaseIsTranscribingIsRefused() async {
        let gate = ContinuationGate()
        let backend = FakeSegmentedBackend(log: EventLog())
        backend.result = DictationTranscriptionResult(regions: [
            DictationRegionTranscript(text: "still speaking", language: "en"),
        ])
        backend.transcriptionGate = gate
        let provider = RecordingProvider(backend: backend)
        let capture = FakeCapture(log: EventLog())
        capture.samples = [0.4]
        let inserter = FakeInserter()
        let controller = DictationController(
            backendProvider: provider,
            capture: capture,
            inserter: inserter,
            captionsActive: { false })

        controller.press()
        await controller.waitForWorkForTests()
        controller.release()
        for _ in 0..<200 where !gate.entered { await Task.yield() }
        #expect(gate.entered)
        #expect(controller.phase == .transcribing)
        #expect(controller.isFinishing)

        // The microphone is closed by now, so nothing in the old state machine
        // stopped a second press. It used to start a session, fail to take the
        // exclusively-leased backend, and discard it on the way out — ending the
        // utterance the user was in the middle of saying.
        provider.foreignLease = true
        controller.press()
        for _ in 0..<50 { await Task.yield() }

        #expect(controller.phase == .transcribing)
        #expect(controller.isActive == false)
        #expect(provider.acquireCalls == 1,
                "the refused press tried to take the shared backend again")
        #expect(!provider.releases.contains { $0.whileLeased && $0.discard },
                "a live lease was discarded by a session that did not own it")

        gate.open()
        await controller.waitForWorkForTests()

        #expect(inserter.inserted == ["still speaking"])
        #expect(provider.releases.count == 1)
        #expect(provider.releases[0].discard == false)
    }

    @Test("a start that fails without acquiring leaves a shared lease untouched")
    func failedStartDoesNotDisturbALeaseItDoesNotOwn() async {
        let backend = FakeSegmentedBackend(log: EventLog())
        let provider = RecordingProvider(backend: backend)
        provider.acquireError = ASRBackendPool.Error.busy
        // Somebody else is mid-session with the one shared backend.
        provider.foreignLease = true
        var issues: [String] = []
        let controller = DictationController(
            backendProvider: provider,
            capture: FakeCapture(log: EventLog()),
            inserter: FakeInserter(),
            captionsActive: { false },
            onIssue: { operation, reason in issues.append("\(operation): \(reason)") })

        controller.press()
        await controller.waitForWorkForTests()

        #expect(provider.acquireCalls == 1)
        #expect(provider.releases.isEmpty,
                "a start that acquired nothing still released somebody's backend")
        #expect(provider.invalidateCalls == 0,
                "a start that acquired nothing still invalidated the shared pool")
        #expect(!controller.isActive)
        #expect(issues.contains { $0.hasPrefix("dictation.start") })
        #expect(controller.phase == .failure("Speech recognition is already in use."))
    }
}
