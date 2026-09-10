import AVFoundation
import Foundation

protocol DictationAudioCapture: AnyObject {
    func start(targetFormat: AVAudioFormat,
               onBuffer: @escaping @Sendable (AVAudioPCMBuffer) -> Void) throws
    func stop()
    func takeCollectedSamples() -> [Float]
    func setLimitHandler(_ handler: (@Sendable () -> Void)?)
    func setWaveformHandler(_ handler: (@Sendable ([Float]) -> Void)?)
}

extension DictationAudioCapture {
    func takeCollectedSamples() -> [Float] { [] }
    func setLimitHandler(_ handler: (@Sendable () -> Void)?) {}
    func setWaveformHandler(_ handler: (@Sendable ([Float]) -> Void)?) {}
}

extension DictationMicrophoneCapture: DictationAudioCapture {}

@MainActor
protocol DictationTextInsertion: AnyObject {
    func insert(_ text: String) -> TextInsertionResult
}

extension TextInserter: DictationTextInsertion {}

/// Owns the reusable ASR backend and one short microphone -> insertion session.
@MainActor
final class DictationController {
    typealias BackendFactory = () -> TranscriptionBackend
    typealias TranslationConfigurationProvider = () -> DictationTranslationConfiguration
    typealias TranslationHandler = (String, String, String) async -> String?
    typealias DetailedTranslationHandler = (String, DictationTranscriptionResult, String) async -> String?
    typealias CleanupHandler = (String, String) async -> String?
    typealias DetailedCleanupHandler = (DictationTranscriptionResult) async -> DictationTranscriptionResult?
    typealias WaveformHandler = @Sendable ([Float]) -> Void
    typealias WhisperTranscriptionHandler = ([[Float]], Locale) async throws -> String?
    typealias WhisperSegmentTranscriptionHandler = ([Float], [DictationSpeechRegion], Locale) async throws -> DictationTranscriptionResult
    typealias AudioFormatFactory = () -> AVAudioFormat?
    typealias WhisperReadinessProvider = () -> Bool

    private let backendProvider: any ASRBackendProvider
    private let capture: any DictationAudioCapture
    private let inserter: any DictationTextInsertion
    private let captionsActive: () -> Bool
    private let translationConfiguration: TranslationConfigurationProvider
    private let translate: TranslationHandler
    private let detailedTranslate: DetailedTranslationHandler?
    private let onPhaseChanged: (DictationPhase) -> Void
    private let cleanupConfiguration: () -> DictationCleanupConfiguration
    private let cleanup: CleanupHandler
    private let detailedCleanup: DetailedCleanupHandler?
    private let onWaveform: WaveformHandler
    private let dictationUsesWhisper: () -> Bool
    private let transcribeWhisper: WhisperTranscriptionHandler
    private let transcribeWhisperSegments: WhisperSegmentTranscriptionHandler?
    private let audioFormatFactory: AudioFormatFactory
    private let whisperIsReady: WhisperReadinessProvider
    private let segmenter: SpeechRegionSegmenter

