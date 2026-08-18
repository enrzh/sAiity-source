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
        var onChunk: (@Sendable (TranscriptChunk) -> Void)?
        var detectedLanguageResult: String? = "en"

        init(log: EventLog) { self.log = log }

        let name = "Test backend"
        var inputFormat: AVAudioFormat? { get async { format } }
        func prepare(locale: Locale, progress: @escaping @Sendable (String) -> Void) async throws {}
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
}
