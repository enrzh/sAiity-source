import AVFoundation
import Foundation

protocol DictationAudioCapture: AnyObject {
    func start(targetFormat: AVAudioFormat,
               onBuffer: @escaping @Sendable (AVAudioPCMBuffer) -> Void) throws
    func stop()
}

extension DictationMicrophoneCapture: DictationAudioCapture {}

@MainActor
protocol DictationTextInsertion: AnyObject {
    func insert(_ text: String) -> TextInsertionResult
}

extension TextInserter: DictationTextInsertion {}

private final class DictationFinalTextCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var assembler = DictationTextAssembler()

    func reset() {
        lock.withLock { assembler.reset() }
    }

    func append(_ text: String) {
        lock.withLock { assembler.append(text) }
    }

    var text: String {
        lock.withLock { assembler.finalText }
    }
}

/// Owns one short microphone -> ASR -> insertion session.
@MainActor
final class DictationController {
    typealias BackendFactory = () -> TranscriptionBackend

    private let makeBackend: BackendFactory
    private let capture: any DictationAudioCapture
    private let inserter: any DictationTextInsertion
    private let captionsActive: () -> Bool
    private let onPhaseChanged: (DictationPhase) -> Void
    private let collector = DictationFinalTextCollector()

    private var state = DictationSessionState()
    private var generation = 0
    private var backend: TranscriptionBackend?
    private var startupTask: Task<Void, Never>?
    private var releaseTask: Task<Void, Never>?
    private var cleanupTask: Task<Void, Never>?
    private(set) var phase: DictationPhase = .idle {
        didSet {
            guard phase != oldValue else { return }
            onPhaseChanged(phase)
        }
    }

    var isActive: Bool { state.isActive }

    init(makeBackend: @escaping BackendFactory,
         capture: any DictationAudioCapture,
         inserter: any DictationTextInsertion,
         captionsActive: @escaping () -> Bool,
         onPhaseChanged: @escaping (DictationPhase) -> Void = { _ in }) {
        self.makeBackend = makeBackend
        self.capture = capture
        self.inserter = inserter
        self.captionsActive = captionsActive
        self.onPhaseChanged = onPhaseChanged
    }

    func press() {
        guard !state.isActive else { return }
        guard !captionsActive() else {
            phase = .failure(String(localized: "Captions are already running."))
            return
        }
        guard state.begin() else { return }

        generation += 1
        let session = generation
        collector.reset()
        phase = .dictating
        startupTask = Task { @MainActor [weak self] in
            await self?.start(session: session)
        }
    }

    func release() {
        guard state.release() else { return }
        let session = generation
        phase = .transcribing
        releaseTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.startupTask?.value
            await self.finish(session: session)
        }
    }

    func cancel() {
        guard state.isActive else { return }
        generation += 1
        state.cancel()
        startupTask?.cancel()
        releaseTask?.cancel()
        capture.stop()
        phase = .idle

        let startup = startupTask
        cleanupTask = Task { @MainActor [weak self] in
            await startup?.value
            guard let self else { return }
            self.backend = nil
        }
    }

    private func start(session: Int) async {
        let backend = makeBackend()
        self.backend = backend
        do {
            try await backend.prepare(locale: Locale.current) { _ in }
            try Task.checkCancellation()
            // A quick tap can release while the model is preparing. The session
            // is still valid until finish() has stopped the backend; cancelling
            // is represented by a generation change, not by state.isActive.
            guard session == generation, state.isActive || phase == .transcribing else {
                await backend.stop()
                return
            }

            let collector = collector
            try await backend.start { chunk in
                guard chunk.isFinal else { return }
                collector.append(chunk.text)
            }
            try Task.checkCancellation()
            guard let format = await backend.inputFormat else {
                throw BackendError.notPrepared
            }
            try Task.checkCancellation()
            try capture.start(targetFormat: format) { [weak backend] buffer in
                backend?.feed(buffer)
            }
        } catch is CancellationError {
            await teardown(backend, session: session, reportFailure: false)
        } catch {
            await teardown(backend, session: session, reportFailure: true, message: error.localizedDescription)
        }
    }

    private func finish(session: Int) async {
        guard session == generation else { return }
        capture.stop()
        guard let backend else {
            if phase == .transcribing { phase = .idle }
            return
        }
        await backend.stop()
        guard session == generation else { return }
        self.backend = nil

        let text = collector.text
        guard !text.isEmpty else {
            phase = .result(String(localized: "No speech detected"))
            return
        }
        phase = .inserting
        let result = inserter.insert(text)
        switch result.outcome {
        case .inserted:
            phase = .result(String(localized: "Inserted"))
        case .copied:
            phase = .result(String(localized: "Copied to Clipboard"))
        }
    }

    private func teardown(_ backend: TranscriptionBackend,
                          session: Int,
                          reportFailure: Bool,
                          message: String = "") async {
        capture.stop()
        await backend.stop()
        guard session == generation else { return }
        self.backend = nil
        state.cancel()
        if reportFailure {
            phase = .failure(message)
        } else {
            phase = .idle
        }
    }

    #if SAIITY_TEST_HOOKS
    func waitForWorkForTests() async {
        await startupTask?.value
        await releaseTask?.value
        await cleanupTask?.value
    }
    #endif
}
