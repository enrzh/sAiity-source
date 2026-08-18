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

/// Owns the reusable ASR backend and one short microphone -> insertion session.
@MainActor
final class DictationController {
    typealias BackendFactory = () -> TranscriptionBackend
    typealias TranslationConfigurationProvider = () -> DictationTranslationConfiguration
    typealias TranslationHandler = (String, String, String) async -> String?

    private let makeBackend: BackendFactory
    private let capture: any DictationAudioCapture
    private let inserter: any DictationTextInsertion
    private let captionsActive: () -> Bool
    private let translationConfiguration: TranslationConfigurationProvider
    private let translate: TranslationHandler
    private let onPhaseChanged: (DictationPhase) -> Void
    private let collector = DictationFinalTextCollector()

    private var state = DictationSessionState()
    private var generation = 0
    private var preparationGeneration = 0
    private var backend: TranscriptionBackend?
    private var preparedBackend: TranscriptionBackend?
    private var preparedFormat: AVAudioFormat?
    private var preparationTask: Task<Void, Never>?
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
         translationConfiguration: @escaping TranslationConfigurationProvider = { .disabled },
         translate: @escaping TranslationHandler = { _, _, _ in nil },
         onPhaseChanged: @escaping (DictationPhase) -> Void = { _ in }) {
        self.makeBackend = makeBackend
        self.capture = capture
        self.inserter = inserter
        self.captionsActive = captionsActive
        self.translationConfiguration = translationConfiguration
        self.translate = translate
        self.onPhaseChanged = onPhaseChanged
    }

    /// Starts ASR preparation without opening the microphone. Calling this more
    /// than once joins the same single-flight task and never creates a second
    /// backend.
    func prepare() {
        guard !state.isActive, preparedBackend == nil, preparationTask == nil else { return }
        phase = .preparing
        beginPreparation()
    }

    /// Marks the global shortcut as available for tests and compatibility with
    /// callers that already completed preparation outside this controller.
    func markReady() {
        guard !state.isActive else { return }
        phase = .ready
    }

    /// Returns to the persistent ready feedback after a transient result or
    /// error. A new press, cancellation, or permission state wins if it landed
    /// while the feedback was visible.
    func markReadyAfterFeedback() {
        guard !state.isActive, phase.automaticallyDismissesToast else { return }
        phase = .ready
    }

    /// Keeps the missing global-key permission visible instead of making the
    /// shortcut look dead while the monitor retries in the background.
    func markWaitingForInputMonitoring() {
        guard !state.isActive else { return }
        phase = .waitingForInputMonitoring
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
        phase = .starting
        if preparedBackend == nil, preparationTask == nil {
            beginPreparation()
        }
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

    /// Cancels both a live microphone session and a background/prepared ASR
    /// backend. The async companion below is used when model files are about to
    /// be deleted and must not return until the backend has really stopped.
    func cancel() {
        guard state.isActive || preparationTask != nil || preparedBackend != nil else {
            phase = .idle
            return
        }

        generation += 1
        preparationGeneration += 1
        state.cancel()
        startupTask?.cancel()
        releaseTask?.cancel()
        preparationTask?.cancel()
        capture.stop()

        let preparation = preparationTask
        let startup = startupTask
        let release = releaseTask
        let active = backend
        let prepared = preparedBackend
        preparationTask = nil
        backend = nil
        preparedBackend = nil
        preparedFormat = nil
        phase = .idle

        cleanupTask = Task { @MainActor in
            await preparation?.value
            await startup?.value
            await release?.value
            if let active {
                await active.stop()
            } else {
                await prepared?.stop()
            }
        }
    }

    /// Synchronous callers can initiate cancellation; model deletion awaits
    /// this method so no old backend can keep a model file open.
    func invalidatePreparedBackend() async {
        cancel()
        await cleanupTask?.value
    }

    private func beginPreparation() {
        guard preparationTask == nil, preparedBackend == nil else { return }
        let token = preparationGeneration
        preparationTask = Task { @MainActor [weak self] in
            await self?.runPreparation(token: token)
        }
    }

    private func runPreparation(token: Int) async {
        let candidate = makeBackend()
        do {
            try await candidate.prepare(locale: Locale.current) { _ in }
            try Task.checkCancellation()
            guard token == preparationGeneration else {
                await candidate.stop()
                return
            }
            guard let format = await candidate.inputFormat else {
                throw BackendError.notPrepared
            }
            try Task.checkCancellation()
            guard token == preparationGeneration else {
                await candidate.stop()
                return
            }
            preparedBackend = candidate
            preparedFormat = format
            preparationTask = nil
            if !state.isActive, phase == .preparing {
                phase = .ready
            }
        } catch is CancellationError {
            await candidate.stop()
            guard token == preparationGeneration else { return }
            preparationTask = nil
            if !state.isActive, phase == .preparing {
                phase = .idle
            }
        } catch {
            await candidate.stop()
            guard token == preparationGeneration else { return }
            preparationTask = nil
            preparedBackend = nil
            preparedFormat = nil
            state.cancel()
            phase = .failure(error.localizedDescription)
        }
    }

    private func start(session: Int) async {
        guard session == generation else { return }
        await preparationTask?.value
        guard session == generation else { return }
        guard state.isActive else {
            if phase == .starting || phase == .transcribing {
                phase = .idle
            }
            return
        }
        guard let preparedBackend, let preparedFormat else {
            if phase == .starting || phase == .transcribing {
                state.cancel()
                phase = .idle
            }
            return
        }

        backend = preparedBackend
        do {
            let collector = collector
            try await preparedBackend.start { chunk in
                guard chunk.isFinal else { return }
                collector.append(chunk.text)
            }
            try Task.checkCancellation()
            guard session == generation else { return }
            try capture.start(targetFormat: preparedFormat) { [weak preparedBackend] buffer in
                preparedBackend?.feed(buffer)
            }
            guard session == generation else {
                capture.stop()
                return
            }
            phase = state.isActive ? .dictating : .transcribing
        } catch is CancellationError {
            await failStart(preparedBackend, session: session, message: nil)
        } catch {
            await failStart(preparedBackend, session: session, message: error.localizedDescription)
        }
    }

    private func finish(session: Int) async {
        guard session == generation else { return }
        capture.stop()
        guard let backend else {
            if phase == .transcribing { phase = .idle }
            return
        }
        let sourceLanguage = await backend.detectedLanguage()
            ?? Locale.current.identifier(.bcp47)
        await backend.flushPending()
        await backend.stop()
        guard session == generation else { return }
        self.backend = nil

        let text = collector.text
        guard !text.isEmpty else {
            phase = .result(String(localized: "No speech detected"))
            return
        }
        let configuration = translationConfiguration()
        var output = text
        var translated = false
        var translationFailed = false
        if configuration.enabled,
           let target = configuration.target?.trimmingCharacters(in: .whitespacesAndNewlines),
           !target.isEmpty {
            phase = .translating
            if let value = await translate(text, sourceLanguage, target) {
                let cleaned = value.trimmingCharacters(in: .whitespacesAndNewlines)
                if !cleaned.isEmpty {
                    output = cleaned
                    translated = true
                } else {
                    translationFailed = true
                }
            } else {
                translationFailed = true
            }
        }
        phase = .inserting
        let result = inserter.insert(output)
        switch result.outcome {
        case .insertedAndCopied:
            if translated {
                phase = .result(String(localized: "Translated and inserted"))
            } else if translationFailed {
                phase = .result(String(localized: "Translation unavailable — original inserted and copied"))
            } else {
                phase = .result(String(localized: "Inserted and copied"))
            }
        case .copied:
            if translated {
                phase = .result(String(localized: "Translated and copied"))
            } else if translationFailed {
                phase = .result(String(localized: "Translation unavailable — original copied to Clipboard"))
            } else {
                phase = .result(String(localized: "Copied to Clipboard"))
            }
        }
    }

    private func failStart(_ backend: TranscriptionBackend,
                           session: Int,
                           message: String?) async {
        capture.stop()
        await backend.stop()
        guard session == generation else { return }
        self.backend = nil
        if let cached = preparedBackend, cached === backend {
            self.preparedBackend = nil
            self.preparedFormat = nil
        }
        state.cancel()
        if let message {
            phase = .failure(message)
        } else {
            phase = .idle
        }
    }

    #if SAIITY_TEST_HOOKS
    func waitForWorkForTests() async {
        await preparationTask?.value
        await startupTask?.value
        await releaseTask?.value
        await cleanupTask?.value
    }
    #endif
}