    private var state = DictationSessionState()
    private var generation = 0
    private var terminal: DictationTerminal = .cancelled
    private var preparationGeneration = 0
    private var backend: TranscriptionBackend?
    private var preparationTask: Task<Void, Never>?
    private var startupTask: Task<Void, Never>?
    private var releaseTask: Task<Void, Never>?
    private var cleanupTask: Task<Void, Never>?
    private var sessionUsesWhisper = false
    private var sessionLocale = Locale.current
    private var sessionSampleRate = 16_000.0
    private var captureDrained = true
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
        case .preparing, .starting, .dictating, .transcribing, .cleaning, .translating, .inserting:
            return true
        case .idle, .waitingForInputMonitoring, .ready, .limit, .recovery, .result, .failure:
            return false
        }
    }

    init(makeBackend: @escaping BackendFactory,
         capture: any DictationAudioCapture,
         inserter: any DictationTextInsertion,
         captionsActive: @escaping () -> Bool,
         translationConfiguration: @escaping TranslationConfigurationProvider = { .disabled },
         translate: @escaping TranslationHandler = { _, _, _ in nil },
         detailedTranslate: DetailedTranslationHandler? = nil,
         cleanupConfiguration: @escaping () -> DictationCleanupConfiguration = { .disabled },
         cleanup: @escaping CleanupHandler = { _, _ in nil },
         detailedCleanup: DetailedCleanupHandler? = nil,
         onWaveform: @escaping WaveformHandler = { _ in },
         dictationUsesWhisper: @escaping () -> Bool = { false },
         transcribeWhisper: @escaping WhisperTranscriptionHandler = { _, _ in nil },
         transcribeWhisperSegments: WhisperSegmentTranscriptionHandler? = nil,
         audioFormatFactory: @escaping AudioFormatFactory = { AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1) },
         whisperIsReady: @escaping WhisperReadinessProvider = { true },
         segmenter: SpeechRegionSegmenter = .default,
         onPhaseChanged: @escaping (DictationPhase) -> Void = { _ in }) {
        self.backendProvider = SingleBackendProvider(makeBackend: makeBackend)
        self.capture = capture
        self.inserter = inserter
        self.captionsActive = captionsActive
        self.translationConfiguration = translationConfiguration
        self.translate = translate
        self.detailedTranslate = detailedTranslate
        self.cleanupConfiguration = cleanupConfiguration
        self.cleanup = cleanup
        self.detailedCleanup = detailedCleanup
        self.onWaveform = onWaveform
        self.dictationUsesWhisper = dictationUsesWhisper
        self.transcribeWhisper = transcribeWhisper
        self.transcribeWhisperSegments = transcribeWhisperSegments
        self.audioFormatFactory = audioFormatFactory
        self.whisperIsReady = whisperIsReady
        self.segmenter = segmenter
        self.onPhaseChanged = onPhaseChanged
    }

    init(backendProvider: any ASRBackendProvider,
         capture: any DictationAudioCapture,
         inserter: any DictationTextInsertion,
         captionsActive: @escaping () -> Bool,
         translationConfiguration: @escaping TranslationConfigurationProvider = { .disabled },
         translate: @escaping TranslationHandler = { _, _, _ in nil },
         detailedTranslate: DetailedTranslationHandler? = nil,
         cleanupConfiguration: @escaping () -> DictationCleanupConfiguration = { .disabled },
         cleanup: @escaping CleanupHandler = { _, _ in nil },
         detailedCleanup: DetailedCleanupHandler? = nil,
         onWaveform: @escaping WaveformHandler = { _ in },
         dictationUsesWhisper: @escaping () -> Bool = { false },
         transcribeWhisper: @escaping WhisperTranscriptionHandler = { _, _ in nil },
         transcribeWhisperSegments: WhisperSegmentTranscriptionHandler? = nil,
         audioFormatFactory: @escaping AudioFormatFactory = { AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1) },
         whisperIsReady: @escaping WhisperReadinessProvider = { true },
         segmenter: SpeechRegionSegmenter = .default,
         onPhaseChanged: @escaping (DictationPhase) -> Void = { _ in }) {
        self.backendProvider = backendProvider
        self.capture = capture
        self.inserter = inserter
        self.captionsActive = captionsActive
        self.translationConfiguration = translationConfiguration
        self.translate = translate
        self.detailedTranslate = detailedTranslate
        self.cleanupConfiguration = cleanupConfiguration
        self.cleanup = cleanup
        self.detailedCleanup = detailedCleanup
        self.onWaveform = onWaveform
        self.dictationUsesWhisper = dictationUsesWhisper
        self.transcribeWhisper = transcribeWhisper
        self.transcribeWhisperSegments = transcribeWhisperSegments
        self.audioFormatFactory = audioFormatFactory
        self.whisperIsReady = whisperIsReady
        self.segmenter = segmenter
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
        sessionUsesWhisper = dictationUsesWhisper()
        sessionLocale = sessionUsesWhisper ? Locale(identifier: WhisperDictationBackend.locale) : Locale.current
        captureDrained = false
        if sessionUsesWhisper && !whisperIsReady() {
            state.cancel()
            phase = .failure(String(localized: "Not ready"))
            return
        }
        terminal = .open
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
        guard state.release(), terminal.accept(.released) else { return }
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
        _ = terminal.accept(.cancelled)
        preparationGeneration += 1
        state.cancel()
        startupTask?.cancel()
        releaseTask?.cancel()
        preparationTask?.cancel()
        _ = drainCapture()

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

    private func limit(session: Int) {
        guard session == generation, terminal.accept(.limited) else { return }
        state.cancel()
        phase = .transcribing
        releaseTask = Task { @MainActor [weak self] in await self?.finish(session: session) }
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
            if sessionUsesWhisper {
                guard let format = audioFormatFactory() else {
                    throw BackendError.notPrepared
                }
                sessionSampleRate = format.sampleRate
                capture.setLimitHandler { [weak self] in
                    Task { @MainActor in self?.limit(session: session) }
                }
                capture.setWaveformHandler(onWaveform)
                try capture.start(targetFormat: format) { _ in }
                guard session == generation else {
                    capture.stop()
                    return
                }
                phase = state.isActive ? .dictating : .transcribing
                return
            }
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
            sessionSampleRate = format.sampleRate
            let deferred = acquired is any DictationSegmentTranscriber
            if !deferred {
                try await acquired.start { _ in }
                try Task.checkCancellation()
            }
            guard session == generation else { return }
            capture.setLimitHandler { [weak self] in
                Task { @MainActor in self?.limit(session: session) }
            }
            capture.setWaveformHandler(onWaveform)
            try capture.start(targetFormat: format) { [weak acquired] buffer in
                guard !deferred else { return }
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
                _ = drainCapture()
                state.cancel()
                phase = .failure(error.localizedDescription)
            }
        }
    }

    private func finish(session: Int) async {
        guard session == generation else { return }
        let samples = drainCapture()
        NSLog("sAiity dictation capture: \(samples.count) samples at \(Int(sessionSampleRate)) Hz (\(String(format: "%.2f", Double(samples.count) / sessionSampleRate))s)")
        if sessionUsesWhisper {
            do {
                if let transcribeWhisperSegments,
                   sessionLocale.identifier == "auto" {
                    let regions = segmenter.segment(samples, sampleRate: sessionSampleRate)
                    NSLog("sAiity dictation transcription: Whisper Auto, \(regions.count) region(s)")
                    guard session == generation, !Task.isCancelled else { return }
                    let transcription = try await transcribeWhisperSegments(samples,
                                                                              regions,
                                                                              sessionLocale)
                    guard session == generation else { return }
                    await finish(transcription: transcription,
                                 session: session,
                                 fallbackSourceLanguage: Locale.current.identifier(.bcp47))
                    return
                }
                let whisperSamples = samples.isEmpty ? [] : [samples]
                guard session == generation, !Task.isCancelled else { return }
                let authoritative = try await transcribeWhisper(whisperSamples, sessionLocale)
                guard session == generation else { return }
                await finish(authoritative: authoritative, session: session, sourceLanguage: sessionLocale.identifier(.bcp47))
            } catch is CancellationError {
                return
            } catch {
                guard session == generation else { return }
                phase = .failure(error.localizedDescription)
            }
            return
        }
        guard let backend else {
            if phase == .transcribing { phase = .idle }
            return
        }
        if let segmented = backend as? any DictationSegmentTranscriber {
            do {
                let regions = segmenter.segment(samples, sampleRate: sessionSampleRate)
                NSLog("sAiity dictation transcription: segmented \(regions.count) region(s) with \(backend.name)")
                guard session == generation, !Task.isCancelled else { return }
                let transcription = try await segmented.transcribeDictation(samples: samples,
                                                                              regions: regions)
                await backendProvider.release(backend, discard: false)
                self.backend = nil
                guard session == generation else { return }
                await finish(transcription: transcription,
                             session: session,
                             fallbackSourceLanguage: Locale.current.identifier(.bcp47))
            } catch is CancellationError {
                await backendProvider.release(backend, discard: true)
            } catch {
                await backendProvider.release(backend, discard: true)
                self.backend = nil
                guard session == generation else { return }
                phase = .failure(error.localizedDescription)
            }
            return
        }
        let sourceLanguage = await backend.detectedLanguage()
            ?? Locale.current.identifier(.bcp47)
        let authoritative = await backend.finishDictation()
        await backendProvider.release(backend, discard: false)
        self.backend = nil
        guard session == generation else { return }

        await finish(authoritative: authoritative, session: session, sourceLanguage: sourceLanguage)
    }

    private func finish(authoritative: String?, session: Int, sourceLanguage: String) async {
        let transcription = DictationTranscriptionResult(text: authoritative ?? "",
                                                          language: sourceLanguage)
        await finish(transcription: transcription,
                     session: session,
                     fallbackSourceLanguage: sourceLanguage)
    }

    private func finish(transcription: DictationTranscriptionResult,
                        session: Int,
                        fallbackSourceLanguage: String) async {
        guard session == generation else { return }
        let authoritativeText = transcription.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !authoritativeText.isEmpty else {
            phase = .result(String(localized: "No speech detected"))
            return
        }
        let text = authoritativeText
        let configuration = translationConfiguration()
        let metadata = transcription.languageMetadata
        let sourceLanguage = metadata.dominantLanguage ?? fallbackSourceLanguage
        var output = text
        var transcriptionForTranslation = transcription
        var cleaned = false
        var translated = false
        var translationFailed = false
        if cleanupConfiguration().enabled {
            phase = .cleaning
            let value: String?
            if let detailedCleanup {
                if let candidate = await detailedCleanup(transcription),
                   let valid = DictationCleanupValidator.validate(candidate.text,
                                                                  preserving: text,
                                                                  sourceLanguage: sourceLanguage,
                                                                  languageMetadata: metadata) {
                    output = valid
                    transcriptionForTranslation = candidate
                    cleaned = true
                }
                value = nil
            } else {
                value = await cleanup(text, sourceLanguage)
            }
            if !cleaned, let value,
               let valid = DictationCleanupValidator.validate(value,
                                                              preserving: text,
                                                              sourceLanguage: sourceLanguage,
                                                              languageMetadata: metadata) {
                output = valid
                cleaned = true
            }
        }
        if configuration.enabled,
           let target = configuration.target?.trimmingCharacters(in: .whitespacesAndNewlines),
           !target.isEmpty {
            phase = .translating
            let value: String?
            if let detailedTranslate {
                value = await detailedTranslate(output, transcriptionForTranslation, target)
            } else {
                value = await translate(output, sourceLanguage, target)
            }
            if let value {
                let translatedText = value.trimmingCharacters(in: .whitespacesAndNewlines)
                if !translatedText.isEmpty {
                    output = translatedText
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
                phase = .result(String(localized: cleaned ? "Translation unavailable — cleaned text inserted and copied" : "Translation unavailable — original inserted and copied"))
            } else {
                phase = .result(String(localized: "Inserted and copied"))
            }
        case .copied:
            if translated {
                phase = .result(String(localized: "Translated and copied"))
            } else if translationFailed {
                phase = .result(String(localized: cleaned ? "Translation unavailable — cleaned text inserted and copied" : "Translation unavailable — original copied to Clipboard"))
            } else {
                phase = .result(String(localized: "Copied to Clipboard"))
            }
        }
    }

    private func failStart(_ backend: TranscriptionBackend,
                           session: Int,
                           message: String?) async {
        _ = drainCapture()
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

    private func drainCapture() -> [Float] {
        guard !captureDrained else { return [] }
        captureDrained = true
        capture.setWaveformHandler(nil)
        capture.stop()
        return capture.takeCollectedSamples()
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
