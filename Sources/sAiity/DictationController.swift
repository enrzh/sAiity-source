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
    typealias ResultHandler = (DictationResultSnapshot) -> Void
    typealias DraftHandler = (String) -> Void
    typealias WaveformHandler = @Sendable ([Float]) -> Void
    typealias WhisperTranscriptionHandler = ([[Float]], Locale) async throws -> String?
    typealias WhisperSegmentTranscriptionHandler = ([Float], [DictationSpeechRegion], Locale) async throws -> DictationTranscriptionResult
    typealias AudioFormatFactory = () -> AVAudioFormat?
    typealias WhisperReadinessProvider = () -> Bool
    typealias IssueHandler = (String, String) -> Void
    typealias TimingHandler = (String, Double, Bool?) -> Void

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
    private let onResult: ResultHandler
    private let onDraft: DraftHandler
    private let onWaveform: WaveformHandler
    private let dictationUsesWhisper: () -> Bool
    private let dictationStreamingDraftEnabled: () -> Bool
    private let transcribeWhisper: WhisperTranscriptionHandler
    private let transcribeWhisperSegments: WhisperSegmentTranscriptionHandler?
    private let audioFormatFactory: AudioFormatFactory
    private let whisperIsReady: WhisperReadinessProvider
    private let segmenter: SpeechRegionSegmenter
    private let onIssue: IssueHandler
    private let onTiming: TimingHandler

    private var state = DictationSessionState()
    private var generation = 0
    private var terminal: DictationTerminal = .cancelled
    private var preparationGeneration = 0
    private var backend: TranscriptionBackend?
    /// The session that owns `backend`. The pool hands out one lease at a time
    /// but the same object to whoever asks next, so identity alone cannot say
    /// whose lease a failure path is about to discard.
    private var backendSession: Int?
    private var preparationTask: Task<Void, Never>?
    private var startupTask: Task<Void, Never>?
    private var releaseTask: Task<Void, Never>?
    private var cleanupTask: Task<Void, Never>?
    private var sessionUsesWhisper = false
    private var sessionUsesStreamingDraft = false
    private var sessionLocale = Locale.current
    private var sessionSampleRate = 16_000.0
    private var captureDrained = true
    private var draftFinalText = ""
    private var draftVolatileText = ""
    private var latestDraftText = ""
    private(set) var phase: DictationPhase = .idle {
        didSet {
            guard phase != oldValue else { return }
            onPhaseChanged(phase)
        }
    }

    var isActive: Bool { state.isActive }

    /// True while a previous session still owns work that has not finished:
    /// transcription, cleanup, translation, insertion.
    ///
    /// `state.isActive` is not enough, and the gap was a real one. Releasing the
    /// key ends the *microphone* session, so a second press during the first
    /// one's transcription passed `press()`'s guard and started a session that
    /// shared the same prepared backend. That backend is leased exclusively, so
    /// the second start failed — and its failure path discarded a backend the
    /// first session was still transcribing with, ending the utterance the user
    /// was in the middle of saying.
    var isFinishing: Bool {
        switch phase {
        case .transcribing, .cleaning, .translating, .inserting: return true
        case .idle, .waitingForInputMonitoring, .preparing, .ready, .starting,
             .dictating, .limit, .recovery, .result, .failure:
            return false
        }
    }

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
         onResult: @escaping ResultHandler = { _ in },
         onDraft: @escaping DraftHandler = { _ in },
         onWaveform: @escaping WaveformHandler = { _ in },
         dictationUsesWhisper: @escaping () -> Bool = { false },
         dictationStreamingDraftEnabled: @escaping () -> Bool = { false },
         transcribeWhisper: @escaping WhisperTranscriptionHandler = { _, _ in nil },
         transcribeWhisperSegments: WhisperSegmentTranscriptionHandler? = nil,
         audioFormatFactory: @escaping AudioFormatFactory = { AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1) },
         whisperIsReady: @escaping WhisperReadinessProvider = { true },
         segmenter: SpeechRegionSegmenter = .default,
         onIssue: @escaping IssueHandler = { _, _ in },
         onTiming: @escaping TimingHandler = { _, _, _ in },
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
        self.onResult = onResult
        self.onDraft = onDraft
        self.onWaveform = onWaveform
        self.dictationUsesWhisper = dictationUsesWhisper
        self.dictationStreamingDraftEnabled = dictationStreamingDraftEnabled
        self.transcribeWhisper = transcribeWhisper
        self.transcribeWhisperSegments = transcribeWhisperSegments
        self.audioFormatFactory = audioFormatFactory
        self.whisperIsReady = whisperIsReady
        self.segmenter = segmenter
        self.onIssue = onIssue
        self.onTiming = onTiming
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
         onResult: @escaping ResultHandler = { _ in },
         onDraft: @escaping DraftHandler = { _ in },
         onWaveform: @escaping WaveformHandler = { _ in },
         dictationUsesWhisper: @escaping () -> Bool = { false },
         dictationStreamingDraftEnabled: @escaping () -> Bool = { false },
         transcribeWhisper: @escaping WhisperTranscriptionHandler = { _, _ in nil },
         transcribeWhisperSegments: WhisperSegmentTranscriptionHandler? = nil,
         audioFormatFactory: @escaping AudioFormatFactory = { AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1) },
         whisperIsReady: @escaping WhisperReadinessProvider = { true },
         segmenter: SpeechRegionSegmenter = .default,
         onIssue: @escaping IssueHandler = { _, _ in },
         onTiming: @escaping TimingHandler = { _, _, _ in },
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
        self.onResult = onResult
        self.onDraft = onDraft
        self.onWaveform = onWaveform
        self.dictationUsesWhisper = dictationUsesWhisper
        self.dictationStreamingDraftEnabled = dictationStreamingDraftEnabled
        self.transcribeWhisper = transcribeWhisper
        self.transcribeWhisperSegments = transcribeWhisperSegments
        self.audioFormatFactory = audioFormatFactory
        self.whisperIsReady = whisperIsReady
        self.segmenter = segmenter
        self.onIssue = onIssue
        self.onTiming = onTiming
        self.onPhaseChanged = onPhaseChanged
    }

    /// Starts ASR preparation without opening the microphone. Calling this more
    /// than once joins the same single-flight task and never creates a second
    /// backend.
    func prepare() {
        guard !dictationUsesWhisper(),
              !state.isActive,
              preparationTask == nil,
              phase != .ready else { return }
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
        // One session at a time, all the way through. A press while the
        // previous release is still transcribing, cleaning, translating or
        // inserting is not a second recording — it is two sessions contending
        // for one shared, exclusively-leased backend.
        guard !isFinishing else { return }
        guard !captionsActive() else {
            phase = .failure(String(localized: "Captions are already running."))
            return
        }
        guard state.begin() else { return }

        generation += 1
        let session = generation
        sessionUsesWhisper = dictationUsesWhisper()
        sessionUsesStreamingDraft = !sessionUsesWhisper && dictationStreamingDraftEnabled()
        resetDraft()
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
        if !sessionUsesWhisper, !wasReady, preparationTask == nil {
            beginPreparation()
        }
        startupTask = Task { @MainActor [weak self] in
            await self?.start(session: session)
        }
    }

    func release() {
        guard state.release(), terminal.accept(.released) else { return }
        releaseStarted = .now
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
        // The lease leaves with the reference. Leaving the owner behind would
        // let a later session match a slot it never filled and release someone
        // else's backend.
        backendSession = nil
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
        releaseStarted = .now
        state.cancel()
        // Say the recording was cut. This used to go straight to `.transcribing`,
        // which left `DictationPhase.limit` — and its "Limit reached" wording —
        // unreachable: a user who held the key past the cap had their audio
        // truncated with nothing on screen explaining why the result was short.
        // `finish` moves on to `.transcribing` as soon as it starts working.
        phase = .limit
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
            reportIssue("dictation.prepare", error.localizedDescription)
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
                // This lease is unambiguously ours — nothing else can hold the
                // pool's single active slot — so it can be discarded even
                // though a newer session exists.
                await backendProvider.release(acquired, discard: true)
                return
            }
            backend = acquired
            backendSession = session
            guard let format = await acquired.inputFormat else {
                throw BackendError.notPrepared
            }
            sessionSampleRate = format.sampleRate
            let deferred = acquired is any DictationSegmentTranscriber && !sessionUsesStreamingDraft
            if !deferred {
                let useStreamingDraft = sessionUsesStreamingDraft
                try await acquired.start { [weak self] chunk in
                    guard useStreamingDraft else { return }
                    Task { @MainActor [weak self] in
                        self?.receiveDraft(chunk, session: session)
                    }
                }
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
            if backendSession == session {
                await failStart(session: session, message: nil)
            }
        } catch {
            if backendSession == session {
                await failStart(session: session, message: error.localizedDescription)
            } else if session == generation {
                _ = drainCapture()
                state.cancel()
                reportIssue("dictation.start", error.localizedDescription)
                phase = .failure(error.localizedDescription)
            }
        }
    }

    private var releaseStarted: ContinuousClock.Instant?

    private func finish(session: Int) async {
        guard session == generation else { return }
        // The cap explains itself, then gets out of the way. Only the limited
        // path needs this — a normal release already said `.transcribing` when
        // the key came up.
        if phase == .limit { phase = .transcribing }
        let samples = drainCapture()
        NSLog("sAiity dictation capture: \(samples.count) samples at \(Int(sessionSampleRate)) Hz (\(String(format: "%.2f", Double(samples.count) / sessionSampleRate))s)")
        if sessionUsesWhisper {
            do {
                if let transcribeWhisperSegments,
                   sessionLocale.identifier == "auto" {
                    let regions = segmenter.segment(samples, sampleRate: sessionSampleRate)
                    NSLog("sAiity dictation transcription: Whisper Auto, \(regions.count) region(s)")
                    guard session == generation, !Task.isCancelled else { return }
                    let transcriptionStarted = ContinuousClock.now
                    let transcription = try await transcribeWhisperSegments(samples,
                                                                              regions,
                                                                              sessionLocale)
                    logDuration("transcription", since: transcriptionStarted)
                    guard session == generation else { return }
                    await finish(transcription: transcription,
                                 session: session,
                                 fallbackSourceLanguage: Locale.current.identifier(.bcp47))
                    return
                }
                let whisperSamples = samples.isEmpty ? [] : [samples]
                guard session == generation, !Task.isCancelled else { return }
                let transcriptionStarted = ContinuousClock.now
                let authoritative = try await transcribeWhisper(whisperSamples, sessionLocale)
                logDuration("transcription", since: transcriptionStarted)
                guard session == generation else { return }
                await finish(authoritative: authoritative, session: session, sourceLanguage: sessionLocale.identifier(.bcp47))
            } catch is CancellationError {
                return
            } catch {
                guard session == generation else { return }
                reportIssue("dictation.transcription", error.localizedDescription)
                phase = .failure(error.localizedDescription)
            }
            return
        }
        guard let backend else {
            if phase == .transcribing {
                reportIssue("dictation.transcription", "No prepared recognition backend was available.")
                phase = .idle
            }
            return
        }
        if let segmented = backend as? any DictationSegmentTranscriber {
            if sessionUsesStreamingDraft {
                if !latestDraftText.isEmpty {
                    onDraft(latestDraftText)
                }
                let sourceLanguage = await backend.detectedLanguage()
                    ?? Locale.current.identifier(.bcp47)
                let authoritative = await backend.finishDictation()?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let text = authoritative.flatMap { $0.isEmpty ? nil : $0 } ?? latestDraftText
                await releaseOwnedBackend(session: session, discard: false)
                guard session == generation else { return }
                await finish(transcription: DictationTranscriptionResult(text: text,
                                                                          language: sourceLanguage),
                             session: session,
                             fallbackSourceLanguage: sourceLanguage)
                return
            }
            do {
                let regions = segmenter.segment(samples, sampleRate: sessionSampleRate)
                NSLog("sAiity dictation transcription: segmented \(regions.count) region(s) with \(backend.name)")
                guard session == generation, !Task.isCancelled else { return }
                let transcriptionStarted = ContinuousClock.now
                let transcription = try await segmented.transcribeDictation(samples: samples,
                                                                              regions: regions)
                logDuration("transcription", since: transcriptionStarted)
                await releaseOwnedBackend(session: session, discard: false)
                guard session == generation else { return }
                await finish(transcription: transcription,
                             session: session,
                             fallbackSourceLanguage: Locale.current.identifier(.bcp47))
            } catch is CancellationError {
                await releaseOwnedBackend(session: session, discard: true)
            } catch {
                await releaseOwnedBackend(session: session, discard: true)
                guard session == generation else { return }
                reportIssue("dictation.transcription", error.localizedDescription)
                phase = .failure(error.localizedDescription)
            }
            return
        }
        let sourceLanguage = await backend.detectedLanguage()
            ?? Locale.current.identifier(.bcp47)
        let transcriptionStarted = ContinuousClock.now
        let authoritative = await backend.finishDictation()
        logDuration("transcription", since: transcriptionStarted)
        await releaseOwnedBackend(session: session, discard: false)
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
        var cleanupUnavailable = false
        var translated = false
        var translationFailed = false
        if cleanupConfiguration().enabled {
            let cleanupStarted = ContinuousClock.now
            defer { logDuration("cleanup", since: cleanupStarted) }
            phase = .cleaning
            // Both cleanup shapes answer the same question — does this candidate
            // keep the transcript's meaning? — so they share one validation.
            // The detailed shape also returns refreshed region metadata, which
            // is what translation should use; the simple shape has none, so it
            // leaves the transcription as it was.
            //
            // This replaces a version that assigned `value = nil` on the
            // detailed path and then tested `if let value` below, so with a
            // detailed handler — which is what production always installs — that
            // branch was unreachable and the validation was written twice.
            var candidate: (text: String, transcription: DictationTranscriptionResult)?
            if let detailedCleanup {
                if let result = await detailedCleanup(transcription) {
                    candidate = (result.text, result)
                }
            } else if let value = await cleanup(text, sourceLanguage) {
                candidate = (value, transcription)
            }

            if let candidate,
               let valid = DictationCleanupValidator.validate(candidate.text,
                                                               preserving: text,
                                                               sourceLanguage: sourceLanguage,
                                                               languageMetadata: metadata) {
                output = valid
                transcriptionForTranslation = candidate.transcription
                cleaned = true
            } else {
                cleanupUnavailable = true
            }
            if cleanupUnavailable {
                reportIssue("dictation.cleanup", "Cleanup unavailable; original transcript preserved.")
            }
        }
        guard session == generation, !Task.isCancelled else { return }
        if configuration.enabled,
           let target = configuration.target?.trimmingCharacters(in: .whitespacesAndNewlines),
           !target.isEmpty {
            phase = .translating
            let translationStarted = ContinuousClock.now
            defer { logDuration("translation", since: translationStarted) }
            let value: String?
            if let detailedTranslate {
                value = await detailedTranslate(output, transcriptionForTranslation, target)
            } else {
                value = await translate(output, sourceLanguage, target)
            }
            guard session == generation, !Task.isCancelled else { return }
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
            if translationFailed {
                reportIssue("dictation.translation", "Translation unavailable; original output preserved.")
            }
        }
        guard session == generation else { return }
        phase = .inserting
        let resultMetadata = translated
            ? DictationLanguageMetadata(regions: [
                .init(text: output, language: configuration.target)
            ])
            : transcriptionForTranslation.languageMetadata
        if let releaseStarted { logDuration("release-to-result", since: releaseStarted) }
        onResult(DictationResultSnapshot(rawText: text,
                                         outputText: output,
                                         wasCleaned: cleaned,
                                         wasTranslated: translated,
                                         languageMetadata: resultMetadata,
                                         cleanupUnavailable: cleanupUnavailable))
        let result = inserter.insert(output)
        if let releaseStarted { logDuration("release-to-insert", since: releaseStarted) }
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

    private func logDuration(_ phase: String, since start: ContinuousClock.Instant) {
        let elapsed = start.duration(to: .now).components
        let seconds = Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18
        NSLog("sAiity dictation timing: %@ %.3fs", phase, seconds)
        onTiming(phase, seconds, nil)
    }

    private func reportIssue(_ operation: String, _ reason: String) {
        onIssue(operation, reason)
    }

    private func failStart(session: Int, message: String?) async {
        _ = drainCapture()
        // Only the session that holds the lease may tear it down. A start that
        // failed *without* acquiring anything must leave the pool alone: the
        // lease it can see belongs to the session that is still transcribing.
        await releaseOwnedBackend(session: session, discard: true)
        guard session == generation else { return }
        state.cancel()
        if let message {
            reportIssue("dictation.start", message)
            phase = .failure(message)
        } else {
            phase = .idle
        }
    }

    /// Return the lease, but only if it is still the one `session` took.
    ///
    /// The guard is the whole point. `backend` is a single slot shared by every
    /// generation, and a start that failed while a previous session was still
    /// finishing used to read the *previous* session's backend out of it and
    /// discard it — killing an utterance mid-sentence from a keystroke the user
    /// did not know was a second session.
    private func releaseOwnedBackend(session: Int, discard: Bool) async {
        guard let active = backend, backendSession == session else { return }
        backend = nil
        backendSession = nil
        await backendProvider.release(active, discard: discard)
    }

    private func drainCapture() -> [Float] {
        guard !captureDrained else { return [] }
        captureDrained = true
        capture.setWaveformHandler(nil)
        capture.stop()
        return capture.takeCollectedSamples()
    }

    private func resetDraft() {
        draftFinalText = ""
        draftVolatileText = ""
        latestDraftText = ""
    }

    private func receiveDraft(_ chunk: TranscriptChunk, session: Int) {
        guard session == generation, state.isActive, sessionUsesStreamingDraft else { return }
        if chunk.isFinal {
            draftFinalText = DictationTranscriptMerger.merge([draftFinalText, chunk.text])
            draftVolatileText = ""
        } else {
            draftVolatileText = chunk.text
        }
        latestDraftText = DictationTranscriptMerger.merge([draftFinalText, draftVolatileText])
        // Push every update, not only the one handed over at the stop. The
        // controller reports what it has; whether that reaches the screen is
        // the phase's and the setting's call in `showDictationDraft`. Withholding
        // it here would put that decision in two places — and is what kept the
        // words invisible while they were still being spoken.
        if !latestDraftText.isEmpty {
            onDraft(latestDraftText)
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
