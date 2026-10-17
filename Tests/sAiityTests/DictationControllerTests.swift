import AVFoundation
import Foundation
import Testing

@testable import sAiity

@MainActor
@Suite struct DictationControllerTests {
    @Test("A cold prepare returning after release deadline never starts preview inference or inserts output")
    func lateColdPreparationDoesNotStartRecognition() async throws {
        let backend = FakeBackend(log: EventLog())
        backend.blockPreparation = true
        let capture = FakeCapture(log: EventLog()), inserter = FakeInserter()
        let controller = DictationController(makeBackend: { backend }, capture: capture, inserter: inserter,
            captionsActive: { false }, cleanupConfiguration: { .disabled }, dictationStreamingDraftEnabled: { true })
        controller.press()
        let waitingUntil = ContinuousClock.now + .seconds(2)
        while backend.preparationContinuation == nil, ContinuousClock.now < waitingUntil { await Task.yield() }
        try #require(backend.preparationContinuation != nil)
        capture.samples = [0.2, 0.3]
        LocalGeneration.$deadline.withValue(.now + .milliseconds(5)) { controller.release() }
        try await Task.sleep(for: .milliseconds(15))
        backend.finishPreparation()
        await controller.waitForWorkForTests()
        #expect(capture.startCalls == 1 && capture.stopCalls == 1)
        #expect(backend.starts == 0 && backend.finishDictationCalls == 0)
        #expect(inserter.inserted.isEmpty && !controller.isBusy)
        if case .failure = controller.phase {} else { Issue.record("Late preparation needs an explicit retryable failure") }
    }
    @Test("Native Paste dispatch uses truthful delivery wording without claiming visible insertion")
    func deliveryCopyDescribesPasteDispatch() async {
        let backend = FakeBackend(log: EventLog()), inserter = FakeInserter()
        inserter.outcome = .insertedAndCopied
        let controller = DictationController(makeBackend: { backend }, capture: FakeCapture(log: EventLog()),
            inserter: inserter, captionsActive: { false }, cleanupConfiguration: { .disabled })
        controller.press()
        await controller.waitForWorkForTests()
        controller.release()
        await controller.waitForWorkForTests()
        #expect(controller.phase == .result(String(localized: "Copied — paste requested")))
    }
    @Test("Delayed native preview and forced-cut decoding preserve new tail PCM through release", arguments: [false, true])
    func delayedForcedCutPreservesCompleteAudio(preview: Bool) async throws {
        let engine = StreamingASRBackendTests.GatedEngine(finalText: { pcm in
            pcm.contains(0.4) ? "shared ending" : "source begins shared"
        })
        defer { engine.releaseProcess() }
        let backend = StreamingASRBackend(name: "Synthetic delayed recognizer", engine: engine)
        let capture = FakeCapture(log: EventLog()), inserter = FakeInserter()
        let controller = DictationController(makeBackend: { backend }, capture: capture, inserter: inserter,
            captionsActive: { false }, cleanupConfiguration: { .disabled }, dictationStreamingDraftEnabled: { preview })
        controller.press()
        await controller.waitForWorkForTests()
        let initial = Array(repeating: Float(0.1), count: 3_200)
        let prefix = initial + Array(repeating: Float(0.2), count: 174_400)
        if preview {
            capture.samples = initial
            capture.onBuffer?(CaptionASRPerformanceTests.audioBufferForDictation(initial[...]))
            let deadline = ContinuousClock.now + .seconds(2)
            while !engine.processStarted, ContinuousClock.now < deadline { await Task.yield() }
            try #require(engine.processStarted)
        }
        capture.samples = prefix
        capture.onBuffer?(CaptionASRPerformanceTests.audioBufferForDictation(prefix[initial.count...]))
        let deadline = ContinuousClock.now + .seconds(2)
        while (preview ? backend.acceptingAudioForTests : !engine.processStarted), ContinuousClock.now < deadline {
            await Task.yield()
        }
        #expect(!preview || !backend.acceptingAudioForTests)
        let full = prefix + Array(repeating: Float(0.4), count: 16_000)
        capture.samples = full
        controller.release()
        #expect(capture.stopped && inserter.inserted.isEmpty)
        #expect(engine.maximumInFlight == 1)
        engine.releaseProcess()
        await controller.waitForWorkForTests()
        let regions = SpeechRegionSegmenter.default.segment(full, sampleRate: 16_000)
        #expect(regions.first?.isForced == true)
        #expect(Array(engine.inputs.suffix(regions.count)) == regions.map { Array(full[$0.audioRange]) })
        #expect(controller.completedSampleRangesForTests == regions.map(\.coveredRange))
        #expect(inserter.inserted == ["source begins shared ending"])
        #expect(engine.maximumInFlight == 1 && capture.takeCalls == 1)
        await controller.invalidatePreparedBackend()
    }

