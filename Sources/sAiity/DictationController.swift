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

    private let backendProvider: any ASRBackendProvider
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

    /// True while dictation still owns work that can touch the translator. The
    /// key is released before transcription and translation finish, so
    /// `isActive` alone is not enough for model-lifecycle decisions.
    var isBusy: Bool {
        switch phase {
        case .preparing, .starting, .dictating, .transcribing, .translating, .inserting:
            return true
        case .idle, .waitingForInputMonitoring, .ready, .result, .failure:
            return false
        }
    }

    init(makeBackend: @escaping BackendFactory,
         capture: any DictationAudioCapture,
         inserter: any DictationTextInsertion,
         captionsActive: @escaping () -> Bool,
         translationConfiguration: @escaping TranslationConfigurationProvider = { .disabled },
         translate: @escaping TranslationHandler = { _, _, _ in nil },
         onPhaseChanged: @escaping (DictationPhase) -> Void = { _ in }) {
        self.backendProvider = SingleBackendProvider(makeBackend: makeBackend)
        self.capture = capture
        self.inserter = inserter
        self.captionsActive = captionsActive
        self.translationConfiguration = translationConfiguration
        self.translate = translate
        self.onPhaseChanged = onPhaseChanged
    }

    init(backendProvider: any ASRBackendProvider,
         capture: any DictationAudioCapture,
         inserter: any DictationTextInsertion,
         captionsActive: @escaping () -> Bool,
         translationConfiguration: @escaping TranslationConfigurationProvider = { .disabled },
         translate: @escaping TranslationHandler = { _, _, _ in nil },
         onPhaseChanged: @escaping (DictationPhase) -> Void = { _ in }) {
        self.backendProvider = backendProvider
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
        guard !state.isActive, preparationTask == nil, phase != .ready else { return }
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
        let wasReady = phase == .ready
        phase = .starting
        if !wasReady, preparationTask == nil {
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
        guard state.isActive || preparationTask != nil || phase == .ready || isBusy else {
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
        preparationTask = nil
        backend = nil
        phase = .idle

        let previousCleanup = cleanupTask
        cleanupTask = Task { @MainActor in
            await previousCleanup?.value
            await preparation?.value
            await startup?.value
            await release?.value
            if let active {
                await backendProvider.release(active, discard: true)
            } else {
                await backendProvider.invalidate()
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
        guard preparationTask == nil else { return }
        let token = preparationGeneration
        let previousCleanup = cleanupTask
        preparationTask = Task { @MainActor [weak self, previousCleanup] in
            await previousCleanup?.value
            guard !Task.isCancelled else { return }
            await self?.runPreparation(token: token)
        }
    }

    private func runPreparation(token: Int) async {
        do {
            try await backendProvider.prepare(locale: Locale.current) { _ in }
            try Task.checkCancellation()
            guard token == preparationGeneration else {
                return
            }
            try Task.checkCancellation()
            guard token == preparationGeneration else {
                return
            }
            preparationTask = nil
            if !state.isActive, phase == .preparing {
                phase = .ready
            }
        } catch is CancellationError {
            guard token == preparationGeneration else { return }
            preparationTask = nil
            if !state.isActive, phase == .preparing {
                phase = .idle
            }
        } catch {
            guard token == preparationGeneration else { return }
            preparationTask = nil
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
        let progress: @Sendable (String) -> Void = { _ in }
        do {
            let acquired = try await backendProvider.acquire(locale: Locale.current,
                                                              progress: progress)
            guard session == generation else {
                await backendProvider.release(acquired, discard: true)
                return
            }
            backend = acquired
            guard let format = await acquired.inputFormat else {
                throw BackendError.notPrepared
            }
            let collector = collector
            try await acquired.start { chunk in
                guard chunk.isFinal else { return }
                collector.append(chunk.text)
            }
            try Task.checkCancellation()
            guard session == generation else { return }
            try capture.start(targetFormat: format) { [weak acquired] buffer in
                acquired?.feed(buffer)
            }
            guard session == generation else {
                capture.stop()
                return
            }
            phase = state.isActive ? .dictating : .transcribing
        } catch is CancellationError {
            if let backend { await failStart(backend, session: session, message: nil) }
        } catch {
            if let backend {
                await failStart(backend, session: session, message: error.localizedDescription)
            } else if session == generation {
                state.cancel()
                phase = .failure(error.localizedDescription)
            }
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
        let authoritative = await backend.finishDictation()
        await backendProvider.release(backend, discard: false)
        self.backend = nil
        guard session == generation else { return }

        let authoritativeText = authoritative?.trimmingCharacters(in: .whitespacesAndNewlines)
        let text = authoritativeText.flatMap { $0.isEmpty ? nil : $0 } ?? collector.text
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
        guard session == generation else { return }
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
        await backendProvider.release(backend, discard: true)
        guard session == generation else { return }
        self.backend = nil
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
