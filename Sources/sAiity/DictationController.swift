import AVFoundation
import Foundation

protocol DictationAudioCapture: AnyObject {
    var inputHealth: DictationInputHealth? { get }
    var collectedSamples: [[Float]] { get }
    func start(targetFormat: AVAudioFormat,
               onBuffer: @escaping @Sendable (AVAudioPCMBuffer) -> Void) throws
    func stop()
    func takeCollectedSamples() -> [Float]
    func setLimitHandler(_ handler: (@Sendable () -> Void)?)
    func setWaveformHandler(_ handler: (@Sendable ([Float]) -> Void)?)
}

extension DictationAudioCapture {
    var inputHealth: DictationInputHealth? { nil }
    var collectedSamples: [[Float]] { [] }
    func takeCollectedSamples() -> [Float] { [] }
    func setLimitHandler(_ handler: (@Sendable () -> Void)?) {}
    func setWaveformHandler(_ handler: (@Sendable ([Float]) -> Void)?) {}
}

extension DictationMicrophoneCapture: DictationAudioCapture {}

@MainActor
protocol DictationTextInsertion: AnyObject {
    func captureFocus() -> DictationFocusToken?
    func insert(_ text: String, expecting expected: DictationFocusToken?) -> TextInsertionResult
    func insert(_ text: String) -> TextInsertionResult
}

extension TextInserter: DictationTextInsertion {}

/// Whether dictation may open the microphone, and the way to ask.
///
/// macOS shows its microphone prompt only when an app asks for access. The
/// shortcut path used to skip asking, so on a fresh install (or after the
/// permission was reset) a press either recorded silence or did nothing, with
/// no prompt and no message — only "Try Dictation" in setup ever asked.
struct MicrophoneAccess: Sendable {
    var status: @Sendable () -> AVAuthorizationStatus
    var request: @Sendable (@escaping @Sendable (Bool) -> Void) -> Void

    static let system = MicrophoneAccess(
        status: { AVCaptureDevice.authorizationStatus(for: .audio) },
        request: { answer in AVCaptureDevice.requestAccess(for: .audio, completionHandler: answer) })