    @Test("An incremental decode that outlives release deadline cannot start later regions or leave the run busy")
    func releaseDeadlineReachesExistingIncrementalTask() async throws {
        let gate = ContinuationGate(), backend = FakeSegmentedBackend(log: EventLog())
        backend.transcriptionGate = gate
        backend.result = .init(text: "synthetic prefix", language: "en")
        let capture = FakeCapture(log: EventLog()), inserter = FakeInserter()
        let controller = DictationController(makeBackend: { backend }, capture: capture, inserter: inserter,
            captionsActive: { false }, cleanupConfiguration: { .disabled })
        controller.press()
        await controller.waitForWorkForTests()
        capture.samples = Array(repeating: 0.2, count: 16_000 * 31)
        capture.onBuffer?(CaptionASRPerformanceTests.audioBufferForDictation(capture.samples.prefix(1)))
        let waitingUntil = ContinuousClock.now + .seconds(2)
        while !gate.entered, ContinuousClock.now < waitingUntil { await Task.yield() }
        try #require(gate.entered)
        LocalGeneration.$deadline.withValue(.now + .milliseconds(5)) { controller.release() }
        try await Task.sleep(for: .milliseconds(15))
        backend.transcriptionGate = nil
        gate.open()
        await controller.waitForWorkForTests()
        #expect(backend.regionCalls.count == 1)
        #expect(inserter.inserted.isEmpty)
        #expect(!controller.isBusy && !controller.isActive)
        if case .failure = controller.phase {} else { Issue.record("Deadline exhaustion needs an explicit retryable failure") }
    }
    @Test("dictation corrects a stale Chinese tag before translating coherent Japanese")
    func pql3JapaneseDelivery() async throws {
        let original = "日本語の字幕を確認してください。"
        let translated = "Please check the Japanese subtitles."
        let backend = FakeBackend(log: EventLog())
        backend.authoritativeResult = original
        backend.detectedLanguageResult = "zh"
        let engine = TranslationProcedureTests.Engine()
        engine.outputs = [translated]
        let inserter = FakeInserter()
        let controller = DictationController(makeBackend: { backend }, capture: FakeCapture(log: EventLog()),
            inserter: inserter, captionsActive: { false },
            translationConfiguration: { .init(enabled: true, target: "en") },
            detailedTranslate: { _, result, target in
                try? await TranslationProcedure.translate(result.translationRuns.map {
                    .init(text: $0.text, source: $0.language ?? "auto")
                }, to: target, engine: engine)
            }, cleanupConfiguration: { .disabled })
        controller.press()
        await controller.waitForWorkForTests()
        controller.release()
        await controller.waitForWorkForTests()
        #expect(engine.inputs == [.init(text: original, source: "ja")])
        #expect(inserter.inserted == [translated])
        #expect(backend.finishDictationCalls == 1)
    }

    final class EventLog {
        var values: [String] = []
    }

    final class FakeCapture: DictationAudioCapture {
        let log: EventLog
        var started = false
        var stopped = false
        var stopCalls = 0
        var takeCalls = 0
        var startCalls = 0
        var onBuffer: (@Sendable (AVAudioPCMBuffer) -> Void)?
        var limitHandler: (@Sendable () -> Void)?
        var waveformHandler: (@Sendable ([Float]) -> Void)?

        init(log: EventLog) { self.log = log }

        func start(targetFormat: AVAudioFormat,
                   onBuffer: @escaping @Sendable (AVAudioPCMBuffer) -> Void) throws {
            started = true
            startCalls += 1
            self.onBuffer = onBuffer
        }

        func stop() {
            stopCalls += 1
            stopped = true
            log.values.append("capture.stop")
        }

        var samples: [Float] = []
        var collectedSamples: [[Float]] { samples.isEmpty ? [] : [samples] }
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
        var fedSamples: [Float] = []
        var failureHandler: (@Sendable (String) -> Void)?

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
        func feed(_ buffer: AVAudioPCMBuffer) {
            if let channel = buffer.floatChannelData?[0] {
                fedSamples += Array(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
            }
        }
        func setFailureHandler(_ handler: (@Sendable (String) -> Void)?) { failureHandler = handler }
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
        var regionCalls: [[DictationSpeechRegion]] = []
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
            regionCalls.append(regions)
            transcriptionStarted = true
            let response = result
            if let transcriptionGate { await transcriptionGate.wait() }
            if let transcriptionError { throw transcriptionError }
            if blockTranscription {
                try await Task.sleep(nanoseconds: 60_000_000_000)
            }
            return response
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
        var focus = DictationFocusToken(processIdentifier: 1, bundleIdentifier: "test.original")
        var expectedFocus: DictationFocusToken?
        var outcome: TextInsertionResult.Outcome = .copied
        func captureFocus() -> DictationFocusToken? { focus }
        func insert(_ text: String, expecting expected: DictationFocusToken?) -> TextInsertionResult {
            expectedFocus = expected
            return insert(text)
        }

        func insert(_ text: String) -> TextInsertionResult {
            inserted.append(text)
            return TextInsertionResult(outcome: outcome)
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

    @Test("clipboard failure retains the completed result until copy recovery")
    func clipboardFailureRetainsResult() async {
        let inserter = FakeInserter()
        inserter.outcome = .copyFailed
        var snapshot: DictationResultSnapshot?
        let controller = DictationController(makeBackend: { FakeBackend(log: EventLog()) },
            capture: FakeCapture(log: EventLog()), inserter: inserter, captionsActive: { false },
            onResult: { snapshot = $0 })
        controller.press()
        await controller.waitForWorkForTests()
        controller.release()
        await controller.waitForWorkForTests()
        #expect(snapshot?.outputText == "hello from dictation")
        #expect(!controller.phase.automaticallyDismissesToast)
        guard case .recovery = controller.phase else { Issue.record("copy failure was reported as success"); return }
        controller.completeCopyRecovery()
        #expect(controller.phase == .result("Copied to Clipboard"))
    }

    @Test("setup trial processes cleanup and translation without insertion, and normal dictation still inserts")
    func trialDoesNotInsert() async {
        let backend = FakeBackend(log: EventLog())
        let capture = FakeCapture(log: EventLog())
        let inserter = FakeInserter()
        var output = ""
        let controller = DictationController(makeBackend: { backend }, capture: capture,
            inserter: inserter, captionsActive: { false },
            translationConfiguration: { .init(enabled: true, target: "de") },
            translate: { _, _, _ in "Hallo aus dem Test." },
            cleanupConfiguration: { .init(enabled: true) },
            cleanup: { text, _ in text + "." }, onResult: { output = $0.outputText })
        controller.press(previewOnly: true)
        await controller.waitForWorkForTests()
        controller.release()
        await controller.waitForWorkForTests()
        #expect(output == "Hallo aus dem Test.")
        #expect(inserter.inserted.isEmpty)
        #expect(controller.phase == .result("Trial complete"))
        controller.press()
        await controller.waitForWorkForTests()
        controller.release()
        await controller.waitForWorkForTests()
        #expect(inserter.inserted == ["Hallo aus dem Test."])
    }

    @Test("insertion uses the app captured at press, not the app focused after processing")
    func focusIsCapturedBeforeProcessing() async {
        let backend = FakeBackend(log: EventLog())
        let inserter = FakeInserter()
        let original = inserter.focus
        let controller = DictationController(makeBackend: { backend }, capture: FakeCapture(log: EventLog()),
            inserter: inserter, captionsActive: { false })
        controller.press()
        await controller.waitForWorkForTests()
        inserter.focus = .init(processIdentifier: 2, bundleIdentifier: "test.other")
        controller.release()
        await controller.waitForWorkForTests()
        #expect(inserter.expectedFocus == original)
    }

    @Test("closing a trial while transcription is pending cannot deliver a late result")
    func cancelledTrialDoesNotDeliver() async {
        let backend = FakeSegmentedBackend(log: EventLog())
        backend.result = .init(text: "late result", language: "en")
        let gate = ContinuationGate()
        backend.transcriptionGate = gate
        let capture = FakeCapture(log: EventLog())
        capture.samples = Array(repeating: 0.2, count: 16_000)
        let inserter = FakeInserter()
        var results = 0
        let controller = DictationController(makeBackend: { backend }, capture: capture,
            inserter: inserter, captionsActive: { false }, onResult: { _ in results += 1 })
        controller.press(previewOnly: true)
        await controller.waitForWorkForTests()
        controller.release()
        for _ in 0..<1_000 where !gate.entered { await Task.yield() }
        #expect(gate.entered)
        controller.cancel()
        gate.open()
        await controller.waitForWorkForTests()
        #expect(results == 0)
        #expect(inserter.inserted.isEmpty)
        #expect(capture.stopped)
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

    @Test("Hitting the duration cap says so instead of silently truncating")
    func limitIsAnnounced() async {
        let capture = FakeCapture(log: EventLog())
        capture.samples = [4]
        var phases: [DictationPhase] = []
        let controller = DictationController(
            makeBackend: { FakeBackend(log: EventLog()) }, capture: capture,
            inserter: FakeInserter(), captionsActive: { false },
            dictationUsesWhisper: { true },
            transcribeWhisper: { _, _ in "truncated" },
            onPhaseChanged: { phases.append($0) })
        controller.markReady(); controller.press(); await controller.waitForWorkForTests()
        for _ in 0..<100 where capture.limitHandler == nil { await Task.yield() }
        capture.limitHandler?()
        // The handler hops through a `Task { @MainActor }`, so the phase has to
        // be given a chance to land before it is read.
        for _ in 0..<100 { await Task.yield() }
        await controller.waitForWorkForTests()

        // The recording was cut, so the reason has to be on screen. It used to
        // go straight to `.transcribing`, which made `DictationPhase.limit` and
        // its "Limit reached" wording unreachable and left the truncated result
        // unexplained.
        #expect(phases.contains(.limit))
        // ...but it must not be the resting state, or progress looks stuck.
        #expect(phases.last != .limit)
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

    @Test("realtime previews do not replace authoritative segmented dictation")
    func fastStreamingDictationUsesDraftSession() async {
        let backend = FakeSegmentedBackend(log: EventLog())
        backend.streamingResult = "Hallo world"
        backend.result = .init(regions: [.init(text: "Guten Tag", language: "de"), .init(text: "world", language: "en")])
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
        #expect(backend.finishDictationCalls == 0)
        #expect(backend.transcriptionStarted)
        #expect(inserter.inserted == ["Guten Tag world"])
    }

    @Test("the draft reaches the handler while the words are still being spoken")
    func draftsArriveDuringDictationNotOnlyAtTheStop() async {
        let backend = FakeSegmentedBackend(log: EventLog())
        backend.streamingResult = "Hallo world"
        backend.result = .init(text: "Hallo world", language: "en")
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
        #expect(controller.phase == .dictating)

        // Still holding the key. If the push only happened in `finish`, the
        // screen would stay blank for the whole utterance and "realtime text"
        // would be a setting that changes nothing until you let go — which is
        // the state the screen was actually in before this.
        backend.emitDraft(.init(text: "Hallo", isFinal: true))
        backend.emitDraft(.init(text: "world", isFinal: false))
        for _ in 0..<100 where draft.isEmpty { await Task.yield() }

        #expect(draft == "Hallo world")
        #expect(controller.phase == .dictating)

        controller.release()
        await controller.waitForWorkForTests()

        #expect(draft == "Hallo world")
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

    @Test("translation failure describes cleaned copy-only delivery honestly")
    func cleanedCopyAfterTranslationFailure() async {
        let inserter = FakeInserter()
        let controller = DictationController(makeBackend: { FakeBackend(log: EventLog()) },
            capture: FakeCapture(log: EventLog()), inserter: inserter,
            captionsActive: { false },
            translationConfiguration: { .init(enabled: true, target: "de") },
            translate: { _, _, _ in nil },
            cleanupConfiguration: { .init(enabled: true) },
            cleanup: { text, _ in text })
        controller.press()
        await controller.waitForWorkForTests()
        controller.release()
        await controller.waitForWorkForTests()
        #expect(inserter.inserted == ["hello from dictation"])
        #expect(controller.phase == .result(String(localized: "Translation unavailable — cleaned text copied to Clipboard")))
    }

    @Test("transcription failure is visible to diagnostics")
    func transcriptionFailureReportsIssue() async {
        let backend = FakeSegmentedBackend(log: EventLog())
        backend.transcriptionError = BackendError.notPrepared
        let capture = FakeCapture(log: EventLog())
        capture.samples = [0.2]
        var issues: [String] = []
        let controller = DictationController(
            makeBackend: { backend },
            capture: capture,
            inserter: FakeInserter(),
            captionsActive: { false },
            onIssue: { operation, reason in issues.append("\(operation):\(reason)") })

        controller.press()
        await controller.waitForWorkForTests()
        controller.release()
        await controller.waitForWorkForTests()

        #expect(issues.count == 1)
        #expect(issues.first?.hasPrefix("dictation.transcription:") == true)
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

    @Test("a press before recognition readiness immediately records while preparation continues")
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
        #expect(controller.phase == .dictating)
        #expect(capture.started)
        #expect(!capture.stopped)

        backend.finishPreparation()
        await controller.waitForWorkForTests()

        #expect(capture.started)
        #expect(controller.phase == .dictating)
    }

    @Test("a stable authoritative region is decoded during recording and is not decoded again at release", arguments: [false, true])
    func completedRecognitionRunsBeforeRelease(preview: Bool) async throws {
        let capture = FakeCapture(log: EventLog())
        let backend = FakeSegmentedBackend(log: EventLog())
        backend.result = .init(text: "Hello world.", language: "en")
        let inserter = FakeInserter()
        let controller = DictationController(makeBackend: { backend }, capture: capture,
            inserter: inserter, captionsActive: { false }, dictationStreamingDraftEnabled: { preview })
        controller.press()
        await controller.waitForWorkForTests()
        capture.samples = Array(repeating: 0.2, count: 16_000) + Array(repeating: 0, count: 6_400)
            + Array(repeating: 0.2, count: 16_000)
        let buffer = AVAudioPCMBuffer(pcmFormat: backend.format, frameCapacity: 1)!
        buffer.frameLength = 1
        buffer.floatChannelData![0][0] = 0.2
        capture.onBuffer?(buffer)
        let waitUntil = ContinuousClock.now + .seconds(2)
        while backend.regionCalls.isEmpty, ContinuousClock.now < waitUntil {
            await Task.yield()
        }
        #expect(backend.regionCalls.count == 1)
        #expect(inserter.inserted.isEmpty)
        let expected = SpeechRegionSegmenter.default.segment(capture.samples, sampleRate: 16_000)
        #expect(backend.regionCalls.first == Array(expected.prefix(1)))
        controller.release()
        await controller.waitForWorkForTests()
        #expect(backend.regionCalls.flatMap { $0 } == expected)
        #expect(inserter.inserted == ["Hello world. Hello world."])
    }

    @Test("a cancelled release cannot commit old authoritative regions into an immediate new recording")
    func cancelledRegionCannotEnterNextRecording() async throws {
        let gate = ContinuationGate()
        let backend = FakeSegmentedBackend(log: EventLog())
        backend.transcriptionGate = gate
        backend.result = .init(text: "old recording", language: "en")
        let capture = FakeCapture(log: EventLog())
        let inserter = FakeInserter()
        let controller = DictationController(makeBackend: { backend }, capture: capture,
            inserter: inserter, captionsActive: { false })
        controller.press()
        await controller.waitForWorkForTests()
        capture.samples = [0.2]
        controller.release()
        let deadline = ContinuousClock.now + .seconds(2)
        while !gate.entered, ContinuousClock.now < deadline { await Task.yield() }
        #expect(gate.entered)
        controller.cancel()
        controller.press()
        capture.samples = [0.3]
        backend.result = .init(text: "new recording", language: "en")
        backend.transcriptionGate = nil
        gate.open()
        await controller.waitForWorkForTests()
        controller.release()
        await controller.waitForWorkForTests()
        #expect(inserter.inserted == ["new recording"])
        #expect(backend.regionCalls.count == 2)
    }

    @Test("a capped recording waiting for preparation refuses another press and preserves its phrase")
    func limitWaitRefusesNewPress() async {
        let backend = FakeBackend(log: EventLog())
        backend.blockPreparation = true
        let capture = FakeCapture(log: EventLog())
        let inserter = FakeInserter()
        let controller = DictationController(makeBackend: { backend }, capture: capture,
            inserter: inserter, captionsActive: { false })
        controller.press()
        let deadline = ContinuousClock.now + .seconds(2)
        while backend.preparationContinuation == nil, ContinuousClock.now < deadline { await Task.yield() }
        capture.samples = [0.2]
        capture.limitHandler?()
        while controller.phase != .limit, ContinuousClock.now < deadline { await Task.yield() }
        #expect(controller.phase == .limit)
        #expect(controller.isFinishing && controller.isBusy)
        controller.press()
        #expect(capture.startCalls == 1)
        backend.finishPreparation()
        await controller.waitForWorkForTests()
        #expect(capture.takeCalls == 1)
        #expect(inserter.inserted == ["hello from dictation"])
    }

    @Test("release before readiness stops capture immediately and preserves the recorded phrase")
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
        #expect(capture.started)
        capture.samples = Array(repeating: 0.2, count: 1600)
        let earlyBuffer = AVAudioPCMBuffer(pcmFormat: AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!,
                                          frameCapacity: 1600)!
        earlyBuffer.frameLength = 1600
        earlyBuffer.floatChannelData![0].update(from: capture.samples, count: 1600)
        capture.onBuffer?(earlyBuffer)
        for _ in 0..<100 where backend.prepares == 0 {
            await Task.yield()
        }
        controller.release()
        #expect(capture.stopped)
        #expect(capture.takeCalls == 1)
        backend.finishPreparation()
        await controller.waitForWorkForTests()

        #expect(capture.started)
        #expect(capture.startCalls == 1)
        #expect(capture.stopCalls == 1)
        #expect(backend.fedSamples == Array(repeating: 0.2, count: 1600))
        #expect(inserter.inserted == ["hello from dictation"])
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