    /// For tests and previews that drive a fake capture.
    static let granted = MicrophoneAccess(status: { .authorized }, request: { $0(true) })
}

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
    typealias DeliveryHandler = (DictationResultSnapshot, TextInsertionResult, UUID) -> Void
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
    private let modelRemovalActive: () -> Bool
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
    private let originalTextApplications: () -> Set<String>
    private let onDelivered: DeliveryHandler
    private let onRunTiming: (DiagnosticsRuntimeTiming) -> Void
    private let microphoneAccess: MicrophoneAccess
    private var awaitingMicrophoneAnswer = false
    /// Set by `cancelPress()`: the recording finishes through the normal path,
    /// so the warm model is returned exactly as after a real dictation, but
    /// nothing is inserted, copied or shown.
    private var deliveryCancelled = false

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
    private var sessionIsTrial = false
    private var sessionFocus: DictationFocusToken?
    private var sessionUsesOriginalText = false
    private(set) var currentRunID: UUID?
    private var runStarted: ContinuousClock.Instant?
    private var runFallbackReason: String?
    private var sessionUsesStreamingDraft = false
    private var sessionLocale = Locale.current
    private var sessionSampleRate = 16_000.0
    private var captureDrained = true
    private let captureSink = BackendSink()
    private var releasedSamples: [Float]?
    private var authoritativeTask: Task<Void, Never>?
    private var completedSpeechRegions: [DictationSpeechRegion] = []
    #if SAIITY_TEST_HOOKS
    var completedSampleRangesForTests: [Range<Int>] { completedSpeechRegions.map(\.coveredRange) }
    #endif
    private var completedTranscripts: [DictationRegionTranscript] = []
    private var lastRecognizedAudioEnd = 0
    private var nextRegionCheck = 0
    private var draftFinalText = ""
    private var draftVolatileText = ""
    private var latestDraftText = ""
    private(set) var phase: DictationPhase = .idle {
        didSet {
            guard phase != oldValue else { return }
            if case .failure = phase { finishRun(outcome: "failed") }
            onPhaseChanged(phase)
        }
    }

    /// Shown instead of the result when the text could only be copied because
    /// Accessibility is off: the words are on the clipboard, and this is the
    /// one thing that makes the next dictation paste by itself.
    static var accessibilityHint: String {
        String(localized: "Copied. Allow Accessibility in Syllivra's settings to paste automatically.")
    }

    static var quietInputMessage: String {
        String(localized: "Syllivra heard almost nothing. Check the microphone and its input level in Sound settings.")
    }

    /// Below about −50 dBFS for a recording long enough to judge, the input
    /// was close to silence rather than quiet speech.
    nonisolated static func inputWasNearlySilent(_ health: DictationInputHealth?) -> Bool {
        guard let health, health.observedDuration >= 0.5,
              let rms = health.rmsDBFS, !rms.isNaN else { return false }
        return rms < -50
    }

    var isActive: Bool { state.isActive }
    var isDiscardingDelivery: Bool { deliveryCancelled }
    var inputHealth: DictationInputHealth? { capture.inputHealth }
    var isUsingOriginalText: Bool { sessionUsesOriginalText && (isActive || isFinishing) }

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
        case .limit, .transcribing, .cleaning, .translating, .inserting: return true
        case .idle, .waitingForInputMonitoring, .preparing, .ready, .starting,
             .dictating, .recovery, .result, .failure, .needsPermission:
            return false
        }
    }

    /// True while dictation still owns work that can touch the translator. The
    /// key is released before transcription and translation finish, so
    /// `isActive` alone is not enough for model-lifecycle decisions.
    var isBusy: Bool {
        switch phase {
        case .preparing, .starting, .dictating, .limit, .transcribing, .cleaning, .translating, .inserting:
            return true
        case .idle, .waitingForInputMonitoring, .ready, .recovery, .result, .failure, .needsPermission:
            return false
        }
    }

    init(makeBackend: @escaping BackendFactory,
         capture: any DictationAudioCapture,
         inserter: any DictationTextInsertion,
         captionsActive: @escaping () -> Bool,
         modelRemovalActive: @escaping () -> Bool = { false },
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
         onPhaseChanged: @escaping (DictationPhase) -> Void = { _ in },
         originalTextApplications: @escaping () -> Set<String> = { [] },
         onDelivered: @escaping DeliveryHandler = { _, _, _ in },
         onRunTiming: @escaping (DiagnosticsRuntimeTiming) -> Void = { _ in },
         microphoneAccess: MicrophoneAccess = .granted) {
        self.backendProvider = SingleBackendProvider(makeBackend: makeBackend)
        self.capture = capture
        self.inserter = inserter
        self.captionsActive = captionsActive
        self.modelRemovalActive = modelRemovalActive
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
        self.originalTextApplications = originalTextApplications
        self.onDelivered = onDelivered
        self.onRunTiming = onRunTiming
        self.microphoneAccess = microphoneAccess
    }

    init(backendProvider: any ASRBackendProvider,
         capture: any DictationAudioCapture,
         inserter: any DictationTextInsertion,
         captionsActive: @escaping () -> Bool,
         modelRemovalActive: @escaping () -> Bool = { false },
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
         onPhaseChanged: @escaping (DictationPhase) -> Void = { _ in },
         originalTextApplications: @escaping () -> Set<String> = { [] },
         onDelivered: @escaping DeliveryHandler = { _, _, _ in },
         onRunTiming: @escaping (DiagnosticsRuntimeTiming) -> Void = { _ in },
         microphoneAccess: MicrophoneAccess = .granted) {
        self.backendProvider = backendProvider
        self.capture = capture
        self.inserter = inserter
        self.captionsActive = captionsActive
        self.modelRemovalActive = modelRemovalActive
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
        self.originalTextApplications = originalTextApplications
        self.onDelivered = onDelivered
        self.onRunTiming = onRunTiming
        self.microphoneAccess = microphoneAccess
    }

    /// Starts ASR preparation without opening the microphone. Calling this more
    /// than once joins the same single-flight task and never creates a second
    /// backend.
    func prepare() {
        guard !modelRemovalActive(), !dictationUsesWhisper(),
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

    func completeCopyRecovery() {
        guard !state.isActive, case .recovery = phase else { return }
        phase = .result(String(localized: "Copied to Clipboard"))
    }

    /// Keeps the missing global-key permission visible instead of making the
    /// shortcut look dead while the monitor retries in the background.
    func markWaitingForInputMonitoring() {
        guard !state.isActive else { return }
        phase = .waitingForInputMonitoring
    }

    func press(previewOnly: Bool = false) {
        guard !state.isActive else { return }
        // One session at a time, all the way through. A press while the
        // previous release is still transcribing, cleaning, translating or
        // inserting is not a second recording — it is two sessions contending
        // for one shared, exclusively-leased backend.
        guard !isFinishing else { return }
        guard !modelRemovalActive() else {
            phase = .failure(String(localized: "Model files are being removed. Wait for that to finish."))
            return
        }
        guard !captionsActive() else {
            phase = .failure(String(localized: "Captions are already running."))
            return
        }
        guard microphoneIsAvailable() else { return }
        guard state.begin() else { return }
        deliveryCancelled = false

        sessionIsTrial = previewOnly
        sessionFocus = previewOnly ? nil : inserter.captureFocus()
        sessionUsesOriginalText = !previewOnly && usesOriginalText(bundleIdentifier: sessionFocus?.bundleIdentifier,
                                                                  exceptions: originalTextApplications())
        let runID = previewOnly ? nil : UUID()
        currentRunID = runID
        runStarted = previewOnly ? nil : .now
        runFallbackReason = nil
        processingDeadline = nil
        generation += 1
        let session = generation
        sessionUsesWhisper = dictationUsesWhisper()
        sessionUsesStreamingDraft = !sessionUsesWhisper && dictationStreamingDraftEnabled()
        resetDraft()
        sessionLocale = sessionUsesWhisper ? Locale(identifier: WhisperDictationBackend.locale) : Locale.current
        captureDrained = false
        releasedSamples = nil
        completedSpeechRegions = []
        completedTranscripts = []
        lastRecognizedAudioEnd = 0
        nextRegionCheck = 0
        if sessionUsesWhisper && !whisperIsReady() {
            state.cancel()
            phase = .failure(String(localized: "Not ready"))
            return
        }
        terminal = .open
        let wasReady = phase == .ready
        phase = .starting
        do {
            guard let format = audioFormatFactory(), format.sampleRate == 16_000,
                  format.channelCount == 1, format.commonFormat == .pcmFormatFloat32 else {
                throw BackendError.notPrepared
            }
            sessionSampleRate = format.sampleRate
            captureSink.point(at: nil, buffering: !sessionUsesWhisper)
            capture.setLimitHandler { [weak self] in
                Task { @MainActor in self?.limit(session: session) }
            }
            capture.setWaveformHandler(onWaveform)
            let sink = captureSink
            let captureStarted = ContinuousClock.now
            try capture.start(targetFormat: format) { [weak self] buffer in
                sink.feed(buffer)
                Task { @MainActor [weak self] in self?.scheduleAuthoritativeRegions(session: session) }
            }
            logDuration("capture-start", since: captureStarted, runID: runID)
            phase = .dictating
        } catch {
            _ = drainCapture()
            captureSink.point(at: nil)
            state.cancel()
            reportIssue("dictation.start", error.localizedDescription)
            phase = .failure(error.localizedDescription)
            return
        }
        if !sessionUsesWhisper, !wasReady, preparationTask == nil {
            beginPreparation()
        }
        startupTask = Task { @MainActor [weak self] in
            await LocalGeneration.$dictationRunID.withValue(runID?.uuidString) {
                await self?.start(session: session)
            }
        }
    }

    /// True when the microphone may be opened now. Otherwise asks macOS (the
    /// first time) or explains where to turn it on, and the press does nothing
    /// else: the key is usually released before anyone answers a prompt.
    private func microphoneIsAvailable() -> Bool {
        switch microphoneAccess.status() {
        case .authorized:
            return true
        case .notDetermined:
            guard !awaitingMicrophoneAnswer else { return false }
            awaitingMicrophoneAnswer = true
            phase = .needsPermission(String(localized: "Allow microphone access to dictate."))
            microphoneAccess.request { [weak self] granted in
                Task { @MainActor in self?.microphoneAnswered(granted) }
            }
            return false
        default:
            reportIssue("dictation.microphone", "Microphone access is off")
            phase = .needsPermission(String(localized: "Microphone access is off. Turn on Syllivra in System Settings → Privacy & Security → Microphone."))
            return false
        }
    }

    /// Ends the current recording without delivering it.
    ///
    /// For a modifier-only shortcut that turned out to be part of another
    /// shortcut (⌃⌥→) or was only tapped. `cancel()` would also throw away the
    /// prepared model, making the next real dictation start cold.
    func cancelPress() {
        guard state.isActive else { return }
        deliveryCancelled = true
        release()
    }

    private func microphoneAnswered(_ granted: Bool) {
        awaitingMicrophoneAnswer = false
        guard !state.isActive else { return }
        phase = granted
            ? .needsPermission(String(localized: "Microphone allowed. Hold the shortcut again to dictate."))
            : .needsPermission(String(localized: "Microphone access is off. Turn on Syllivra in System Settings → Privacy & Security → Microphone."))
    }

    func release() {
        guard state.release(), terminal.accept(.released) else { return }
        releaseStarted = .now
        releasedSamples = drainCapture()
        let session = generation
        let runID = currentRunID
        let deadline = LocalGeneration.deadline ?? .now.advanced(by: .seconds(15))
        processingDeadline = deadline
        phase = .transcribing
        releaseTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await LocalGeneration.$dictationRunID.withValue(runID?.uuidString) {
                await LocalGeneration.$deadline.withValue(deadline) {
                    await self.startupTask?.value
                    await self.authoritativeTask?.value
                    await self.finish(session: session)
                }
            }
        }
    }

    /// Cancels both a live microphone session and a background/prepared ASR
    /// backend. The async companion below is used when model files are about to
    /// be deleted and must not return until the backend has really stopped.
    func cancel() {
        finishRun(outcome: "cancelled")
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
        authoritativeTask?.cancel()
        _ = drainCapture()
        releasedSamples = nil
        captureSink.point(at: nil)

        let preparation = preparationTask
        let startup = startupTask
        let release = releaseTask
        let authoritative = authoritativeTask
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
            await authoritative?.value
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
        releasedSamples = drainCapture()
        state.cancel()
        // Say the recording was cut. This used to go straight to `.transcribing`,
        // which left `DictationPhase.limit` — and its "Limit reached" wording —
        // unreachable: a user who held the key past the cap had their audio
        // truncated with nothing on screen explaining why the result was short.
        // `finish` moves on to `.transcribing` as soon as it starts working.
        phase = .limit
        let runID = currentRunID
        let deadline = LocalGeneration.deadline ?? .now.advanced(by: .seconds(15))
        processingDeadline = deadline
        releaseTask = Task { @MainActor [weak self] in
            await LocalGeneration.$dictationRunID.withValue(runID?.uuidString) {
                await LocalGeneration.$deadline.withValue(deadline) {
                    await self?.startupTask?.value
                    await self?.authoritativeTask?.value
                    await self?.finish(session: session)
                }
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
        let runID = currentRunID
        let previousCleanup = cleanupTask
        preparationTask = Task { @MainActor [weak self, previousCleanup] in
            await previousCleanup?.value
            guard !Task.isCancelled else { return }
            await LocalGeneration.$dictationRunID.withValue(runID?.uuidString) {
                await self?.runPreparation(token: token, runID: runID)
            }
        }
    }

    private func runPreparation(token: Int, runID: UUID?) async {
        let started = ContinuousClock.now
        defer { logDuration("preparation", since: started, runID: runID) }
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
            _ = drainCapture()
            captureSink.point(at: nil)
            reportIssue("dictation.prepare", error.localizedDescription)
            phase = .failure(error.localizedDescription)
        }
    }

    private func start(session: Int) async {
        guard session == generation else { return }
        let runID = currentRunID
        if let preparationTask {
            let waiting = ContinuousClock.now
            await preparationTask.value
            logDuration("preparation-wait", since: waiting, runID: runID)
        }
        guard session == generation else { return }
        guard state.isActive || phase == .transcribing || phase == .limit else { return }
        let progress: @Sendable (String) -> Void = { _ in }
        do {
            if processingDeadlineExpired { throw CancellationError() }
            try LocalGeneration.checkDeadline()
            if sessionUsesWhisper {
                scheduleAuthoritativeRegions(session: session)
                return
            }
            let acquired = try await backendProvider.acquire(locale: Locale.current,
                                                              progress: progress)
            guard session == generation, !processingDeadlineExpired else {
                // This lease is unambiguously ours — nothing else can hold the
                // pool's single active slot — so it can be discarded even
                // though a newer session exists.
                await backendProvider.release(acquired, discard: true)
                return
            }
            backend = acquired
            backendSession = session
            acquired.setFailureHandler { [weak self] reason in
                Task { @MainActor in
                    guard let self, session == self.generation else { return }
                    self.finishRun(outcome: "failed")
                    self.cancel()
                    self.reportIssue("dictation.transcription", reason)
                    self.phase = .failure(reason)
                }
            }
            guard let format = await acquired.inputFormat,
                  format.sampleRate == sessionSampleRate,
                  format.channelCount == 1, format.commonFormat == .pcmFormatFloat32 else {
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
            if processingDeadlineExpired { throw CancellationError() }
            captureSink.point(at: deferred ? nil : acquired)
            phase = state.isActive ? .dictating : .transcribing
            scheduleAuthoritativeRegions(session: session)
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
    private var processingDeadline: ContinuousClock.Instant?

    private var processingDeadlineExpired: Bool {
        processingDeadline.map { ContinuousClock.now >= $0 } ?? false
    }

    private func reportProcessingTimeout(session: Int) {
        guard session == generation, processingDeadlineExpired else { return }
        runFallbackReason = "deadline-exhausted"
        phase = .failure(String(localized: "Recognition took too long. Please try again."))
    }

    private func scheduleAuthoritativeRegions(session: Int) {
        guard session == generation, state.isActive, authoritativeTask == nil,
              (backend is any DictationSegmentTranscriber
               || (sessionUsesWhisper && sessionLocale.identifier == "auto" && transcribeWhisperSegments != nil)),
              (capture.inputHealth?.sampleCount ?? capture.collectedSamples.first?.count ?? 0) >= nextRegionCheck,
              let samples = capture.collectedSamples.first,
              samples.count >= nextRegionCheck else { return }
        nextRegionCheck = samples.count + Int(sessionSampleRate / 2)
        let regions = segmenter.completedRegions(samples, sampleRate: sessionSampleRate)
        guard regions.count > completedSpeechRegions.count,
              Array(regions.prefix(completedSpeechRegions.count)) == completedSpeechRegions else { return }
        let pending = Array(regions.dropFirst(completedSpeechRegions.count))
        let runID = currentRunID
        // Preview work remains provisional; its pump drains before authoritative decoding.
        if sessionUsesStreamingDraft { captureSink.point(at: nil) }
        authoritativeTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.authoritativeTask = nil }
            do {
                for region in pending {
                    try Task.checkCancellation()
                    let started = ContinuousClock.now
                    let result = try await LocalGeneration.$dictationRunID.withValue(runID?.uuidString) {
                        try await self.decodeRegion(samples: samples, region: region)
                    }
                    self.logDuration("recognition-region", since: started, runID: runID)
                    guard session == self.generation, !Task.isCancelled else { return }
                    self.acceptRegion(result, region: region)
                }
                if self.state.isActive, self.sessionUsesStreamingDraft, let backend = self.backend {
                    self.draftFinalText = DictationTranscriptionResult(regions: self.completedTranscripts).text
                    self.draftVolatileText = ""
                    try await backend.start { [weak self] chunk in
                        Task { @MainActor in self?.receiveDraft(chunk, session: session) }
                    }
                    guard session == self.generation, self.state.isActive, !Task.isCancelled else { return }
                    self.captureSink.point(at: backend)
                }
            } catch is CancellationError {
                return
            } catch {
                guard session == self.generation else { return }
                // An incomplete prefix is never used as final output; finish retries the full source.
                self.completedSpeechRegions = []
                self.completedTranscripts = []
                self.lastRecognizedAudioEnd = 0
                self.reportIssue("dictation.recognition-region", error.localizedDescription)
            }
        }
    }

    private func decodeRegion(samples: [Float], region: DictationSpeechRegion) async throws -> DictationTranscriptionResult {
        let deadline = [processingDeadline, LocalGeneration.deadline].compactMap { $0 }.min()
        return try await LocalGeneration.$deadline.withValue(deadline) {
            try LocalGeneration.checkDeadline()
            let result: DictationTranscriptionResult
            if sessionUsesWhisper, let transcribeWhisperSegments {
                result = try await transcribeWhisperSegments(samples, [region], sessionLocale)
            } else {
                guard let segmented = backend as? any DictationSegmentTranscriber else { throw BackendError.notPrepared }
                result = try await segmented.transcribeDictation(samples: samples, regions: [region])
            }
            try LocalGeneration.checkDeadline()
            // A recording-time call can outlive the later release deadline.
            if processingDeadlineExpired { throw CancellationError() }
            return result
        }
    }

    private func acceptRegion(_ result: DictationTranscriptionResult, region: DictationSpeechRegion) {
        var transcripts = result.regions
        if let first = transcripts.first, lastRecognizedAudioEnd > region.audioRange.lowerBound {
            transcripts[0] = .init(text: first.text, language: first.language, overlapsPreviousAudio: true)
        }
        if !transcripts.isEmpty { lastRecognizedAudioEnd = region.audioRange.upperBound }
        completedTranscripts += transcripts
        completedSpeechRegions.append(region)
    }

    private func finishRegions(samples: [Float], regions: [DictationSpeechRegion], session: Int) async throws -> DictationTranscriptionResult {
        guard session == generation else { throw CancellationError() }
        if Array(regions.prefix(completedSpeechRegions.count)) != completedSpeechRegions {
            completedSpeechRegions = []
            completedTranscripts = []
            lastRecognizedAudioEnd = 0
        }
        for region in regions.dropFirst(completedSpeechRegions.count) {
            try Task.checkCancellation()
            let result = try await decodeRegion(samples: samples, region: region)
            guard session == generation, !Task.isCancelled else { throw CancellationError() }
            acceptRegion(result, region: region)
        }
        return DictationTranscriptionResult(regions: completedTranscripts)
    }

    private func finish(session: Int) async {
        guard session == generation else { return }
        let runID = currentRunID
        // The cap explains itself, then gets out of the way. Only the limited
        // path needs this — a normal release already said `.transcribing` when
        // the key came up.
        if phase == .limit { phase = .transcribing }
        let samples = releasedSamples ?? drainCapture()
        releasedSamples = nil
        captureSink.point(at: nil)
        if processingDeadlineExpired {
            await releaseOwnedBackend(session: session, discard: true)
            reportProcessingTimeout(session: session)
            return
        }
        NSLog("sAiity dictation capture: \(samples.count) samples at \(Int(sessionSampleRate)) Hz (\(String(format: "%.2f", Double(samples.count) / sessionSampleRate))s)")
        if sessionUsesWhisper {
            do {
                if transcribeWhisperSegments != nil,
                   sessionLocale.identifier == "auto" {
                    let regions = segmenter.segment(samples, sampleRate: sessionSampleRate)
                    NSLog("sAiity dictation transcription: Whisper Auto, \(regions.count) region(s)")
                    guard session == generation, !Task.isCancelled else { return }
                    let transcriptionStarted = ContinuousClock.now
                    let transcription = try await finishRegions(samples: samples, regions: regions, session: session)
                    logDuration("transcription", since: transcriptionStarted, runID: runID)
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
                logDuration("transcription", since: transcriptionStarted, runID: runID)
                guard session == generation else { return }
                await finish(authoritative: authoritative, session: session, sourceLanguage: sessionLocale.identifier(.bcp47))
            } catch is CancellationError {
                reportProcessingTimeout(session: session)
                return
            } catch {
                guard session == generation else { return }
                reportIssue("dictation.transcription", error.localizedDescription)
                phase = .failure(error.localizedDescription)
            }
            return
        }
        guard let backend else {
            finishRun(outcome: "failed")
            if phase == .transcribing {
                reportIssue("dictation.transcription", "No prepared recognition backend was available.")
                phase = .idle
            }
            return
        }
        if backend is any DictationSegmentTranscriber {
            if sessionUsesStreamingDraft {
                if !latestDraftText.isEmpty {
                    onDraft(latestDraftText)
                }
            }
            do {
                let regions = segmenter.segment(samples, sampleRate: sessionSampleRate)
                NSLog("sAiity dictation transcription: segmented \(regions.count) region(s) with \(backend.name)")
                guard session == generation, !Task.isCancelled else { return }
                let transcriptionStarted = ContinuousClock.now
                let transcription = try await finishRegions(samples: samples, regions: regions, session: session)
                logDuration("transcription", since: transcriptionStarted, runID: runID)
                await releaseOwnedBackend(session: session, discard: false)
                guard session == generation else { return }
                await finish(transcription: transcription,
                             session: session,
                             fallbackSourceLanguage: Locale.current.identifier(.bcp47))
            } catch is CancellationError {
                await releaseOwnedBackend(session: session, discard: true)
                reportProcessingTimeout(session: session)
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
        logDuration("transcription", since: transcriptionStarted, runID: runID)
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
        if deliveryCancelled {
            deliveryCancelled = false
            finishRun(outcome: "cancelled")
            phase = .idle
            return
        }
        if processingDeadlineExpired {
            reportProcessingTimeout(session: session)
            return
        }
        let runID = currentRunID
        let authoritativeText = transcription.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !authoritativeText.isEmpty else {
            // Say why when the reason is visible in the audio: a microphone
            // turned down, muted or pointed elsewhere records near-silence,
            // and "No speech detected" alone sends people looking for a bug.
            let quiet = Self.inputWasNearlySilent(capture.inputHealth)
            finishRun(outcome: "failed", fallback: quiet ? "quiet-input" : "no-speech")
            phase = .result(quiet ? Self.quietInputMessage : String(localized: "No speech detected"))
            return
        }
        let transcription = sessionUsesOriginalText ? transcription : DictationVocabulary.applying(to: transcription)
        let text = transcription.text
        let configuration = sessionUsesOriginalText ? .disabled : translationConfiguration()
        let metadata = transcription.languageMetadata
        let sourceLanguage = metadata.dominantLanguage ?? fallbackSourceLanguage
        var output = text
        var transcriptionForTranslation = transcription
        var cleaned = false
        var cleanupUnavailable = false
        var translated = false
        var translationFailed = false
        if !sessionUsesOriginalText, cleanupConfiguration().enabled,
           LocalGeneration.deadline.map({ ContinuousClock.now < $0 }) ?? true {
            let cleanupStarted = ContinuousClock.now
            defer { logDuration("cleanup", since: cleanupStarted, runID: runID) }
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

            guard session == generation, !Task.isCancelled else { return }

            if let candidate,
               let valid = DictationCleanupValidator.validate(candidate.text,
                                                               preserving: text,
                                                               sourceLanguage: sourceLanguage,
                                                               languageMetadata: metadata) {
                output = valid
                transcriptionForTranslation = candidate.transcription
                cleaned = true
                cleanupUnavailable = candidate.transcription.modelCleanupUnavailable
            } else {
                cleanupUnavailable = true
            }
            if cleanupUnavailable {
                runFallbackReason = candidate == nil || candidate?.transcription.modelCleanupUnavailable == true
                    ? "cleanup-unavailable" : "validation-rejected"
                reportIssue("dictation.cleanup", "Model cleanup unavailable; safe text preserved.")
            }
        }
        guard session == generation, !Task.isCancelled else { return }
        if configuration.enabled,
           LocalGeneration.deadline.map({ ContinuousClock.now < $0 }) ?? true,
           let target = configuration.target?.trimmingCharacters(in: .whitespacesAndNewlines),
           !target.isEmpty {
            phase = .translating
            let translationStarted = ContinuousClock.now
            defer { logDuration("translation", since: translationStarted, runID: runID) }
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
                runFallbackReason = "translation-unavailable"
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
        if let releaseStarted { logDuration("release-to-result", since: releaseStarted, runID: runID) }
        let snapshot = DictationResultSnapshot(rawText: authoritativeText,
                                         outputText: output,
                                         wasCleaned: cleaned,
                                         wasTranslated: translated,
                                         languageMetadata: resultMetadata,
                                         cleanupUnavailable: cleanupUnavailable)
        onResult(snapshot)
        guard session == generation, !Task.isCancelled else { return }
        // Setup trials use the complete pipeline without touching another app
        // or replacing the person's clipboard.
        if sessionIsTrial {
            phase = .result(String(localized: "Trial complete"))
            return
        }
        guard let deliveryID = currentRunID else { return }
        let deliveryStarted = ContinuousClock.now
        let result = inserter.insert(output, expecting: sessionFocus)
        logDuration("delivery", since: deliveryStarted, runID: runID)
        if let releaseStarted { logDuration("release-to-insert", since: releaseStarted, runID: runID) }
        switch result.outcome {
        case .copyFailed:
            reportIssue("dictation.clipboard", "Clipboard write failed; result retained in the bubble.")
            phase = .recovery(String(localized: "Copy failed — use Retry Copy in the bubble."))
        case .insertedAndCopied:
            if translated {
                phase = .result(String(localized: "Translated and copied — paste requested"))
            } else if translationFailed {
                phase = .result(String(localized: cleaned ? "Translation unavailable — cleaned text copied; paste requested" : "Translation unavailable — original copied; paste requested"))
            } else {
                phase = .result(String(localized: "Copied — paste requested"))
            }
        case .copied:
            if translated {
                phase = .result(String(localized: "Translated and copied"))
            } else if translationFailed {
                phase = .result(String(localized: cleaned ? "Translation unavailable — cleaned text copied to Clipboard" : "Translation unavailable — original copied to Clipboard"))
            } else if result.accessibilityMissing {
                phase = .result(Self.accessibilityHint)
            } else {
                phase = .result(String(localized: "Copied to Clipboard"))
            }
        }
        let outcome: String
        switch result.outcome {
        case .insertedAndCopied: outcome = "paste-dispatched"
        case .copied: outcome = "copied"
        case .copyFailed: outcome = "copy-failed"
        }
        finishRun(outcome: outcome)
        onDelivered(snapshot, result, deliveryID)
    }

    private func logDuration(_ phase: String, since start: ContinuousClock.Instant, runID: UUID?) {
        let elapsed = start.duration(to: .now).components
        let seconds = Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18
        NSLog("sAiity dictation timing: %@ %.3fs", phase, seconds)
        onTiming(phase, seconds, nil)
        guard let runID, runID == currentRunID, !Task.isCancelled else { return }
        onRunTiming(.init(date: Date(), operation: "dictation.\(phase)", seconds: seconds,
                          runID: runID.uuidString))
    }

    private func finishRun(outcome: String, fallback: String? = nil) {
        guard let id = currentRunID, let started = runStarted else { return }
        currentRunID = nil
        runStarted = nil
        let elapsed = started.duration(to: .now).components
        let seconds = Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18
        onRunTiming(.init(date: Date(), operation: "dictation.total", seconds: seconds,
                          runID: id.uuidString, outcome: outcome,
                          fallbackReason: fallback ?? runFallbackReason))
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
        let drained = ContinuousClock.now
        let runID = currentRunID
        active.setFailureHandler(nil)
        backend = nil
        backendSession = nil
        await backendProvider.release(active, discard: discard)
        logDuration("drain", since: drained, runID: runID)
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
        await authoritativeTask?.value
        await releaseTask?.value
        await cleanupTask?.value
    }
    #endif
}
