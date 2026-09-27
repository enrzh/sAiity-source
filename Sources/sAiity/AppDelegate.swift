import AppKit
import Sparkle
import AVFoundation
import CoreGraphics
import Foundation
import NaturalLanguage
import UniformTypeIdentifiers

/// Menu-bar app. No dock icon, no main window — just the caption bar.
///
/// Isolated to the main actor as a whole. Everything here is AppKit or drives
/// AppKit, and the alternative — a nonisolated class with `assumeIsolated` at
/// each entry point — let `beginRecording()` and `endRecording()` mutate an
/// NSView hierarchy and the status-item image from a cooperative-pool thread
/// after their first `await`. The compiler warned about it; nothing enforced it.
/// Class-level isolation makes that a build error instead.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    #if SAIITY_TEST_HOOKS
    var whisperPreparationForTests: (@Sendable (WhisperDictationBackend.ModelChoice, @escaping @Sendable (Progress) -> Void) async throws -> Void)?
    #endif
    private var statusItem: NSStatusItem!
    /// Launch Services may deliver an open URL before AppKit has finished
    /// launching the delegate. Queue it until the status item and menu exist.
    private var launchFinished = false
    private var pendingOpenURLs: [URL] = []
    /// Sparkle. The standard controller drives the whole flow — check, consent,
    /// download, staged install — against the appcast in Info.plist. Automatic
    /// checks are off until the user opts in.
    private lazy var updater = SPUStandardUpdaterController(startingUpdater: true,
                                                            updaterDelegate: nil,
                                                            userDriverDelegate: nil)
    private let overlay = OverlayWindow()
    private let dictationToast = DictationToastWindow(contentRect: .zero,
                                                       styleMask: [.borderless],
                                                       backing: .buffered,
                                                       defer: false)
    private let dictationCapture = DictationMicrophoneCapture()
    private lazy var waveformDelivery = WaveformUpdateCoalescer { [weak self] levels in
        self?.dictationToast.updateWaveform(levels)
    }
    private var dictationHotkeyRetryTask: Task<Void, Never>?
    /// Captions and push-to-talk share this one prepared backend. The pool owns
    /// the warm model; callers hold only a temporary lease while feeding audio.
    private lazy var asrBackendPool = ASRBackendPool(makeBackend: AppDelegate.makeActiveBackend)
    private lazy var dictationBackendPool = ASRBackendPool(makeBackend: AppDelegate.makeDictationStreamingBackend)
    private lazy var dictationController: DictationController = {
        let waveformDelivery = self.waveformDelivery
        return DictationController(
        backendProvider: dictationBackendPool,
        capture: dictationCapture,
        inserter: TextInserter(),
        captionsActive: { [weak self] in self?.state.isActive ?? false },
        translationConfiguration: { [weak self] in
            self?.dictationTranslationConfiguration() ?? .disabled
        },
        translate: { [weak self] text, source, target in
            guard let self else { return nil }
            return await self.translateDictatedText(text, source: source, target: target)
        },
        detailedTranslate: { [weak self] text, transcription, target in
            guard let self else { return nil }
            return await self.translateDictatedText(text,
                                                    transcription: transcription,
                                                    target: target)
        },
        cleanupConfiguration: {
            DictationCleanupConfiguration(
                enabled: UserDefaults.standard.object(forKey: "dictationCleanupEnabled") as? Bool ?? true)
        },
        cleanup: { [weak self] text, sourceLanguage in
            await self?.cleanupDictatedText(text, sourceLanguage: sourceLanguage)
        },
        detailedCleanup: { [weak self] transcription in
            await self?.cleanupDictatedText(transcription)
        },
        onResult: { [weak self] result in
            self?.lastDictationResult = result
        },
        onDraft: { [weak self] text in
            self?.showDictationDraft(text)
        },
        onWaveform: { levels in
            waveformDelivery.submit(levels)
        },
        dictationUsesWhisper: { DictationRecognizer.selected == .whisper },
        dictationStreamingDraftEnabled: {
            DictationRecognizer.selected == .streaming
                && SettingsWindowController.state.dictationProfile == .fast
                && !SettingsWindowController.state.dictationCleanupEnabled
                && !SettingsWindowController.state.translateDictation
        },
        transcribeWhisper: { samples, locale in
            try await WhisperDictationBackend().transcribe(samples: samples, locale: locale)
        },
        transcribeWhisperSegments: { samples, regions, locale in
            try await WhisperDictationBackend().transcribeDictation(samples: samples,
                                                                     regions: regions,
                                                                     locale: locale)
        },
        whisperIsReady: { WhisperDictationBackend.isReady(WhisperDictationBackend.model) },
        onIssue: { operation, reason in
            Diagnostics.recordFailure(operation: operation, reason: reason)
        },
        onTiming: { operation, seconds, cold in
            Diagnostics.recordTiming(operation: "dictation.\(operation)", seconds: seconds, cold: cold)
        },
        onPhaseChanged: { [weak self] phase in
            self?.updateDictationToast(phase)
            self?.scheduleTranslatorEvictionIfIdle()
        })
    }()
    private let dictationHotkeyMonitor = DictationHotkeyMonitor()
    private var dictationPrewarmTask: Task<Void, Never>?
    private var lastDictationResult: DictationResultSnapshot?
    private var dictationFeedbackTask: Task<Void, Never>?
    private let capture = SystemAudioCapture()
    private var engine = ASREngine.effective

    override init() {
        super.init()
        bindDictationToastActions()
    }

    func bindDictationToastActions() {
        dictationToast.onResetPosition = { [weak self] in
            self?.dictationToast.resetPosition()
        }
    }

#if SAIITY_TEST_HOOKS
    var dictationToastForTests: DictationToastWindow { dictationToast }
    func updateDictationToastForTests(_ phase: DictationPhase) {
        updateDictationToast(phase)
    }
#endif

    private func cleanupDictatedText(_ text: String, sourceLanguage: String) async -> String? {
        await cleanupDictatedText(DictationTranscriptionResult(text: text, language: sourceLanguage))?.text
    }

    private lazy var dictationCleanupSession = DictationCleanupSession(gate: translatorInferenceGate)

    private func cleanupDictatedText(_ transcription: DictationTranscriptionResult) async -> DictationTranscriptionResult? {
        await translatorSwap?.value
        await waitForTranslatorUsersToFinish()
        beginTranslatorUse()
        defer { endTranslatorUse() }
        let selected = LocalModel.cleanupSelected
        let model = LocalModel.isCleanupCompatible(selected) ? selected : nil
        return await dictationCleanupSession.cleanup(transcription, modelKey: model?.file) { [self] in
            // The session owns the native gate here. Waiters/teardown must not
            // recursively enter that gate. Dictation already excludes captions;
            // a warm translator is released before loading the cleanup weights.
            let outgoing = activeTranslator
            activeTranslator = nil
            activeTranslatorEngine = nil
            translatorPreparedTarget = nil
            translatorReady = false
            await outgoing?.stop()
            let translator = LocalLLMTranslator()
            do {
                try await translator.prepare(model: model, from: "auto", to: "auto") { message in
                    NSLog("sAiity cleanup progress: %@", message)
                }
            } catch {
                await translator.stop()
                throw error
            }
            return DictationCleanupSession.Model(
                cleanup: { text, source, metadata in
                    await translator.cleanup(text, sourceLanguage: source, languageMetadata: metadata)
                },
                cleanupRegions: { regions in
                    await translator.cleanupRegions(regions)
                },
                stop: { await translator.stop() })
        }
    }

    /// Model destruction is serialized with native inference.
    private func stopTranslator(_ translator: Translating?) async {
        guard let translator else { return }
        _ = try? await translatorInferenceGate.run {
            await translator.stop()
        }
    }

    static func performDictationCleanup(
        _ text: String,
        prepare: () async throws -> Void,
        cleanup: (String) async -> String?,
        stop: () async -> Void
    ) async -> String? {
        do {
            try await prepare()
            let result = await cleanup(text)
            await stop()
            return result
        } catch {
            await stop()
            NSLog("sAiity cleanup unavailable: \(error.localizedDescription)")
            return nil
        }
    }

    /// Production action for the deferred Task6 settings control.
    func prepareSelectedWhisperModelForUse(_ choice: WhisperDictationBackend.ModelChoice,
                                           progress: @escaping @Sendable (Progress) -> Void = { _ in }) async throws {
        #if SAIITY_TEST_HOOKS
        if let hook = whisperPreparationForTests {
            try await hook(choice, progress)
            return
        }
        #endif
        let backend = WhisperDictationBackend()
        try await backend.prepareModelForUse(choice, progress: progress)
    }

    func prepareSelectedWhisperModelForUse(progress: @escaping @Sendable (Progress) -> Void = { _ in }) async throws {
        try await prepareSelectedWhisperModelForUse(WhisperDictationBackend.model, progress: progress)
    }

    func removeSelectedWhisperModel() async throws {
        await invalidateDictationBackend()
        try await WhisperDictationBackend().removeModel(WhisperDictationBackend.model)
    }

    func invalidateDictationBackend() async {
        await dictationController.invalidatePreparedBackend()
    }

    #if SAIITY_TEST_HOOKS
    var captionEngineForTests: ASREngine { engine }
    var captionPoolPreparedForTests: Bool { asrBackendPool.preparedForTests }
    var captionPoolLeaseForTests: Bool { asrBackendPool.hasActiveLeaseForTests }
    /// The sentence still being assembled, as the recogniser sees it. Empty once
    /// it has closed.
    var pendingSentenceForTests: [String] { sentenceParts }
    /// Seed that partial sentence the way a real chunk does.
    func openSentenceForTests(_ parts: [String]) {
        sentenceParts = parts
        sentenceStart = 0
        sentenceEnd = Double(parts.count) * 0.5
    }
    /// Close it, exactly as punctuation or teardown would.
    func closeSentenceForTests() { closeSentence() }
    /// The lines this session has recorded, whether or not saving is on.
    var sessionLinesForTests: [Segment] { sessionLines }
    var pendingTranscriptWritesForTests: Int { pendingTranscriptWrites }
    #endif
    /// The current caption lease. The pool remains the owner of the cached
    /// backend; this is held only between caption start and teardown.
    private var captionBackend: TranscriptionBackend?
    private let captureSink = BackendSink()

    /// Recognition is always the selected ASR engine.
    ///
    /// Whisper used to be able to replace it — speech straight to English in one
    /// model pass — which is why this was a function rather than a property.
    /// That engine was cut: it stopped emitting finals about 25 seconds into
    /// every session (its sliding window slid but its commit index never
    /// rebased), and it was slower than Nemotron plus a real translator anyway.
    static func makeActiveBackend() -> TranscriptionBackend {
        let selected = ASREngine.effective
        let metrics: @Sendable (StreamingASRMetrics) -> Void = { metrics in
            Task { @MainActor in
                Diagnostics.recordTiming(operation: "captions.asr.rtf",
                                         seconds: metrics.realTimeFactor,
                                         cold: false)
                Diagnostics.recordTiming(operation: "captions.asr.backlog",
                                         seconds: metrics.peakBacklogSeconds,
                                         cold: false)
                if metrics.droppedAudioSeconds > 0 {
                    ASRAdaptivePolicy.markOverloaded(scope: .captions)
                    Diagnostics.recordTiming(operation: "captions.asr.dropped",
                                             seconds: metrics.droppedAudioSeconds,
                                             cold: false)
                    Diagnostics.recordFailure(
                        operation: "captions.audio",
                        reason: String(format: "dropped %.3fs of backlog audio",
                                       metrics.droppedAudioSeconds))
                }
            }
        }
        guard selected == .nemotron else {
            return selected.makeBackend(onMetrics: metrics)
        }

        let preferredTier = NemotronEngine.selectedChunkMs
        let installed = Set(NemotronEngine.availableChunkMs.filter {
            NemotronEngine.isDownloaded(chunkMs: $0)
        })
        let tier = NemotronEngine.hasExplicitChunkSelection
            ? preferredTier
            : ASRAdaptivePolicy.chooseRuntimeTier(preferred: preferredTier,
                                                   available: NemotronEngine.availableChunkMs,
                                                   installed: installed,
                                                   scope: .captions)
        let name = String(localized: "NVIDIA Nemotron (streaming, on-device)")
        return StreamingASRBackend(
            name: name,
            engine: NemotronEngine(chunkMs: tier),
            onPerformance: { rtf, _ in
                ASRAdaptivePolicy.record(realTimeFactor: rtf,
                                         tier: tier,
                                         scope: .captions)
            },
            onMetrics: metrics,
            onBackpressure: { backlogSeconds in
                Task { @MainActor in
                    ASRAdaptivePolicy.markOverloaded(scope: .captions)
                    Diagnostics.recordTiming(operation: "captions.asr.backpressure",
                                             seconds: backlogSeconds,
                                             cold: false)
                }
            })
    }

    static func makeDictationStreamingBackend() -> TranscriptionBackend {
        let engine = ASREngine.dictationEffective
        guard engine == .nemotron else { return engine.makeBackend() }
        // Dictation's own tier, not the caption tier. It follows the caption
        // preference only while it has no choice of its own, and pinning the
        // adaptive policy to the same value let one surface's setting decide
        // for the other.
        let preferredTier = NemotronEngine.dictationSelectedChunkMs
        let installed = Set(NemotronEngine.availableChunkMs.filter {
            NemotronEngine.isDownloaded(chunkMs: $0)
        })
        let tier = NemotronEngine.hasExplicitDictationChunkSelection
            ? preferredTier
            : ASRAdaptivePolicy.chooseRuntimeTier(preferred: preferredTier,
                                                   available: NemotronEngine.availableChunkMs,
                                                   installed: installed)
        let name = String(localized: "NVIDIA Nemotron (streaming, on-device)")
        return StreamingASRBackend(
            name: name,
            engine: NemotronEngine(chunkMs: tier),
            onPerformance: { rtf, _ in
                ASRAdaptivePolicy.record(realTimeFactor: rtf,
                                         tier: tier,
                                         scope: .dictation)
            })
    }

    func refreshDictationRuntime() {
        Task { @MainActor in
            await dictationController.invalidatePreparedBackend()
            await dictationBackendPool.replace(with: Self.makeDictationStreamingBackend())
        }
    }

    /// Quiesce runtime-backed models before Settings removes an incomplete
    /// selected asset. The caller has already established that no transfer is
    /// active; this is the second safety door for a model that was prewarmed
    /// outside a visible caption session.
    @discardableResult
    func prepareForModelCleanup() async -> Bool {
        guard state == .idle,
              !dictationController.isBusy,
              // A re-translation is a live session of its own, holding a
              // translator this is about to stop and files it is about to
              // unlink. It reports through the same global flag captions do, so
              // the check belongs here as much as in the window.
              !CaptionSession.shared.isRetranslating,
              translatorSwap == nil,
              translatorUsers == 0 else { return false }
        await dictationController.invalidatePreparedBackend()
        let outgoing = activeTranslator
        activeTranslator = nil
        activeTranslatorEngine = nil
        translatorPreparedTarget = nil
        translatorReady = false
        await stopTranslator(outgoing)
        return true
    }

    private var activeTranslator: Translating?
    private var activeTranslatorEngine: TranslationEngine?
    private var translatorPreparedTarget: String?
    private let translatorInferenceGate = TranslationInferenceGate()
    /// The one gate every native translation call passes through, including the
    /// ones that run with no caption session: dictation's own translation and
    /// cleanup already do, and re-translating a saved transcript now does too.
    /// Those three are the only inference in the app, and MADLAD's Metal
    /// runtime is not safe to overlap — without the gate a re-translation and a
    /// dictation press could decode on it at the same time.
    var translationInferenceGate: TranslationInferenceGate { translatorInferenceGate }
    private var translatorReady = false
    private var translationRuntimeFallback = TranslationRuntimeFallback()
    private let translatorIdleEviction = IdleEviction()
    private var translatorUsers = 0
    private var translatorIdleWaiters: [CheckedContinuation<Void, Never>] = []

    /// Serialises translator replacement, and lets a superseded swap bow out.
    ///
    /// Replacing the translator means releasing gigabytes and loading gigabytes.
    /// Every change — menu-bar target, Settings target, translation engine, GGUF
    /// selection — used to fire that off immediately and unserialised, so
    /// clicking through a few languages while one load was in flight started a
    /// fresh multi-gigabyte load per click, each holding its own copy alive.
    private var translatorSwap: Task<Void, Never>?
    private var translatorGeneration = 0

    /// Release the current translator, then build and prepare its replacement.
    ///
    /// Order matters: the outgoing model is released *before* the incoming one
    /// is constructed, so the peak is one model rather than two.
    @MainActor
    private func swapTranslator(for scope: TranslationEngineScope = .captions) {
        captionTranslationTasks.values.forEach { $0.cancel() }
        captionTranslationTasks.removeAll()
        translatorIdleEviction.cancel()
        translatorGeneration += 1
        let generation = translatorGeneration
        translatorSwap = Task { @MainActor [weak self, previous = translatorSwap] in
            defer {
                if let self, self.translatorGeneration == generation {
                    self.translatorSwap = nil
                }
            }
            await previous?.value
            guard let self else { return }
            await self.waitForTranslatorUsersToFinish()
            let outgoing = self.activeTranslator
            self.activeTranslator = nil
            self.activeTranslatorEngine = nil
            self.translatorPreparedTarget = nil
            self.translatorReady = false
            await self.stopTranslator(outgoing)
            // A newer choice landed while we were releasing. Let that one do the
            // loading rather than paying for a model already superseded.
            guard generation == self.translatorGeneration else { return }
            var attempted: Set<TranslationEngine> = []
            while generation == self.translatorGeneration,
                  let selected = self.selectedTranslationEngine(for: scope),
                  !attempted.contains(selected) {
                attempted.insert(selected)
                self.activeTranslatorEngine = selected
                self.activeTranslator = selected.makeTranslator()
                _ = await self.prepareTranslatorIfNeeded(scope: scope,
                                                         allowRuntimeFallback: false)
                if self.translatorReady || self.activeTranslator != nil { return }
            }
        }
    }

    /// Hand back everything the translator holds, without disturbing the
    /// session. Used when the system is short of memory.
    @MainActor
    private func unloadTranslator(reason: String) async {
        translatorIdleEviction.cancel()
        await waitForTranslatorUsersToFinish()
        let outgoing = activeTranslator
        activeTranslator = nil
        activeTranslatorEngine = nil
        translatorPreparedTarget = nil
        translatorReady = false
        await stopTranslator(outgoing)
        MemoryPolicy.releaseCaches()
        NSLog("sAiity memory: released translator (\(reason)) — \(MemoryPolicy.describeFootprint())")
    }

    /// The system is short of memory. Give some back before it starts killing
    /// processes — quite possibly this one, mid-session.
    @MainActor
    private func handleMemoryPressure(_ level: MemoryPolicy.Pressure) {
        // Cached transcript text is the cheapest thing in the process to give
        // back — it is re-readable from disk, unlike a loaded model. It costs
        // a slower next search and nothing else, so it goes first and on any
        // pressure at all.
        if level != .normal { SegmentCache.shared.invalidate() }
        switch level {
        case .normal:
            // Pressure passed. Put translation back, if pressure is what took
            // it away — a spike that lasts seconds should not disable a feature
            // for the rest of the session, which is exactly what the first
            // version of this did. Measured on a busy Mac: one critical event
            // during a build, and translation was off until the app restarted.
            guard translationSuspendedByMemory else { return }
            translationSuspendedByMemory = false
            guard state.isActive, translateTo != nil else { return }
            NSLog("sAiity memory: pressure normal — restoring translation")
            Task { @MainActor in
                await prepareTranslatorIfNeeded()
            }
        case .warning:
            // Pooled buffers only. Nothing the user can perceive.
            MemoryPolicy.releaseCaches()
        case .critical:
            Task { @MainActor in await dictationCleanupSession.invalidate() }
            // Captions are the point of the app; translation is the expensive
            // extra. Shedding it keeps the session alive instead of losing it,
            // and it is said out loud rather than left to look like translation
            // quietly breaking.
            // `activeTranslator` is non-nil even when no weights are loaded, so
            // readiness is the only honest test of whether there is anything
            // here worth shedding.
            translatorIdleEviction.cancel()
            guard translatorReady else {
                MemoryPolicy.releaseCaches()
                return
            }
            translationSuspendedByMemory = true
            Task { @MainActor in
                await unloadTranslator(reason: "system memory pressure")
                if state.isActive {
                    setStatus("Translation paused — the Mac is short of memory. It comes back on its own.")
                }
            }
        }
    }

    /// True while translation is off *because of* memory pressure, so the
    /// recovery in `.normal` only undoes what pressure did — it must not switch
    /// translation on for someone who never asked for it.
    private var translationSuspendedByMemory = false

    /// A dictation request supplies its own target; caption preparation falls
    /// back to the captions preference when no scoped target is provided.
    static func translationTargetForPreparation(captionsTarget: String?,
                                                requestedTarget: String?) -> String? {
        requestedTarget ?? captionsTarget
    }

    private func selectedTranslationEngine(for scope: TranslationEngineScope) -> TranslationEngine? {
        let preferred: TranslationEngine?
        switch scope {
        case .captions:
            // Captions historically use the recommended engine when a target
            // is enabled before the user has persisted a picker choice. Keep
            // that default while still letting the runtime quarantine remove
            // a broken engine for this session.
            preferred = TranslationEngine.visibleSelection(TranslationEngine.selected)
                ?? .recommended
        case .dictation:
            // Dictation's picker visibly offers the recommended engine even
            // before the user has persisted a choice. Treat that recommendation
            // as the runtime default so enabling translation does not silently
            // produce an unconfigured translator.
            preferred = TranslationEngine.visibleSelection(TranslationEngine.dictationSelected)
                ?? TranslationEngine.visibleSelection(TranslationEngine.selected)
                ?? .recommended
        }
        return translationRuntimeFallback.resolve(preferred)
    }

    private func translationTarget(for scope: TranslationEngineScope,
                                   requestedTarget: String?) -> String? {
        switch scope {
        case .captions:
            return Self.translationTargetForPreparation(captionsTarget: translateTo,
                                                        requestedTarget: requestedTarget)
        case .dictation:
            return requestedTarget ?? SettingsWindowController.state.dictationTranslateTo
        }
    }

    /// Load (and if necessary download) the selected translator. This was the
    /// missing link: the translator object was constructed but `prepare()` was
    /// never called, so MADLAD and Qwen never downloaded their weights and
    /// `translate()` quietly returned nil forever.
    @MainActor
    @discardableResult
    private func prepareTranslatorIfNeeded(requestedTarget: String? = nil,
                                           allowWithoutCaptions: Bool = false,
                                           sourceLanguage: String? = nil,
                                           scope: TranslationEngineScope = .captions,
                                           allowRuntimeFallback: Bool = true) async -> Bool {
        translatorIdleEviction.cancel()
        guard let target = translationTarget(for: scope, requestedTarget: requestedTarget) else {
            return false
        }
        guard let selectedEngine = selectedTranslationEngine(for: scope) else {
            // A target without a translator: honest, and recoverable in one step.
            setStatus("No translator chosen — pick one in Settings")
            return false
        }
        guard activeTranslator == nil || activeTranslatorEngine == selectedEngine else {
            // A different scoped choice is still in use. Let the caller replace
            // it through the serialized swap path instead of releasing native
            // state during inference.
            return false
        }
        // Preparation also crosses into MLX/llama native state. Hold the same
        // lifetime lease as inference so a target/engine swap cannot release
        // the object while its async load is suspended.
        beginTranslatorUse()
        defer { endTranslatorUse() }
        let generation = translatorGeneration
        if activeTranslator == nil {
            activeTranslator = selectedEngine.makeTranslator()
            activeTranslatorEngine = selectedEngine
        }
        guard let engine = activeTranslator else { return false }
        if translatorReady && translatorPreparedTarget == target {
            return true
        }
        // Loading is deferred until a session is actually running, deliberately.
        // Choosing a target used to load the model there and then — 1.9 GB for
        // MADLAD, up to 2.5 GB for a large GGUF — and hold it for as long as the
        // app was open, with captions stopped and nothing to translate. That was
        // the largest block of memory this app held for no reason at all.
        // start() calls this again once the session is up.
        guard allowWithoutCaptions || state.isActive else {
            setStatus("Translation: \(AppLanguage(code: target).displayName) — loads on start")
            return false
        }
        let coldPrepare = !translatorReady
        let prepareStarted = ContinuousClock.now
        let src = sourceLanguage ?? detectedLanguage ?? locale.identifier(.bcp47)
        NSLog("sAiity translator: selected=\(selectedEngine.rawValue) object=\(engine.name) src=\(src) dst=\(target) scope=\(scope.rawValue)")
        // Frozen BEFORE the await, like `target` above and for the same
        // reason: the user can switch translator — or Qwen model — while
        // prepare() runs, and reading `.effective` again at the end would
        // pin this load's outcome on whichever asset happens to be selected
        // then. A health record against a model that never ran is worse than
        // none: it offers "Re-download" for a file that is perfectly fine.
        let assetID = selectedEngine.activeAssetID
        do {
            try await translatorInferenceGate.run {
                await self.dictationCleanupSession.releaseModel()
                try await engine.prepare(from: src, to: target) { msg in
                    NSLog("sAiity translator progress: \(msg)")
                    Task { @MainActor in self.setStatus(localized: msg) }
                }
            }
            // A settings change can replace the model while prepare() is
            // suspended. Never mark that stale instance ready or let a caller
            // translate through it after the replacement has started.
            guard generation == translatorGeneration,
                  activeTranslatorEngine == selectedEngine,
                  activeTranslator != nil else { return false }
            translatorReady = true
            translatorPreparedTarget = target
            Diagnostics.recordTiming(operation: "translator.prepare",
                                     seconds: elapsedSeconds(since: prepareStarted),
                                     cold: coldPrepare)
            if let assetID { LoadHealth.clear(assetID) }
            setStatus("Translating with \(selectedEngine.displayName)")
            return true
        } catch {
            translatorReady = false
            // A native loader can leave a partially constructed model object
            // behind before throwing. Drop it before the next attempt; keeping
            // that object alive is both wasted memory and unsafe for llama/MLX.
            let failed = activeTranslator
            activeTranslator = nil
            activeTranslatorEngine = nil
            translatorPreparedTarget = nil
            await stopTranslator(failed)
            translationRuntimeFallback.quarantine(selectedEngine)
            // Bytes on disk that refuse to load are damage worth remembering —
            // the Models page turns this into a "Re-download" the user can
            // actually connect to the error, instead of the same status-line
            // failure on every future session.
            switch error {
            case is CancellationError: break
            case let e as URLError where e.code == .cancelled: break
            default:
                if let assetID, !Self.isRuntimeResourceFailure(error) {
                    LoadHealth.recordFailureIfInstalled(assetID,
                                                        reason: DiagnosticsRedactor.redact(error.localizedDescription))
                }
            }
            let fallback = selectedTranslationEngine(for: scope)
            if allowRuntimeFallback, let fallback, fallback != selectedEngine,
               translatorSwap == nil {
                activeTranslatorEngine = fallback
                activeTranslator = fallback.makeTranslator()
                setStatus("\(selectedEngine.displayName) unavailable — trying \(fallback.displayName)")
                return await prepareTranslatorIfNeeded(requestedTarget: requestedTarget,
                                                       allowWithoutCaptions: allowWithoutCaptions,
                                                       sourceLanguage: sourceLanguage,
                                                       scope: scope,
                                                       allowRuntimeFallback: false)
            }
            if let fallback {
                setStatus("\(selectedEngine.displayName) unavailable — will use \(fallback.displayName)")
            } else {
                setStatus("Translation unavailable: \(error.localizedDescription)")
            }
            NSLog("sAiity translator prepare failed: \(error.localizedDescription)")
            return false
        }
    }

    private static func isRuntimeResourceFailure(_ error: Error) -> Bool {
        guard let error = error as? TranslationEngineError else { return false }
        if case .runtimeUnavailable = error { return true }
        return false
    }

    /// Retire a translator after a native inference returns no result. The
    /// current caller still holds its use lease, so teardown waits for that
    /// lease rather than releasing MLX/llama state from inside inference.
    private func retireFailedTranslator(_ engine: TranslationEngine,
                                         reason: String) {
        translationRuntimeFallback.quarantine(engine)
        guard activeTranslatorEngine == engine else { return }
        let outgoing = activeTranslator
        activeTranslator = nil
        activeTranslatorEngine = nil
        translatorPreparedTarget = nil
        translatorReady = false
        NSLog("sAiity translator retired: engine=%@ reason=%@", engine.rawValue, reason)
        Task { @MainActor [weak self, outgoing] in
            guard let self else { return }
            await self.waitForTranslatorUsersToFinish()
            await self.stopTranslator(outgoing)
        }
    }

    private func dictationTranslationConfiguration() -> DictationTranslationConfiguration {
        let settings = SettingsWindowController.state
        return DictationTranslationConfiguration(enabled: settings.translateDictation,
                                                  target: settings.dictationTranslateTo)
    }

    private func translateDictatedText(_ text: String,
                                       source: String,
                                       target: String) async -> String? {
        // A same-language target is a no-op. In particular, do not prepare or
        // enter MLX for zh -> zh: the transcript is already the requested
        // output and native initialization is the most failure-prone part.
        guard !TranslationLanguage.isSame(source, as: target) else { return text }
        translatorIdleEviction.cancel()
        // Dictation may use a different engine than captions. Switch through
        // the serialized lifecycle before entering native inference, and keep
        // the model resident between regions and presses.
        guard let desiredEngine = selectedTranslationEngine(for: .dictation) else { return nil }
        if activeTranslator == nil || activeTranslatorEngine != desiredEngine {
            swapTranslator(for: .dictation)
        }
        // A settings change replaces the translator asynchronously. Do not
        // translate against the old model while that replacement is in flight.
        let generation = translatorGeneration
        let swap = translatorSwap
        await swap?.value
        // A new swap may have been scheduled while the previous one was
        // finishing. Re-check before acquiring the use lease so that a late
        // dictation cannot race the replacement's prepare/release cycle.
        guard generation == translatorGeneration else { return nil }
        beginTranslatorUse()
        defer {
            endTranslatorUse()
            scheduleTranslatorEvictionIfIdle()
        }
        guard SettingsWindowController.state.translateDictation,
              SettingsWindowController.state.dictationTranslateTo == target else {
            return nil
        }
        guard await prepareTranslatorIfNeeded(requestedTarget: target,
                                              allowWithoutCaptions: true,
                                              sourceLanguage: source,
                                              scope: .dictation),
              let engine = activeTranslator else { return nil }
        do {
            let started = ContinuousClock.now
            let result: String? = try await translatorInferenceGate.run {
                await engine.translate(text, from: source, to: target)
            }
            Diagnostics.recordTiming(operation: "translator.inference",
                                     seconds: elapsedSeconds(since: started),
                                     cold: false)
            if result == nil {
                retireFailedTranslator(desiredEngine, reason: "dictation inference returned no output")
            }
            return result
        } catch {
            NSLog("sAiity dictation translation unavailable: \(error.localizedDescription)")
            return nil
        }
    }

    private func translateDictatedText(_ text: String,
                                       transcription: DictationTranscriptionResult,
                                       target: String) async -> String? {
        // A recognizer may expose no language tag (or only the first tag) even
        // though the segmenter found several speech regions. Region count is
        // therefore the conservative authority for translation granularity;
        // never collapse an untagged segmented recording back to its first
        // language and send the whole mixed message through one source code.
        guard transcription.regions.count > 1 else {
            let source = transcription.languageMetadata.dominantLanguage ?? "auto"
            return await translateDictatedText(text, source: source, target: target)
        }

        let runs = transcription.translationRuns
        let regionsNeedingTranslation = runs.filter { region in
            let source = region.language ?? "auto"
            return !TranslationLanguage.isSame(source, as: target)
        }
        // Every region is already in the requested target language. Preserve
        // the original mixed transcript and keep the translator cold.
        guard !regionsNeedingTranslation.isEmpty else { return transcription.text }

        // A mixed transcript is translated region by region. Hold one use
        // lease and one gate operation for the complete run: the loaded native
        // model cannot be evicted or retargeted between regions, and no other
        // caption/dictation inference can enter while this authoritative result
        // is being assembled.
        translatorIdleEviction.cancel()
        guard let desiredEngine = selectedTranslationEngine(for: .dictation) else { return nil }
        if activeTranslator == nil || activeTranslatorEngine != desiredEngine {
            swapTranslator(for: .dictation)
        }
        let generation = translatorGeneration
        await translatorSwap?.value
        guard generation == translatorGeneration else { return nil }
        beginTranslatorUse()
        defer {
            endTranslatorUse()
            scheduleTranslatorEvictionIfIdle()
        }
        guard SettingsWindowController.state.translateDictation,
              SettingsWindowController.state.dictationTranslateTo == target,
              await prepareTranslatorIfNeeded(requestedTarget: target,
                                               allowWithoutCaptions: true,
                                               sourceLanguage: transcription.languageMetadata.dominantLanguage,
                                               scope: .dictation),
              let engine = activeTranslator else { return nil }

        do {
            let started = ContinuousClock.now
            let result: String? = try await translatorInferenceGate.run {
                var translated = Array(repeating: "", count: runs.count)
                var pending: [(index: Int, region: DictationRegionTranscript)] = []
                pending.reserveCapacity(runs.count)
                for (index, region) in runs.enumerated() {
                    try Task.checkCancellation()
                    let source = region.language ?? "auto"
                    if TranslationLanguage.isSame(source, as: target) {
                        translated[index] = region.text
                    } else {
                        pending.append((index, region))
                    }
                }

                if pending.count > 1 {
                    let batch = pending.map {
                        TranslationRegion(text: $0.region.text,
                                          source: $0.region.language ?? "auto")
                    }
                    if let values = await engine.translateRegions(batch, to: target),
                       values.count == pending.count {
                        for (item, value) in zip(pending, values) {
                            translated[item.index] = value
                        }
                    }
                }

                // Engines without strict batching, and malformed native batch
                // responses, use the proven sequential path. This also keeps
                // Hy-MT2/custom translators correct without special cases.
                for item in pending where translated[item.index].isEmpty {
                    try Task.checkCancellation()
                    let source = item.region.language ?? "auto"
                    guard let value = await engine.translate(item.region.text,
                                                              from: source,
                                                              to: target) else {
                        return nil
                    }
                    translated[item.index] = value
                }
                return DictationTranscriptMerger.merge(translated)
            }
            Diagnostics.recordTiming(operation: "translator.inference",
                                     seconds: elapsedSeconds(since: started),
                                     cold: false)
            if result == nil {
                retireFailedTranslator(desiredEngine, reason: "dictation inference returned no output")
            }
            return result
        } catch is CancellationError {
            return nil
        } catch {
            NSLog("sAiity dictation translation unavailable: \(error.localizedDescription)")
            return nil
        }
    }

    private func elapsedSeconds(since start: ContinuousClock.Instant) -> Double {
        let elapsed = start.duration(to: .now).components
        return Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18
    }

    /// Model loading/release and native inference must never overlap. The
    /// translator implementations cross into MLX/llama.cpp, where releasing a
    /// model during an in-flight call can terminate the process instead of
    /// throwing a Swift error.
    private func beginTranslatorUse() {
        translatorUsers += 1
    }

    private func endTranslatorUse() {
        guard translatorUsers > 0 else { return }
        translatorUsers -= 1
        guard translatorUsers == 0 else { return }
        let waiters = translatorIdleWaiters
        translatorIdleWaiters.removeAll(keepingCapacity: true)
        waiters.forEach { $0.resume() }
    }

    private func waitForTranslatorUsersToFinish() async {
        guard translatorUsers > 0 else { return }
        await withCheckedContinuation { continuation in
            translatorIdleWaiters.append(continuation)
        }
    }

    /// Keep a prepared translator warm across a short pause, but do not let an
    /// idle menu-bar app retain gigabytes indefinitely. The eligibility check is
    /// repeated by `IdleEviction` at the deadline, so a late phase transition
    /// cannot unload a translator that became useful again.
    @MainActor
    private func scheduleTranslatorEvictionIfIdle() {
        guard translatorReady,
              state == .idle,
              !dictationController.isBusy,
              translatorSwap == nil,
              !liveTranslationBusy,
              pendingTranslations == 0,
              translatorUsers == 0 else { return }
        translatorIdleEviction.schedule(
            after: .seconds(300),
            shouldEvict: { [weak self] in
                guard let self else { return false }
                return self.translatorReady
                    && self.state == .idle
                    && !self.dictationController.isBusy
                    && self.translatorSwap == nil
                    && !self.liveTranslationBusy
                    && self.pendingTranslations == 0
                    && self.translatorUsers == 0
            },
            evict: { [weak self] in
                guard let self else { return }
                await self.unloadTranslator(reason: "idle grace period")
            })
    }

#if SAIITY_TEST_HOOKS
    var translatorEvictionScheduledForTests: Bool {
        translatorIdleEviction.isScheduledForTests
    }

    var translatorReadyForTests: Bool { translatorReady }

    func armTranslatorEvictionForTests(after delay: Duration) {
        translatorReady = true
        translatorIdleEviction.schedule(
            after: delay,
            shouldEvict: { [weak self] in self?.translatorReady ?? false },
            evict: { [weak self] in
                await self?.unloadTranslator(reason: "test idle grace period")
            })
    }

    func handleMemoryPressureForTests(_ level: MemoryPolicy.Pressure) {
        handleMemoryPressure(level)
    }
#endif

    /// Where the capture session is in its lifecycle.
    ///
    /// A Bool could not express `starting`, and that gap was the bug: `start()`
    /// set `running = true` and then did the real work — model load, possibly a
    /// 634 MB download — in a Task nobody held. `stop()` flipped the flag and
    /// tore down a backend that had not started yet, and the start Task
    /// afterwards went right on to bring up the audio stream. The result was
    /// system audio being captured, with the recording indicator lit, while the
    /// menu said "Start captions".
    enum SessionState: Equatable {
        case idle, starting, running, stopping

        /// What the menu offers, and what a caller may do next.
        var isActive: Bool { self == .starting || self == .running }
    }

    private var state: SessionState = .idle {
        didSet {
            guard state != oldValue else { return }
            // The Settings window gates model deletion on this: deleting weights
            // out from under a loading engine is exactly as bad as under a
            // running one, so `starting` counts as busy.
            CaptionSession.shared.setRunning(state.isActive)
        }
    }

    /// The in-flight start. Held so `stopAsync()` can cancel it and wait for it
    /// to actually leave the engine before tearing anything down.
    private var sessionTask: Task<Void, Never>?
    /// Coalesces repeated gap callbacks and is cancelled by teardown. The
    /// callback itself runs on the capture queue; only this task touches the
    /// main-actor sentence state.
    private var speechGapTask: Task<Void, Never>?

    private var locale = Locale(identifier: "en-US")
    /// BCP-47, nil = off. Persisted — it was previously an in-memory var, so the
    /// chosen target silently reset to "off" on every launch, which is one of the
    /// two reasons translation appeared not to work at all.
    private var translateTo: String? = UserDefaults.standard.string(forKey: "translateTo") {
        didSet { UserDefaults.standard.set(translateTo, forKey: "translateTo") }
    }
    private var statusLine = String(localized: "Idle")
    /// A rebuild was requested and not yet done. Held while the status menu is
    /// tracking and honoured in `menuDidClose`.
    private var menuRebuildPending = false
    private var menuIsTracking = false
    private var showedAnyCaption = false
    private var captionFirstTextLogged = false
    private var captionFirstFinalLogged = false
    private var captionWarmStart = false
    private var captionStartInstant: ContinuousClock.Instant?
    private var captionCaptureStartedAt: ContinuousClock.Instant?
    private var clearCaptionInstant: ContinuousClock.Instant?

    // Recording is deliberately separate from captioning and defaults to OFF:
    // captions are ephemeral, a transcript is a durable record of a conversation
    // other people were part of.
    private var saveTranscript = UserDefaults.standard.bool(forKey: "saveTranscript")
    private var recordingSince: Date?
    private var recordedLines = 0
    private var subtitleSessionStartedAt: Date?
    /// Untruncated, unlike the overlay label — never copy from the view.
    private var lastFinalText = ""
    private var lastVolatileText = ""

    // MARK: - Sentence assembly
    //
    // The recogniser commits a clause every few seconds, because waiting for
    // punctuation means continuous speech produces no captions at all. Those
    // clauses are the right unit for the engine and the wrong unit for a
    // viewer: shown one at a time they replace each other, so a sentence
    // arrives as a series of two-word flashes and the translation of each is
    // made without the rest. These hold the clauses until they form something
    // worth reading.
    private var sentenceParts: [String] = []
    /// Which sentence the translation on screen belongs to, so a stale one can
    /// be dimmed rather than cleared, and cleared only once it is two sentences
    /// behind. Nil when the row is empty.
    private var shownTranslationID: Int?
    /// Live-mode translation of the still-open sentence: single-flight with
    /// latest-wins, because neither translator can be cancelled mid-decode —
    /// queueing every clause would fall permanently behind, and what matters is
    /// only ever the newest text.
    private var liveTranslationBusy = false
    private var pendingLiveText: (text: String, sentenceID: Int)?
    private struct LiveTranslationRequest: Equatable {
        let text: String
        let sentenceID: Int
        let source: String
        let target: String
        let engine: TranslationEngine
    }
    private var lastLiveTranslationRequest: LiveTranslationRequest?
    private var sentenceWords: [TimedWord] = []
    private var sentenceStart: Double = 0
    private var sentenceEnd: Double = 0

    /// Identifies the sentence whose original is on screen right now.
    ///
    /// A translation takes a second or two, by which time the speaker may have
    /// started the next sentence. Without this the translation line kept
    /// whatever arrived last regardless of what was above it — measured: the
    /// bubble read "direkt auf dem Gerät" over "This application generates
    /// subtitles for everything that is played on Mac", two different
    /// sentences stacked as if they were a pair. A translation is now only
    /// shown while its own original is still displayed.
    private var displayLifecycle = CaptionDisplayLifecycle()

    /// Also the display cap: past this a sentence is closed rather than left to
    /// grow past what the bubble can show.
    private static let maxSentenceChars = 220
    private static let sentenceTerminators: Set<Character> = [".", "!", "?", "…", "。", "！", "？"]
    /// Punctuation that says the speaker is mid-thought, so a pause after it is
    /// a breath rather than a full stop.
    private static let clauseContinuations: Set<Character> = [",", "、", "，", ";", "；", ":", "：", "-", "–"]

    #if SAIITY_TEST_HOOKS
    static var sentenceTerminatorsForTests: Set<Character> { sentenceTerminators }
    static var maxSentenceCharsForTests: Int { maxSentenceChars }
    #endif

    /// Joins clauses the way the script writes them. Chinese, Japanese and Thai
    /// run on without spaces, and inserting one produces text a native reader
    /// sees as broken — and a translator sees as two words.
    static func joinClauses(_ parts: [String]) -> String {
        CaptionTextMerger.join(parts)
    }

    private static func trimmedForDisplay(_ parts: [String]) -> String {
        String(joinClauses(parts).suffix(maxSentenceChars))
    }
    private var sessionLines: [Segment] = []
    /// Bumped by start(), so an async result from the previous session cannot
    /// patch a line of this one that happens to share an index.
    private var sessionGeneration = 0
    /// Serialises transcript-store appends into claim order. Each link awaits
    /// the previous, so the jsonl's line order matches the spoken order even
    /// when translations finish out of order.
    private var transcriptWriteChain: Task<Void, Never>?
    /// Links in that chain whose append has not happened yet. The chain itself
    /// is only cleared on teardown, so it cannot answer "is anything still
    /// owed to the store?" — and that is precisely the question quitting asks
    /// before it closes the handle.
    private var pendingTranscriptWrites = 0

    private struct CaptionTranslationKey: Hashable {
        let text: String
        let source: String
        let target: String
        let engine: TranslationEngine
    }

    /// Stable caption translations are safe to reuse within one session. The
    /// key excludes the segment index deliberately: repeated ASR boundaries
    /// should not invoke the same native model twice.
    private var captionTranslationCache = BoundedCache<CaptionTranslationKey, String>(capacity: 64)
    private var captionTranslationTasks: [Int: Task<String?, Never>] = [:]

    /// How many caption lines may be waiting on the translator at once.
    ///
    /// MADLAD serialises translation behind a lock and takes a second or two per
    /// sentence. When speech outruns it there is nothing to stop the queue
    /// growing for the length of the session: each waiting line pins its chunk
    /// — including per-word timings — and occupies a thread in the cooperative
    /// pool while it blocks on that lock. Past this many, lines go through
    /// untranslated instead of joining a queue that is not going to drain. A
    /// translation that lands a minute after the words were spoken is worth
    /// nothing on screen anyway.
    private static let maxPendingTranslations = 4
    private var pendingTranslations = 0

    // Auto language detection. `autoLanguage` controls whether a confident
    // detection also SWITCHES the recogniser; the detected language is always
    // tracked, because translation needs a real source language rather than
    // whatever locale happens to be selected.
    private var detector = LanguageDetector()
    private var detectedLanguage: String?
    /// The PCM format the capture stream is currently converting into. If a
    /// language switch changes it, capture has to be restarted too or we would
    /// feed the new engine buffers in the old engine's format.
    private var captureFormat: AVAudioFormat?

    func applicationDidFinishLaunching(_ note: Notification) {
        // First, before permissions or onboarding can be keyed to the wrong
        // path: an app running off the DMG or out of Downloads should move
        // home. If the user says yes the process relaunches from
        // /Applications and nothing below this line matters for this one.
        MoveToApplications.offerIfNeeded()
        // Apply the retention policy before anything can list transcripts, so
        // an expired session never appears and then vanishes — then keep
        // applying it, because this app is left running for weeks.
        TranscriptRetention.sweep()
        TranscriptRetention.startPeriodicSweep()
        // Before anything can allocate: cap MLX's buffer pool, and start
        // listening for the system asking for memory back. See MemoryPolicy —
        // this app can hold several gigabytes of models, and on a 16 GB machine
        // that is the difference between working and taking the Mac down with it.
        MemoryPolicy.startMonitoring { [weak self] level in
            self?.handleMemoryPressure(level)
        }
        // The pool owns the backend. The sink stays empty until a caption lease
        // has been acquired, so an idle app cannot keep an ASR model reachable.
        captureSink.point(at: nil)

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        updateStatusItemIcon()
        // Deliberately not localised: a two-glyph fallback that only appears if
        // icon rendering fails, and a stable marker beats a per-locale one.
        if statusItem.button?.image == nil { statusItem.button?.title = "CC" }
        statusItem.button?.toolTip = String(localized: "sAiity — on-device live subtitles")
        overlay.onCopy = { [weak self] in self?.copyCurrentLine() }
        overlay.onSaveTranscript = { [weak self] in self?.saveSubtitlesTranscript() }
        overlay.onClear = { [weak self] in self?.clearCaption() }
        bindDictationToastActions()
        NotificationCenter.default.addObserver(
            self, selector: #selector(saveTranscriptChangedExternally(_:)),
            name: .saiitySaveTranscriptChanged, object: nil)
        // The gap threshold decides where sentences break, so a change should
        // land on the session the user is watching rather than the next one.
        NotificationCenter.default.addObserver(
            forName: .saiitySpeechGapChanged, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in self?.capture.applySpeechGapSettings() }
            }
        rebuildMenu()
        if SettingsWindowController.state.dictationEnabled {
            Self.scheduleAfterLaunch { [weak self] in
                self?.ensureDictationHotkey()
            }
        }
        NotificationCenter.default.addObserver(forName: .saiityDictationSettingChanged,
                                               object: nil, queue: .main) { [weak self] note in
            Task { @MainActor [weak self] in
                guard let self else { return }
                let refreshRuntime = note.userInfo?["refreshRuntime"] as? Bool == true
                self.dictationHotkeyMonitor.updateChord(SettingsWindowController.state.dictationChord)
                if refreshRuntime { self.refreshDictationRuntime() }
                if SettingsWindowController.state.dictationEnabled {
                    self.ensureDictationHotkey()
                } else {
                    self.dictationHotkeyRetryTask?.cancel()
                    self.dictationHotkeyRetryTask = nil
                    // Cancel before the monitor and toast go away, so no
                    // prepared backend survives a user-visible disable action.
                    self.dictationController.cancel()
                    self.dictationHotkeyMonitor.stop()
                    self.dictationToast.dismiss()
                }
                self.rebuildMenu()
            }
        }
        NotificationCenter.default.addObserver(forName: .saiityDictationShortcutRecordingChanged,
                                               object: nil, queue: .main) { [weak self] note in
            let suspended = note.object as? Bool ?? false
            Task { @MainActor [weak self] in
                self?.dictationHotkeyMonitor.setSuspended(suspended)
            }
        }

        // Lets the Settings window stop the session and drop loaded models
        // before it deletes their files.
        CaptionSession.shared.releaseModels = { [weak self] in await self?.releaseModels() }
        // Leftovers from an interrupted download; nothing else cleans these up.
        FileDownloader.sweepPartials(in: ModelRegistry.root)

        NSLog("sAiity launch: screenCapture=\(CGPreflightScreenCaptureAccess())")

        NotificationCenter.default.addObserver(forName: .saiityResetBubble, object: nil,
                                               queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in self?.overlay.resetPosition() }
        }
        NotificationCenter.default.addObserver(forName: .saiityMicSettingChanged, object: nil,
                                               queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                await self.capture.applyMicSetting()
                // Say what happened: turning it off mid-session is exactly
                // the moment someone wants confirmation that it is off.
                switch self.capture.micStatus {
                case .off where self.state.isActive:
                    self.setStatus("Microphone released — captions continue from system audio")
                case .mixing:
                    self.setStatus("Microphone added to the captions")
                case .denied:
                    self.setStatus("Captions run without your microphone — allow sAiity under System Settings → Privacy & Security → Microphone")
                case .failed:
                    self.setStatus("Captions run without your microphone — it could not be started")
                default:
                    break
                }
            }
        }

        HotKeyCenter.shared.register(.toggleCaptions) { [weak self] in
            self?.toggle()
        }
        HotKeyCenter.shared.register(.copyLastLine) { [weak self] in
            self?.copyCurrentLine()
        }
        HotKeyCenter.shared.register(.toggleBubble) { [weak self] in
            self?.toggleBubbleHidden()
        }
        HotKeyCenter.shared.register(.recentCaptions) { [weak self] in
            self?.showRecentCaptions()
        }
        HotKeyCenter.shared.register(.clearCaption) { [weak self] in
            self?.clearCaption()
        }
        // Keep the menu-bar picker and the window in step — they write the same
        // preference, so without this they silently disagree.
        NotificationCenter.default.addObserver(forName: .saiityTranslateTargetChanged, object: nil,
                                               queue: .main) { [weak self] note in
            let t = note.userInfo?["target"] as? String
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.translateTo = t
                // Hold the row open for as long as translation is on, so the
                // bubble does not change height every time a translation
                // lands and clears.
                self.overlay.reservesTranslationRow =
                    t != nil && CaptionStyle.current.showTranslation
                if t == nil { self.overlay.applyStyle(CaptionStyle.current) }
                // Changing the translation target no longer changes which
                // recognition engine runs — that was only ever true for
                // Whisper, which has been cut.
                self.rebuildMenu()
                // Releases the outgoing model before loading its replacement,
                // and collapses a burst of changes into one load.
                self.swapTranslator()
            }
        }

        NotificationCenter.default.addObserver(forName: .saiityEngineChanged, object: nil,
                                               queue: .main) { [weak self] note in
            guard let raw = note.userInfo?["engine"] as? String,
                  let parsed = ASREngine(rawValue: raw),
                  let e = ASREngine.visibleSelection(parsed) else { return }
            // Delivered on .main, but the closure itself is nonisolated. Hop
            // explicitly instead of assuming the dispatch queue is the actor.
            Task { @MainActor [weak self] in self?.engineChanged(to: e) }
        }

        // Nemotron is one multilingual model that identifies the language from
        // audio, so there is no locale to choose and nothing to query. This used
        // to round-trip the system speech daemon on every launch.
        statusLine = String(localized: "Idle")
        rebuildMenu()
        // First run: explain, get the permission, and download deliberately —
        // rather than the old behaviour of doing all three silently behind a
        // "Start captions" click and then failing.
        //
        // Skipped under SAIITY_AUTOSTART, which is the headless/e2e path and
        // must not put a window on screen.
        let autostart = TestHooks.autostart
        if Onboarding.needsRun && !autostart {
            OnboardingWindowController.shared.show(state: SettingsWindowController.state)
        }
        if autostart { start() }
        // Sibling of SAIITY_AUTOSTART: this is a menu-bar app, so there is no
        // way to reach the settings window from a script, which makes checking
        // its layout after a change needlessly manual.
        if TestHooks.openSettings {
            SettingsWindowController.show()
        }
        if TestHooks.preview {
            // The window server can drop an order request made in the first
            // applicationDidFinishLaunching pass. Use the same settled-launch
            // boundary as the dictation toast so the preview exercises the
            // real overlay rather than a window that exists but is not drawn.
            Self.scheduleAfterLaunch { [weak self] in
                self?.overlay.showPreview()
            }
        }
        launchFinished = true
        let pending = pendingOpenURLs
        pendingOpenURLs.removeAll(keepingCapacity: true)
        if !pending.isEmpty { handleOpenURLs(pending) }
    }

    private func startDictationHotkey() -> Bool {
        guard dictationHotkeyMonitor.start(
            onPress: { [weak self] in
                Task { @MainActor in self?.dictationController.press() }
            },
            onRelease: { [weak self] in
                Task { @MainActor in self?.dictationController.release() }
            }) else { return false }
        // Warm an installed model immediately so the first key press starts
        // recording quickly. A missing model stays cold here; preparation on
        // the first press is what should initiate the deliberate download.
        if Self.dictationModelIsInstalled() {
            if DictationRecognizer.selected == .whisper {
                dictationPrewarmTask?.cancel()
                dictationPrewarmTask = Task { @MainActor [weak self] in
                    do {
                        try await self?.prepareSelectedWhisperModelForUse()
                    } catch is CancellationError {
                        return
                    } catch {
                        Diagnostics.recordFailure(operation: "dictation.prewarm",
                                                  reason: error.localizedDescription)
                    }
                }
            } else {
                dictationController.prepare()
            }
        }
        return true
    }

    private static func dictationModelIsInstalled() -> Bool {
        if DictationRecognizer.selected == .whisper {
            return WhisperDictationBackend.isReady(WhisperDictationBackend.model)
        }
        let engine = ASREngine.dictationEffective
        if engine == .nemotron {
            // Dictation's tier, not the caption tier: readiness for a tier the
            // dictation path will never load is not readiness.
            if NemotronEngine.hasExplicitDictationChunkSelection {
                return NemotronEngine.isDownloaded(chunkMs: NemotronEngine.dictationSelectedChunkMs)
            }
            return NemotronEngine.availableChunkMs.contains {
                NemotronEngine.isDownloaded(chunkMs: $0)
            }
        }
        return false
    }

    /// AppKit can accept a panel order request during application launch while
    /// still dropping it before the window server has settled. Start the global
    /// monitor after a short post-launch grace period so its initial ready state
    /// can render in the same way as a later dictation toast.
    static func scheduleAfterLaunch(_ action: @escaping @MainActor () -> Void) {
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            action()
        }
    }

    /// Input Monitoring can become available after launch (for example after
    /// the user accepts the privacy prompt). Keep trying while dictation is on
    /// so the shortcut does not silently depend on reopening sAiity.
    private func ensureDictationHotkey() {
        guard SettingsWindowController.state.dictationEnabled else { return }
        if startDictationHotkey() {
            dictationHotkeyRetryTask?.cancel()
            dictationHotkeyRetryTask = nil
            return
        }
        dictationController.markWaitingForInputMonitoring()
        guard dictationHotkeyRetryTask == nil else { return }
        dictationHotkeyRetryTask = Task { @MainActor [weak self] in
            while let self, !Task.isCancelled, SettingsWindowController.state.dictationEnabled {
                try? await Task.sleep(for: .seconds(2))
                guard !Task.isCancelled else { return }
                if self.startDictationHotkey() {
                    self.dictationHotkeyRetryTask = nil
                    return
                }
            }
        }
    }

    /// Launching an already-running menu-bar app (double-clicking it in Finder,
    /// or `open -a`) otherwise does nothing at all, which reads as broken.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        SettingsWindowController.show()
        return true
    }

    /// Quitting has to wait for the transcript, and this is the only place it
    /// can: the process is gone the moment `applicationWillTerminate` returns,
    /// while a line's append may still be queued.
    ///
    /// `.terminateLater` is the AppKit way to say "not yet" — the reply comes
    /// from the flush itself, once the last sentence is on disk. The previous
    /// shape could not do this at all: a semaphore wait on the main thread for
    /// main-actor work, which is either a deadlock or a 2-second freeze.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // A backstop reply, so a flush that somehow never finishes cannot make
        // the app unquittable — the one failure mode worse than losing a line.
        let deadline = Task { @MainActor in
            try? await Task.sleep(for: .seconds(15))
            sender.reply(toApplicationShouldTerminate: true)
        }
        Task { @MainActor in
            await self.flushOnQuit()
            deadline.cancel()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    /// Close the transcript cleanly on quit, otherwise the last lines are on
    /// disk but meta.json still says the session never ended.
    func applicationWillTerminate(_ note: Notification) {
        dictationHotkeyMonitor.stop()
        dictationHotkeyRetryTask?.cancel()
        dictationController.cancel()
        dictationToast.dismiss()
        // The backstop for a quit that never asked: closing the sentence is
        // idempotent, and `end()` returns on an already-closed handle. The real
        // flush happens in `applicationShouldTerminate`, which is where the
        // process can still be held open for it.
        closeSentence()
        let sem = DispatchSemaphore(value: 0)
        Task.detached {
            try? await TranscriptStore.shared.end()
            sem.signal()
        }
        _ = sem.wait(timeout: .now() + 2)
    }

    /// Everything a quit owes the transcript: the sentence in progress, the
    /// write it queues, and the handle.
    @MainActor
    func flushOnQuit() async {
        dictationHotkeyMonitor.stop()
        dictationHotkeyRetryTask?.cancel()
        dictationController.cancel()
        dictationToast.dismiss()
        // The sentence the recogniser is still assembling at ⌘Q is real speech.
        // Nothing else ever closes it — `closeSentence()` runs on punctuation, a
        // speech gap, the length cap, and teardown — so quitting dropped the
        // last line of every session that ended with the app rather than with
        // punctuation, even though the words were recognised and on screen.
        closeSentence()
        // That sentence queued a transcript write, and the store drops an append
        // that arrives after `end()`.
        await drainTranscriptWrites(within: .seconds(2))
        await endRecording()
    }

    /// Wait for every queued transcript write to reach the store, or for the
    /// budget to run out.
    ///
    /// `async` is the whole point. Those writes are main-actor work, so a
    /// synchronous wait on the main thread cannot let them run at all; suspending
    /// here gives the main actor back exactly long enough. The bound matters
    /// too: quitting must not hang because one translation is slow.
    @MainActor
    func drainTranscriptWrites(within budget: Duration) async {
        let deadline = ContinuousClock.now + budget
        while pendingTranscriptWrites > 0, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    private func updateDictationToast(_ phase: DictationPhase) {
        switch phase {
        case .idle:
            dictationToast.dismiss()
        case .waitingForInputMonitoring, .preparing:
            dictationToast.show(phase: phase)
        case .ready:
            dictationToast.show(phase: phase, autoDismissAfter: .seconds(4.5))
        case .starting:
            // Do not let a previous result flash while a new recording is
            // being prepared. The finished result is shown only from the
            // terminal `.result` phase below.
            lastDictationResult = nil
            dictationFeedbackTask?.cancel()
            dictationFeedbackTask = nil
            dictationToast.show(phase: phase)
        case .dictating, .transcribing, .cleaning, .translating, .inserting, .limit:
            dictationToast.show(phase: phase)
        case .recovery, .failure:
            dictationToast.show(phase: phase)
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(2))
                if self.dictationController.phase.automaticallyDismissesToast {
                    self.dictationController.markReadyAfterFeedback()
                }
            }
        case .result(let message):
            if let output = lastDictationResult?.outputText.trimmingCharacters(in: .whitespacesAndNewlines),
               !output.isEmpty {
                dictationToast.show(resultText: output, autoDismissAfter: nil)
            } else {
                dictationToast.show(text: message, animated: false)
            }
            scheduleDictationFeedbackDismissal()
        }
        guard phase != .idle else { return }
    }

    private func showDictationDraft(_ text: String) {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        switch dictationController.phase {
        case .transcribing, .cleaning, .translating, .inserting:
            dictationToast.show(resultText: text, autoDismissAfter: nil)
        default:
            break
        }
    }

    private func scheduleDictationFeedbackDismissal() {
        dictationFeedbackTask?.cancel()
        dictationFeedbackTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(4.5))
            guard let self, !Task.isCancelled else { return }
            if self.dictationController.phase.automaticallyDismissesToast {
                self.dictationController.markReadyAfterFeedback()
            }
            self.dictationFeedbackTask = nil
        }
    }

    // MARK: - Menu

    /// Template symbols for menu items: monochrome, sized by the system, so
    /// they render like the OS's own menus in every appearance.
    private static func menuSymbol(_ name: String) -> NSImage? {
        let img = NSImage(systemSymbolName: name, accessibilityDescription: nil)
        img?.isTemplate = true
        return img
    }

    private func rebuildMenu() {
        let menu = NSMenu()
        // The engine's full name ("NVIDIA Nemotron (streaming, on-device)")
        // used to head the menu. It never changes while you work and it is on
        // the Captions page anyway; the status line below says the thing that
        // actually varies.
        if let rl = recordingLine {
            let r = NSMenuItem(title: rl, action: nil, keyEquivalent: "")
            r.isEnabled = false
            menu.addItem(r)
        }
        let s = NSMenuItem(title: statusLine, action: nil, keyEquivalent: "")
        s.isEnabled = false
        menu.addItem(s)
        menu.addItem(.separator())
        if Onboarding.needsRun {
            let setup = NSMenuItem(title: String(localized: "Finish setup…"),
                                   action: #selector(openSetup), keyEquivalent: "")
            setup.image = Self.menuSymbol("checklist")
            menu.addItem(setup)
            menu.addItem(.separator())
        }
        let toggleItem = NSMenuItem(title: state.isActive ? String(localized: "Stop captions") : String(localized: "Start captions"),
                                    action: #selector(toggle), keyEquivalent: "")
        if let sc = HotKeyCenter.shortcut(for: .toggleCaptions), sc.isUsable {
            // Shown for discoverability. The real binding is the global hot key —
            // a menu keyEquivalent only fires while this app is frontmost, which
            // a menu-bar app never is.
            // Glue only. The modifier glyphs and the brackets read the same in every
            // locale, so this deliberately does not go through the catalog.
            toggleItem.title += "  (\(sc.displayString))"
        }
        toggleItem.image = Self.menuSymbol("captions.bubble")
        menu.addItem(toggleItem)

        let clearItem = NSMenuItem(title: String(localized: "Clear the caption"),
                                   action: #selector(clearCaptionFromMenu),
                                   keyEquivalent: "")
        if let sc = HotKeyCenter.shortcut(for: .clearCaption), sc.isUsable {
            // Shown for discoverability, same as Start/Stop. The real binding
            // is the global hot key; a menu key equivalent only fires while
            // this menu-bar app is frontmost, which it is not.
            clearItem.title += "  (\(sc.displayString))"
        }
        clearItem.image = Self.menuSymbol("xmark.circle")
        clearItem.tag = Self.clearCaptionMenuTag
        clearItem.isEnabled = CaptionLatencyCopy.clearEnabled(
            showingCaption: overlay.hasVisibleCaption)
        menu.addItem(clearItem)

        let chord = SettingsWindowController.state.dictationChord.displayString
        let dictationItem = NSMenuItem(title: String(localized: "Hold \(chord) to Dictate"),
                                       action: nil, keyEquivalent: "")
        dictationItem.image = Self.menuSymbol("mic")
        dictationItem.isEnabled = false
        menu.addItem(dictationItem)

        // Translation, transcript export, and model choices live in Settings.
        // The menu stays focused on actions needed while captions are running.

        menu.addItem(.separator())
        // "Settings…" with ⌘, — the name and the shortcut every Mac app uses
        // for this command. "Open sAiity…" described the window, not the verb.
        let settings = NSMenuItem(title: String(localized: "Settings…"), action: #selector(openMainWindow),
                                  keyEquivalent: ",")
        settings.image = Self.menuSymbol("gear")
        menu.addItem(settings)
        let update = NSMenuItem(title: String(localized: "Check for Updates…"),
                                action: #selector(SPUStandardUpdaterController.checkForUpdates(_:)),
                                keyEquivalent: "")
        update.target = updater
        menu.addItem(update)
        // terminate(_:) lives on NSApplication, not on this delegate. Without an
        // explicit target, assignTargets below would point it at AppDelegate,
        // which does not implement it — and the item silently does nothing.
        let quit = NSMenuItem(title: String(localized: "Quit sAiity"), action: #selector(NSApplication.terminate(_:)),
                              keyEquivalent: "q")
        quit.target = NSApp
        menu.addItem(quit)
        assignTargets(menu)
        menu.delegate = self
        guard let statusItem else { return }
        statusItem.menu = menu
    }

    /// Caption text arrives without rebuilding the menu. Refresh Clear when
    /// the menu opens so it is disabled when the bubble has nothing on it.
    func menuWillOpen(_ menu: NSMenu) {
        // A status change rebuilds the whole menu, including the download
        // progress ticks that fire several times a second. Doing that while
        // the menu is tracking dismisses it under the cursor, because
        // `statusItem.menu = …` replaces the very menu NSStatusItem is showing.
        // So: coalesce the rebuild, and never replace the menu that is open.
        menuIsTracking = true
        menuRebuildPending = false
        guard let item = menu.item(withTag: Self.clearCaptionMenuTag) else { return }
        item.isEnabled = CaptionLatencyCopy.clearEnabled(
            showingCaption: overlay.hasVisibleCaption)
    }

    /// The rebuild `scheduleMenuRebuild` held back. Doing it here rather than
    /// waiting for the next status change means the line the user just read was
    /// not stale, without ever swapping the menu out from under them.
    func menuDidClose(_ menu: NSMenu) {
        menuIsTracking = false
        guard menuRebuildPending else { return }
        menuRebuildPending = false
        rebuildMenu()
    }

    @objc private func clearCaptionFromMenu(_ sender: Any?) {
        clearCaption()
    }

    private static let clearCaptionMenuTag = 174


    /// Only claim items that have not already chosen a target — otherwise this
    /// steals actions meant for NSApp.
    private func assignTargets(_ menu: NSMenu) {
        for item in menu.items where item.action != nil && item.target == nil {
            item.target = self
        }
    }

    /// The menu-bar status line.
    ///
    /// Takes a `String.LocalizationValue` rather than a `String` on purpose: a
    /// bare literal at a call site then goes through the catalog automatically,
    /// and forgetting one becomes a compile-time question instead of something
    /// you only discover by launching in German. Every status the user reads
    /// while captions start, run and fail comes through here.
    private func setStatus(_ text: String.LocalizationValue) {
        setStatus(localized: String(localized: text))
    }

    /// For text that is already localised — the ASR and translator progress
    /// sinks, whose messages carry runtime percentages and so are localised at
    /// the producer.
    private func setStatus(localized text: String) {
        statusLine = text
        scheduleMenuRebuild()
    }

    /// A model download reports progress several times a second, and each report
    /// used to build a fresh `NSMenu` and hand it to the status item. That is a
    /// full menu construction — every item, every localized title, every
    /// `DateFormatter` for the recording line — several times a second, on the
    /// main actor, for a string the user can only see by opening the menu.
    ///
    /// Two guards. One rebuild per runloop turn, however many reports land in
    /// it. And none at all while a menu is tracking, because
    /// `statusItem.menu = …` replaces the very menu NSStatusItem is showing and
    /// dismisses it under the cursor; the pending flag is honoured in
    /// `menuDidClose` instead.
    private func scheduleMenuRebuild() {
        menuRebuildPending = true
        guard !menuIsTracking else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, self.menuRebuildPending, !self.menuIsTracking else { return }
            self.rebuildMenu()
        }
    }

    /// Prefixed to the status line so "this is being written down" is the first
    /// thing the menu says.
    private var recordingLine: String? {
        guard let since = recordingSince else { return nil }
        let m = Int(Date().timeIntervalSince(since) / 60)
        return String(localized: "● Recording · \(m) min · \(recordedLines) lines")
    }

    // MARK: - Actions

    @objc private func saveTranscriptChangedExternally(_ note: Notification) {
        guard let on = note.userInfo?["on"] as? Bool, on != saveTranscript else { return }
        applySaveTranscript(on)
    }

    /// The single place recording is turned on or off, wherever the request
    /// came from.
    private func applySaveTranscript(_ on: Bool) {
        saveTranscript = on
        UserDefaults.standard.set(saveTranscript, forKey: "saveTranscript")

        // Say the quiet part once, the first time it is switched on.
        if saveTranscript, !UserDefaults.standard.bool(forKey: "recordingNoticeShown") {
            UserDefaults.standard.set(true, forKey: "recordingNoticeShown")
            let a = NSAlert()
            a.messageText = String(localized: "Transcripts are saved to this Mac")
            a.informativeText = String(localized: """
                Sessions are written to ~/Library/Application Support/de.aiity.saiity \
                and never leave the device.

                System audio includes everyone on a call — and with "Include my \
                microphone" switched on, your own side as well. Recording other \
                people may require their consent, or be regulated where you are — \
                it is worth telling them.
                """)
            a.addButton(withTitle: String(localized: "OK"))
            a.alertStyle = .informational
            a.runModal()
        }

        if state.isActive {
            Task { @MainActor in
                if saveTranscript { await beginRecording() } else { await endRecording() }
                rebuildMenu()
            }
        } else {
            rebuildMenu()
        }
    }

    @objc private func copyCurrentLine() {
        let line = lastFinalText.isEmpty ? lastVolatileText : lastFinalText
        guard !line.isEmpty else { return }
        Clipboard.copy(line)
        setStatus("Line copied")
    }

    @objc private func copyWholeSession() {
        guard !sessionLines.isEmpty else { return }
        Clipboard.copy(Export.txt(sessionLines))
        setStatus("Session copied (\(sessionLines.count) lines)")
    }

    /// Save the current live session directly into the transcript library. This
    /// is intentionally independent of the opt-in persistent recorder.
    private func saveSubtitlesTranscript() {
        Task { @MainActor [weak self] in
            guard let self else { return }
            // Wait for any in-flight translation and ordered store append to
            // settle, so the library copy contains the final visible state.
            await self.transcriptWriteChain?.value
            let segments = self.sessionLines
            guard !segments.isEmpty else {
                self.setStatus("That transcript has no lines.")
                return
            }
            let locale = self.locale.identifier(.bcp47)
            let target = self.translateTo
            let startedAt = self.subtitleSessionStartedAt ?? Date()
            let work = Task.detached(priority: .userInitiated) {
                Result { try TranscriptStore.saveSession(segments, locale: locale,
                                                          translateTo: target,
                                                          startedAt: startedAt) }
            }
            switch await work.value {
            case .success:
                SessionCatalog.invalidate()
                self.setStatus("Transcript saved to library")
            case .failure(let error):
                NSLog("sAiity transcript library save failed: \(error.localizedDescription)")
                self.setStatus("Could not save transcript")
            }
        }
    }

    private func beginRecording() async {
        do {
            try await TranscriptStore.shared.begin(locale: locale.identifier(.bcp47),
                                                   translateTo: translateTo)
            SessionCatalog.invalidate()
            recordingSince = Date()
            recordedLines = 0
            overlay.isRecording = true
            updateStatusItemIcon()
        } catch {
            NSLog("sAiity recording failed to start: \(error.localizedDescription)")
            setStatus("Could not start recording")
        }
    }

    private func endRecording() async {
        try? await TranscriptStore.shared.end()
        SessionCatalog.invalidate()
        recordingSince = nil
        overlay.isRecording = false
        updateStatusItemIcon()
    }

    @MainActor
    private func transcriptRecordingFailed(_ error: Error) {
        NSLog("sAiity transcript write failed: \(error.localizedDescription)")
        saveTranscript = false
        UserDefaults.standard.set(false, forKey: "saveTranscript")
        recordingSince = nil
        recordedLines = 0
        overlay.isRecording = false
        SessionCatalog.invalidate()
        updateStatusItemIcon()
        setStatus("Transcript recording stopped")
    }

    /// The menu-bar icon fills in while a transcript is being written, so the
    /// state is never ambiguous.
    /// The menu-bar icon: the app's own icon, drawn down to menu-bar size.
    ///
    /// The only place the icon is set — it used to be assigned here AND at
    /// launch, so changing it meant changing both and the launch one silently
    /// won until the first recording toggle.
    ///
    /// Recording adds a red dot rather than swapping the glyph. The app icon is
    /// colour art, so there is no filled/outline pair to switch between, and a
    /// dot is what the rest of the app already uses for this.
    private func updateStatusItemIcon() {
        let side: CGFloat = 18
        let recording = overlay.isRecording
        // applicationIconImage is what the Dock and Finder show; asking for it
        // by name depends on CFBundleIconFile resolving, which it does not in a
        // bare SwiftPM build.
        let source = NSApp.applicationIconImage ?? NSImage(named: "AppIcon")

        let img = NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            if let source {
                source.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1)
            } else if let sym = NSImage(systemSymbolName: "captions.bubble",
                                        accessibilityDescription: nil) {
                sym.draw(in: rect)
            }
            if recording {
                NSColor.systemRed.setFill()
                NSBezierPath(ovalIn: NSRect(x: rect.maxX - 7, y: rect.maxY - 7,
                                            width: 6, height: 6)).fill()
            }
            return true
        }
        // Never a template: templates are flattened to a silhouette, which would
        // throw away the whole point of using the app icon.
        img.isTemplate = source == nil
        img.accessibilityDescription = recording ? String(localized: "sAiity, recording") : "sAiity"
        // There is no status item before launch finishes — the quit flush ends
        // recording, and ending recording repaints the icon.
        guard let statusItem else { return }
        statusItem.button?.image = img
    }

    /// Swap engines live. Recognition restarts; capture keeps running, so no
    /// audio is lost beyond the model-load gap.
    @MainActor
    private var engineTier = NemotronEngine.selectedChunkMs

    private func engineChanged(to new: ASREngine) {
        // The tier is part of the engine's identity: same enum case, different
        // tier means a different model on disk and a different backend.
        let newTier = NemotronEngine.selectedChunkMs
        guard new != engine || newTier != engineTier else { return }
        engine = new
        engineTier = newTier
        ASREngine.selected = new
        // `.running`, not `isActive`. `isActive` includes `.starting`, so
        // changing engine while the first download was in flight spawned this
        // untracked task to stop and rebuild the backend the start Task was at
        // that moment loading into.
        let wasRunning = state == .running
        Task { @MainActor in
            if state.isActive { await stopAsync() }
            await dictationController.invalidatePreparedBackend()
            await asrBackendPool.replace(with: Self.makeActiveBackend())
            setStatus("Engine: \(new.displayName)")
            if wasRunning, state == .idle { start() }
            rebuildMenu()
        }
    }

    @objc private func openMainWindow() {
        Task { @MainActor in SettingsWindowController.show() }
    }

    @objc private func openSetup() {
        Task { @MainActor in
            OnboardingWindowController.shared.show(state: SettingsWindowController.state)
        }
    }



    @objc private func toggle() {
        state.isActive ? stop() : start()
    }

    /// Mirror of Settings → Captions → "Show the caption bubble", reachable
    /// without opening Settings. Hiding the subtitles when a scene needs the
    /// bottom of the screen is the one thing a viewer wants mid-film, and it
    /// used to require the Settings window — while captions kept playing over
    /// the video. Recognition keeps running either way.
    private func toggleBubbleHidden() {
        var st = CaptionStyle.current
        st.hidden.toggle()
        CaptionStyle.current = st
        if !st.hidden { overlay.reveal() }
    }

    /// "What did I miss": flash the last few closed sentences in the bubble,
    /// then hand the display back to the live caption. Recognition already
    /// holds them — sessionLines is the in-memory session record whether or
    /// not saving is on — the overlay just never looked back. A new chunk
    /// arriving mid-flash simply overwrites it; live always wins.
    private var recentFlashTask: Task<Void, Never>?
    private func showRecentCaptions() {
        guard state == .running else { return }
        let recent = sessionLines.suffix(3).enumerated().map { index, segment in
            CaptionHistoryEntry(sentenceID: -1_000_000 - index,
                                 original: segment.text,
                                 translation: segment.tr)
        }
        guard !recent.isEmpty else { return }
        recentFlashTask?.cancel()
        overlay.showHistory(recent)
        let generation = sessionGeneration
        recentFlashTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 6_000_000_000)
            // The generation guard, not just `.running`: Stop-then-Start
            // inside the flash window leaves a NEW session running, and this
            // task would otherwise paint the previous session's snapshot over
            // its "listening…" line.
            guard let self, !Task.isCancelled, self.state == .running,
                  self.sessionGeneration == generation else { return }
            var parts = self.sentenceParts
            if !self.lastVolatileText.isEmpty { parts.append(self.lastVolatileText) }
            let live = Self.trimmedForDisplay(parts)
            // Falling back to lastFinalText is what keeps the display contract:
            // between a closed sentence and the next one's first volatile,
            // BOTH sentenceParts and lastVolatileText are empty, and showing
            // that emptied the bubble — erasing the sentence that is supposed
            // to stay on screen until its successor replaces it.
            self.overlay.clearHistory()
            if live.isEmpty {
                guard !self.lastFinalText.isEmpty else { return }
                self.overlay.show(text: self.lastFinalText, isFinal: true,
                                 sentenceID: self.displayLifecycle.sentenceID)
            } else {
                self.overlay.show(text: live, isFinal: self.lastVolatileText.isEmpty,
                                 sentenceID: self.displayLifecycle.sentenceID)
            }
        }
    }

    /// Wipe what is on screen, and keep it wiped until the next sentence.
    ///
    /// Display only: the sentence being assembled still reaches the transcript,
    /// and the recogniser is untouched. Without the suppression the very next
    /// volatile chunk would redraw the whole assembled sentence — including the
    /// words just cleared — which makes the button look broken. Recording it
    /// against the sentence ID means normal captions resume by themselves when
    /// the speaker starts the next one; there is no state to get stuck in.
    private func clearCaption() {
        // Commit the current display state before hiding it. Volatile text is
        // cumulative, so it belongs after the settled parts and must not be
        // redisplayed by the next ASR revision.
        if !lastVolatileText.isEmpty {
            sentenceParts.append(lastVolatileText)
            lastVolatileText = ""
        }
        if !sentenceParts.isEmpty {
            closeSentence()
        }
        displayLifecycle.clearCurrentSentence()
        clearCaptionInstant = .now
        recentFlashTask?.cancel()
        recentFlashTask = nil
        overlay.clearHistory(keepVisible: true)
        shownTranslationID = nil
    }

    /// The caption label's value changes silently — macOS has no SwiftUI-style
    /// live region — so without explicit announcements assistive tech never
    /// learns a caption arrived, and for a deaf-blind user on a braille
    /// display the captions ARE the product. A no-op unless VoiceOver (or
    /// another assistive client) is listening.
    private func announce(_ text: String) {
        NSAccessibility.post(element: NSApp as Any,
                             notification: .announcementRequested,
                             userInfo: [.announcement: text,
                                        .priority: NSAccessibilityPriorityLevel.medium.rawValue])
    }

    /// `saiity://` automation: Shortcuts' Open-URL action, Raycast, and
    /// script runners all drive URL schemes for free. App Intents would be
    /// the nicer surface, but this bundle is hand-assembled from `swift
    /// build` — appintentsmetadataprocessor never runs, so Shortcuts would
    /// not discover intents. The URL scheme is the route that actually works
    /// under this build system.
    ///
    /// Verbs are idempotent where they can be: `start` on a running session
    /// and `stop` on an idle one do nothing, so an automation that fires
    /// twice cannot invert the user's intent the way a bare toggle would.
    func application(_ application: NSApplication, open urls: [URL]) {
        guard launchFinished else {
            pendingOpenURLs.append(contentsOf: urls)
            return
        }
        handleOpenURLs(urls)
    }

    private func handleOpenURLs(_ urls: [URL]) {
        for url in urls where url.scheme == "saiity" {
            let verb = (url.host ?? url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))).lowercased()
            NSLog("sAiity url: \(verb)")
            switch verb {
            case "toggle": toggle()
            case "start": if !state.isActive { start() }
            case "stop": if state.isActive { stop() }
            case "copy": copyCurrentLine()
            // The whole running session, which no other surface can reach: it
            // has not been written to disk yet, and will not be at all unless
            // saving is on. Off the menu, still scriptable.
            case "copyall": copyWholeSession()
            case "bubble": toggleBubbleHidden()
            case "recent": showRecentCaptions()
            // A deterministic preview is useful for Shortcuts and for checking
            // the overlay after a display or macOS update without starting ASR.
            case "preview": overlay.showPreview()
            default:
                NSLog("sAiity url: unknown verb \(verb)")
            }
        }
    }

    private func start() {
        // Ignore a second Start while one is already in flight. Without this,
        // two starts each brought up their own SCStream and their own ASR pump,
        // and two pumps calling process() concurrently is the exact overlap
        // StreamingASRBackend documents as a reproduced crash.
        guard state == .idle else {
            // Silently returning here is what made the wedge invisible: during a
            // teardown the menu said Idle and offered Start, and every press did
            // nothing at all.
            if state == .stopping { setStatus("Still stopping — try again in a moment") }
            return
        }
        // The other half of "one translator at a time". Re-translation refuses
        // to start during a session; without this, a session was free to start
        // during a re-translation — the same two multi-gigabyte models in
        // memory at once, by the other route, on a machine this app has
        // already been taught not to push into swap.
        guard !CaptionSession.shared.isRetranslating else {
            setStatus("Translating a saved transcript — wait for that to finish, or cancel it")
            overlay.show(text: String(localized: "Translating a saved transcript. Wait for it to finish, or cancel it under Transcripts."),
                         isFinal: true)
            return
        }
        // Nothing chosen means nothing to run. This used to proceed on a
        // defaulted engine and turn Start into consent for a 634 MB download the
        // user had never been shown — the whole reason the selection is now
        // allowed to be empty. Say what to do instead of doing it.
        guard let chosen = ASREngine.selected else {
            setStatus("No recognition model chosen — pick one in Settings → Models")
            overlay.show(text: String(localized: "Choose a recognition model in Settings → Models."),
                         isFinal: true)
            return
        }
        // A chosen engine whose bytes are missing is a different case: the user
        // picked it, so downloading is what they asked for — but say so first.
        if chosen.needsDownload {
            setStatus("Downloading \(chosen.displayName) before captions can start…")
        }
        state = .starting
        speechGapTask?.cancel()
        speechGapTask = nil
        translatorIdleEviction.cancel()
        showedAnyCaption = false
        captionFirstTextLogged = false
        captionFirstFinalLogged = false
        captionWarmStart = asrBackendPool.isPrepared
        captionStartInstant = .now
        captionCaptureStartedAt = nil
        clearCaptionInstant = nil
        overlay.reservesTranslationRow =
            translateTo != nil && CaptionStyle.current.showTranslation
        sessionLines.removeAll()
        captionTranslationTasks.values.forEach { $0.cancel() }
        captionTranslationTasks.removeAll()
        captionTranslationCache.removeAll(keepingCapacity: true)
        subtitleSessionStartedAt = Date()
        pendingTranslations = 0
        shownTranslationID = nil
        displayLifecycle = CaptionDisplayLifecycle()
        pendingLiveText = nil
        lastLiveTranslationRequest = nil
        // A recap flash from the previous session has nothing to restore into
        // this one; its generation guard would drop it anyway, but a pending
        // task that outlives its subject is worth ending outright.
        recentFlashTask?.cancel()
        recentFlashTask = nil
        sessionGeneration += 1
        transcriptWriteChain = nil
        lastFinalText = ""
        lastVolatileText = ""
        sentenceParts.removeAll()
        sentenceWords.removeAll()
        detector.reset()
        detectedLanguage = nil
        setStatus("Starting…")
        overlay.show(text: String(localized: "starting…"), isFinal: false)

        // Frozen with the backend this session starts WITH. Engine and tier
        // are both user-switchable mid-load, and re-reading `.effective` at
        // the end would attribute this load's outcome — damage or health —
        // to whichever model happens to be selected by then.
        let asrAssetID = ASREngine.effective.activeAssetID

        sessionTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let backend = asrBackendPool.currentBackend
                NSLog("sAiity engine: preparing \(backend.name)")
                let prepareStarted = self.captionStartInstant ?? .now
                do {
                    let acquired = try await asrBackendPool.acquire(locale: locale) { [weak self] msg in
                        Task { @MainActor [weak self] in
                            guard let self, self.state == .starting else { return }
                            self.setStatus(localized: msg)
                            self.overlay.show(text: msg, isFinal: false)
                        }
                    }
                    captionBackend = acquired
                    captureSink.point(at: acquired)
                    Diagnostics.recordTiming(operation: "captions.asr.prepare",
                                             seconds: self.elapsedSeconds(since: prepareStarted),
                                             cold: !self.captionWarmStart)
                    // Every await below is a place the user may have pressed
                    // Stop — prepare() alone can be a multi-gigabyte download.
                    // Bail before touching the microphone-equivalent, not after.
                    try Task.checkCancellation()

                    let backendStart = ContinuousClock.now
                    try await acquired.start { [weak self] chunk in
                        Task { @MainActor [weak self] in self?.render(chunk) }
                    }
                    Diagnostics.recordTiming(operation: "captions.backend.start",
                                             seconds: self.elapsedSeconds(since: backendStart),
                                             cold: !self.captionWarmStart)
                } catch {
                    // The inner catch exists to scope damage-recording to the
                    // MODEL failing: everything after this point (capture,
                    // permissions) fails for reasons no re-download fixes.
                    switch error {
                    case is CancellationError: break
                    case let e as URLError where e.code == .cancelled: break
                    default:
                        LoadHealth.recordFailureIfInstalled(
                            asrAssetID, reason: error.localizedDescription)
                    }
                    throw error
                }
                LoadHealth.clear(asrAssetID)
                try Task.checkCancellation()

                guard let backend = captionBackend,
                      let fmt = await backend.inputFormat else {
                    throw BackendError.notPrepared
                }
                try Task.checkCancellation()
                captureFormat = fmt
                let captureStart = ContinuousClock.now
                try await capture.start(
                    targetFormat: fmt,
                    // Capture the backend we are starting WITH, rather than
                    // reading self.backend on each buffer. This closure runs on
                    // the capture queue ~50×/s while the main actor may be
                    // reassigning that property during an engine swap — an
                    // unsynchronised read/write of a class reference. Binding it
                    // once also guarantees the audio goes to the engine the
                    // stream was configured for.
                    onBuffer: { [captureSink] buf in
                        captureSink.feed(buf)
                    },
                    onState: { audio in
                        Task { @MainActor [self] in self.captureStateChanged(audio) }
                    })
                self.captionCaptureStartedAt = .now
                Diagnostics.recordTiming(operation: "captions.capture.start",
                                         seconds: self.elapsedSeconds(since: captureStart),
                                         cold: !self.captionWarmStart)
                // Commit on a pause, which is what makes a finished sentence
                // translate when the speaker stops rather than when a 3.5 s
                // budget runs out.
                capture.onSpeechGap = { [weak self] range in
                    Task { @MainActor in self?.scheduleSpeechGapCommit(range) }
                }

                if saveTranscript { await beginRecording() }
                state = .running
                setStatus("Listening · \(Self.coverageNote())")
                // ASR must be visible while the optional translator warms up.
                overlay.show(text: String(localized: "listening…"), isFinal: false)
                // The global hotkey gives no feedback a screen reader can
                // perceive; a no-op unless one is listening.
                announce(String(localized: "Captions started"))
                // The mic is an addition; its failure is reported, never
                // propagated — but silently running without it would break
                // the transcript the user turned it on for.
                switch capture.micStatus {
                case .denied:
                    setStatus("Captions run without your microphone — allow sAiity under System Settings → Privacy & Security → Microphone")
                case .failed:
                    setStatus("Captions run without your microphone — it could not be started")
                case .off, .mixing:
                    break
                }
                NSLog("sAiity engine: started; preparing translator")
                await prepareTranslatorIfNeeded()
                // Translator preparation may finish after the first caption.
                // Never paint the listening placeholder over that caption.
                if state == .running, !showedAnyCaption {
                    overlay.show(text: String(localized: "listening…"), isFinal: false)
                }
            } catch is CancellationError {
                // stopAsync() is awaiting us; it owns the teardown from here.
                NSLog("sAiity engine: start cancelled before capture began")
            } catch let e as URLError where e.code == .cancelled {
                // The same event, spelled differently. FluidAudio's downloader
                // cancels the underlying URLSessionDataTask, so a Stop pressed
                // during the first model download surfaces as URLError.cancelled
                // and not CancellationError — which used to fall through to the
                // branch below, stomp `state` back to .idle while stopAsync was
                // mid-teardown holding .stopping, and show the user "Error:
                // cancelled" for something they had just asked for.
                NSLog("sAiity engine: start cancelled during download")
            } catch {
                let msg = error.localizedDescription
                // Claim the teardown before the first await. `state` is only
                // touched on the main actor, so this pair is atomic against
                // stopAsync — whichever gets here first owns it, and the other
                // sees .stopping and leaves the resources alone.
                let ownsTeardown = (state == .starting)
                if ownsTeardown { state = .stopping }
                // The failure most likely on a first run — Screen Recording not
                // granted, thrown from capture.start — happens AFTER prepare and
                // start have both succeeded, so the model is loaded and the pump
                // is looping. Setting .idle and returning left both running with
                // the menu claiming there was no session.
                if ownsTeardown {
                    await releaseSessionResources()
                    state = .idle
                }
                // The bubble can be switched off entirely (Settings → Captions),
                // and a bare "Error" in the menu is then the only thing a failed
                // first download says. Put the reason where it is always visible.
                // After the teardown, so nothing it does overwrites the reason.
                setStatus("Error: \(msg)")
                overlay.show(text: msg, isFinal: true)
                NSLog("sAiity start failed: \(msg)")
            }
        }
    }

    /// Acts on a confirmed language change.
    ///
    /// Switching the recogniser is deliberately conservative. The locale is more
    /// a decoding hint than a model selector — the de-* and en-* transcribers
    /// share one multilingual model, and English audio transcribes verbatim
    /// through a German locale — so a restart usually buys nothing and costs a
    /// gap in the captions. We only switch when a model for the detected
    /// language is genuinely installed and differs from the current one.
    /// Report the detected language. With a single multilingual engine there
    /// is nothing to switch — the value's real job is telling the translator
    /// what the source language actually is.
    /// Schedule one pause commit at a time. A capture callback can arrive
    /// again while the previous watermark is still draining; the newest gap is
    /// the only boundary worth committing.
    private func scheduleSpeechGapCommit(_ range: Range<Int>) {
        speechGapTask?.cancel()
        let generation = sessionGeneration
        speechGapTask = Task { @MainActor [weak self] in
            await self?.commitAtSpeechGap(range, generation: generation)
        }
    }

    /// Commit whatever is pending because the speaker paused. The capture
    /// detector reports a 48 kHz sample-clock range; the backend waits until
    /// its converted queue has processed that same point before flushing. This
    /// removes the old fixed sleeps and keeps sentence boundaries stable when
    /// the model is faster or slower than the balanced tier.
    private func commitAtSpeechGap(_ range: Range<Int>, generation: Int) async {
        guard state == .running, generation == sessionGeneration else { return }
        guard let backend = captionBackend else { return }
        let sampleRate = await backend.inputFormat?.sampleRate ?? 16_000
        let target = Int(ceil(Double(range.upperBound)
                              / SystemAudioCapture.streamSampleRate
                              * sampleRate))
        await backend.drain(toAudioSample: target)
        guard !Task.isCancelled,
              state == .running,
              generation == sessionGeneration else { return }
        await backend.flushPending()
        guard !Task.isCancelled,
              state == .running,
              generation == sessionGeneration else { return }

        // Punctuation is the ASR endpoint. A pause after a comma or colon is
        // only acoustic evidence, so keep the thought open and wait for either
        // punctuation, another confirmed gap, or the length cap.
        if let last = lastFinalText.last,
           Self.clauseContinuations.contains(last) {
            return
        }
        closeSentence()
    }

    /// What the running engine can hear, said up front.
    ///
    /// This has to be proactive, because the reactive check cannot work for the
    /// case that matters: an English-only engine fed German does not emit
    /// German, it emits English-shaped gibberish ("decuts on shout altem
    /// fenster" — measured). The text detector reads that as English and never
    /// fires, and Parakeet has no audio-level language identification to ask.
    /// So the constraint is stated when captions start, not discovered later.
    private static func coverageNote() -> String {
        switch ASREngine.effective.coverage {
        case .manyDetectedFromAudio:
            return String(localized: "detecting language")
        case .only(let codes):
            let names = codes.sorted().map {
                Locale.current.localizedString(forLanguageCode: $0) ?? $0
            }
            return String(localized: "\(names.joined(separator: ", ")) only")
        }
    }

    private func languageDetected(_ code: String) {
        let name = Locale.current.localizedString(forLanguageCode: code) ?? code
        // An engine that cannot hear this language does not fail — it produces
        // fluent nonsense, which looks like the app working badly rather than
        // being pointed at the wrong model. Say so plainly.
        let engine = ASREngine.effective
        guard engine.canHear(code) else {
            let supported: String
            if case .only(let codes) = engine.coverage {
                supported = codes.sorted().map {
                    Locale.current.localizedString(forLanguageCode: $0) ?? $0
                }.joined(separator: ", ")
            } else {
                supported = String(localized: "the selected languages")
            }
            setStatus("\(engine.displayName) recognises \(supported) only — this sounds like \(name)")
            overlay.show(text: String(localized: "\(engine.displayName) only recognises \(supported). This sounds like \(name) — switch engine in Settings → Captions."),
                         isFinal: true)
            return
        }
        setStatus("Listening · \(name)")
    }

    private func stop() {
        Task { @MainActor in await stopAsync() }
    }

    /// The awaitable form. `stop()` deliberately returns immediately for the
    /// menu, but anything that needs the models actually released — deleting
    /// them, for one — has to be able to wait for the teardown.
    private func stopAsync() async {
        guard state != .stopping else { return }
        // Announce only what actually stopped. stopAsync is also the teardown
        // path releaseEverything() takes when Settings deletes a model with
        // nothing running, and a VoiceOver user was told "Captions stopped"
        // for deleting weights while idle.
        let wasRunning = state.isActive
        state = .stopping
        if wasRunning { announce(String(localized: "Captions stopped")) }
        // Not "Idle". Cancelling a model download in flight can take a moment,
        // and this await used to sit behind a menu that already said Idle and
        // offered Start — while `start()` bailed on `guard state == .idle`, so
        // every press was silently ignored.
        setStatus("Stopping…")

        // Cancel an in-flight start and WAIT for it. Cancellation alone is not
        // enough: the start Task may be suspended inside a model download, and
        // if we tore down here without waiting it would resume afterwards and
        // bring the audio stream up behind our back — capture running with the
        // menu reading "Start captions".
        sessionTask?.cancel()
        await sessionTask?.value
        sessionTask = nil

        // A translator swap is fired and forgotten from the notification, so it
        // can be mid-load right now and would otherwise finish onto a session
        // that no longer exists.
        translatorSwap?.cancel()
        await translatorSwap?.value
        translatorSwap = nil

        // Order inside: backend.stop() emits whatever was still volatile, and
        // closeSentence() catches the sentence it lands in, so the last thing
        // said reaches the transcript instead of being dropped with the session.
        // Queued transcript writes then have to land before the recording
        // closes: TranscriptStore is an actor, so once end() has closed the
        // handle a still-pending append is silently dropped.
        await releaseSessionResources()
        overlay.clear()
        state = .idle
        scheduleTranslatorEvictionIfIdle()
        // The status said "Stopping…" for the whole teardown; say what is true
        // now that it has finished.
        setStatus("Idle")
    }

    /// Hand back everything a session holds.
    ///
    /// Split out of `stopAsync()` so the failed-start path can share it. The
    /// property that makes that safe is what it does NOT do: it never touches
    /// `sessionTask`. Calling `stopAsync()` from inside the start Task would
    /// make that task await its own `sessionTask?.value` and never return.
    ///
    /// Every step is safe on a session that never got that far — `capture.stop()`
    /// nils a stream that was never created, `backend.stop()` no-ops on a nil
    /// pump, `TranscriptStore.end()` returns on a nil handle — which is why the
    /// two callers can both run it without coordinating.
    @MainActor
    private func releaseSessionResources() async {
        speechGapTask?.cancel()
        speechGapTask = nil
        await capture.stop()
        // Stop delivering audio before returning the lease. Otherwise a capture
        // callback racing teardown can feed a backend that the pool has already
        // marked idle.
        captureSink.point(at: nil)
        if let backend = captionBackend {
            await backend.stop()
            await asrBackendPool.release(backend, discard: false)
            captionBackend = nil
        }
        closeSentence()
        if await TranscriptStore.shared.isRecording {
            await transcriptWriteChain?.value
        }
        transcriptWriteChain = nil
        await endRecording()
        MemoryPolicy.releaseCaches()
        NSLog("sAiity memory: session released — \(MemoryPolicy.describeFootprint())")
    }

    /// Stop and drop every loaded model, so their files can be removed for real.
    @MainActor
    private func releaseModels() async {
        await stopAsync()
        await dictationController.invalidatePreparedBackend()
        await asrBackendPool.replace(with: AppDelegate.makeActiveBackend())
        await unloadTranslator(reason: "model deletion")
        await dictationCleanupSession.invalidate()
    }

    /// Silence is not the same as a broken pipeline, and the UI must not let the
    /// two look alike. With nothing playing, capture keeps running perfectly and
    /// delivers pure zeros forever; if the buffers themselves stop, the stream
    /// died and that is a real error.
    @MainActor
    private func captureStateChanged(_ audio: SystemAudioCapture.State) {
        // Named `audio` rather than `state` so it cannot be confused with the
        // session state below — they mean very different things, and the
        // original shadowing hid which one this guard was testing.
        guard state == .running else { return }
        if TestHooks.verboseLogging {
            NSLog("sAiity capture state: \(audio)")
        }
        let tag = AppLanguage(code: locale.identifier(.bcp47)).displayName
        switch audio {
        case .audible:
            setStatus("Listening · \(tag)")
        case .silent:
            // Utterance boundary: commit the volatile tail so it reaches the
            // transcript and the translator.
            if let backend = captionBackend {
                Task { await backend.flushPending() }
            }
            setStatus("Listening · nothing is playing")
            if !showedAnyCaption { overlay.show(text: String(localized: "nothing is playing"), isFinal: false) }
        case .stalled:
            setStatus("Audio stream stopped — press Stop, then Start")
            overlay.show(text: String(localized: "audio stream stopped"), isFinal: true)
        }
    }

    /// Render the chunk as-is. Volatile results are *cumulative for the current
    /// utterance* — they grow from "Die" to the full sentence — so appending them
    /// to the previous final would print the sentence twice. The last final simply
    /// stays on screen until the next utterance's first volatile replaces it.
    @MainActor
    private func render(_ chunk: TranscriptChunk) {
        let text = DictationVocabulary.preservingSpelling(
            in: chunk.text.trimmingCharacters(in: .whitespacesAndNewlines))
        guard !text.isEmpty else { return }
        // After committing a sentence the engine often emits a lone "." as the
        // start of the next one; showing that would blank the bar to a dot.
        guard text.rangeOfCharacter(from: .alphanumerics) != nil else { return }
        if let startedAt = subtitleSessionStartedAt {
            let elapsed = captionCaptureStartedAt.map { elapsedSeconds(since: $0) }
                ?? Date().timeIntervalSince(startedAt)
            if !captionFirstTextLogged {
                NSLog("sAiity caption timing: first-text %.3fs", elapsed)
                Diagnostics.recordTiming(operation: "captions.first-text",
                                         seconds: elapsed,
                                         cold: captionWarmStart)
                captionFirstTextLogged = true
            }
            if chunk.isFinal, !captionFirstFinalLogged {
                NSLog("sAiity caption timing: first-final %.3fs", elapsed)
                Diagnostics.recordTiming(operation: "captions.first-final",
                                         seconds: elapsed,
                                         cold: captionWarmStart)
                captionFirstFinalLogged = true
            }
            if chunk.isFinal, chunk.end > 0, let captureStarted = captionCaptureStartedAt {
                let visibleLag = max(0, elapsedSeconds(since: captureStarted) - chunk.end)
                Diagnostics.recordTiming(operation: "captions.visible-lag",
                                         seconds: visibleLag,
                                         cold: captionWarmStart)
            }
        }
        if TestHooks.verboseLogging {
            NSLog("sAiity chunk final=%@ chars=%d", chunk.isFinal ? "true" : "false", text.count)
        }
        showedAnyCaption = true

        // The first words of a new sentence replace the last one on screen. The
        // translation under them belongs to the sentence that just left — but
        // clearing it here was wrong: recognition is faster than translation,
        // so with continuous speech the next sentence's first chunk always beat
        // the 0.2–1.2 s translation, which was then also discarded for having
        // the wrong ID. The row was blanked and then never filled — visible as
        // "the update removes the translation".
        //
        // So the rows are decoupled. The old translation stays, dimmed to say
        // it belongs to the previous line, until its successor replaces it —
        // and only a translation two or more sentences stale is cleared, since
        // under two newer sentences it no longer helps anyone.
        advanceToNextSentenceIfNeeded()

        // The user cleared this sentence off the screen. Keep tracking it —
        // the transcript still gets it — but do not paint it back.
        let suppressed = displayLifecycle.isCleared(displayLifecycle.sentenceID)

        guard chunk.isFinal else {
            // Still being revised: show it after the part of the sentence that
            // has already settled, so the line reads forward instead of being
            // replaced by its own tail.
            lastVolatileText = text
            if !suppressed {
                if let clearedAt = clearCaptionInstant {
                    Diagnostics.recordTiming(operation: "captions.clear-to-visible",
                                             seconds: elapsedSeconds(since: clearedAt))
                    clearCaptionInstant = nil
                }
                overlay.show(text: Self.trimmedForDisplay(sentenceParts + [text]),
                             isFinal: false, sentenceID: displayLifecycle.sentenceID)
            }
            return
        }

        // A committed clause EXTENDS the sentence on screen; it does not replace
        // it. The engine commits a clause every few seconds so that continuous
        // speech still produces captions, but those units are not sentences —
        // "Mac abspielt" on its own is not something anyone can read, and handed
        // to a translator it comes back as "Mac plays." Assembling them here is
        // what puts a whole thought on screen and gives the translator a whole
        // thought to work with.
        if sentenceParts.isEmpty { sentenceStart = chunk.start }
        sentenceEnd = chunk.end
        sentenceParts.append(text)
        sentenceWords.append(contentsOf: chunk.words)
        lastVolatileText = ""
        lastFinalText = Self.joinClauses(sentenceParts)
        if !suppressed {
            if let clearedAt = clearCaptionInstant {
                Diagnostics.recordTiming(operation: "captions.clear-to-visible",
                                         seconds: elapsedSeconds(since: clearedAt))
                clearCaptionInstant = nil
            }
            overlay.show(text: Self.trimmedForDisplay(sentenceParts), isFinal: true,
                         sentenceID: displayLifecycle.sentenceID)
        }

        // Finished, or run on for so long that waiting costs more than an
        // awkward break. Speech that carries no punctuation at all — most of
        // what the multilingual model emits — is closed by the pause instead,
        // from commitAtSpeechGap().
        let ended = lastFinalText.last.map(Self.sentenceTerminators.contains) ?? false
        if ended || lastFinalText.count >= Self.maxSentenceChars {
            closeSentence()
        } else if TranslationTiming.current == .live {
            // The sentence is still open; in live mode, translate what exists
            // of it so far. The close will produce the authoritative version.
            kickLiveTranslation(of: lastFinalText,
                                sentenceID: displayLifecycle.sentenceID)
        }
    }

    /// Starts the next display row after a completed sentence. Keeping this in
    /// one place is important because punctuation and the pause boundary both
    /// close rows through the same lifecycle.
    private func advanceToNextSentenceIfNeeded() {
        guard displayLifecycle.sentenceClosed, sentenceParts.isEmpty,
              displayLifecycle.advanceIfNeeded() else { return }
        if let shown = shownTranslationID,
           displayLifecycle.sentenceID - shown >= 2 {
            shownTranslationID = nil
        } else if let shown = shownTranslationID {
            overlay.markTranslationStale(forSentenceID: shown)
        }
    }

    /// Live-mode translation of the still-open sentence: display only, never
    /// the transcript. Single-flight with latest-wins — neither translator can
    /// be cancelled mid-decode, so queueing every clause would fall permanently
    /// behind, and only the newest text is ever worth translating. A request
    /// arriving while one runs replaces whatever was waiting, and the newest
    /// waiter runs when the current one finishes.
    @MainActor
    private func kickLiveTranslation(of text: String, sentenceID: Int) {
        // `!sentenceClosed`: once the sentence closes, the authoritative
        // translation from emitSentence owns the row. The display ID does not
        // bump until the NEXT sentence renders, so the ID check alone
        // leaves a window where a stale partial still passes.
        guard sentenceID == displayLifecycle.sentenceID,
              !displayLifecycle.sentenceClosed,
              !displayLifecycle.isCleared(sentenceID),
              translateTo != nil, translatorReady,
              CaptionStyle.current.showTranslation else { return }
        // The close path skips lines already in the target language; making
        // the same call about the same text here keeps live mode from filling
        // the row with an LLM's paraphrase of a line the close path then
        // deliberately refuses to translate — which would stand for two
        // sentences with nothing to correct it.
        if alreadyInTargetLanguage(text) { return }
        let source = captionSourceLanguage(for: text)
        guard let target = translateTo else { return }
        let request = LiveTranslationRequest(text: text,
                                             sentenceID: sentenceID,
                                             source: source,
                                             target: target,
                                             engine: TranslationEngine.effective)
        // Recognition can emit the same revision more than once. Avoid
        // decoding identical input again while keeping different sentences
        // distinct even when their text happens to match.
        guard request != lastLiveTranslationRequest else { return }
        if liveTranslationBusy {
            pendingLiveText = (text, sentenceID)
            return
        }
        lastLiveTranslationRequest = request
        liveTranslationBusy = true
        let srcCode = source
        let generation = sessionGeneration
        Task { @MainActor in
            defer {
                liveTranslationBusy = false
                if let next = pendingLiveText {
                    pendingLiveText = nil
                    kickLiveTranslation(of: next.text, sentenceID: next.sentenceID)
                }
                scheduleTranslatorEvictionIfIdle()
            }
            beginTranslatorUse()
            defer { endTranslatorUse() }
            guard let engine = activeTranslator else { return }
            let engineKind = activeTranslatorEngine
            let translationStarted = ContinuousClock.now
            guard let out = try? await translatorInferenceGate.run({
                await self.translateCaptionText(text,
                                                fallbackSource: srcCode,
                                                target: target,
                                                engine: engine)
            }), !out.isEmpty else {
                Diagnostics.recordTiming(operation: "captions.translation",
                                         seconds: self.elapsedSeconds(since: translationStarted),
                                         cold: false)
                if let engineKind {
                    retireFailedTranslator(engineKind, reason: "live inference returned no output")
                }
                return
            }
            Diagnostics.recordTiming(operation: "captions.translation",
                                     seconds: self.elapsedSeconds(since: translationStarted),
                                     cold: false)
            // Same guards as the authoritative path: not across a session
            // boundary, and only under the sentence it translates. The
            // `!sentenceClosed` leg drops a partial that resolves after the
            // sentence closed — it would race the authoritative translation
            // behind the translator's serial lock, and landing second it
            // rewrote the settled row with an older, shorter text.
            guard sessionGeneration == generation,
                  displayLifecycle.sentenceID == sentenceID,
                  !displayLifecycle.sentenceClosed,
                  !displayLifecycle.isCleared(sentenceID),
                  CaptionStyle.current.showTranslation else { return }
            if TestHooks.verboseLogging {
                NSLog("sAiity live translated: chars=%d target=%@", out.count, target)
            }
            overlay.showTranslation(out, forSentenceID: sentenceID)
            shownTranslationID = sentenceID
        }
    }

    /// Hand the assembled sentence on: language detection, translation, and the
    /// transcript all work on the whole thing rather than on a clause of it.
    @MainActor
    private func closeSentence() {
        guard !sentenceParts.isEmpty else { return }
        let text = Self.joinClauses(sentenceParts)
        let chunk = TranscriptChunk(text: text, isFinal: true,
                                    start: sentenceStart, end: sentenceEnd,
                                    words: sentenceWords)
        sentenceParts.removeAll()
        sentenceWords.removeAll()
        // Its original stays on screen until the next sentence starts rendering.
        displayLifecycle.closeSentence()
        lastVolatileText = ""
        // A live partial queued behind the busy slot is now superseded: the
        // close translates the full sentence anyway, so re-kicking the queued
        // partial would translate the same words twice and race the result.
        pendingLiveText = nil
        // Sentence-final is the natural throttle: volatile revisions would
        // queue faster than VoiceOver speech or a braille display can render.
        if UserDefaults.standard.bool(forKey: "announceCaptions") {
            announce(text)
        }
        emitSentence(text, chunk: chunk,
                     sentenceID: displayLifecycle.sentenceID)
    }

    /// True when the line already reads as the target language. Shared by the
    /// close path and live mode so both make the same call about the same
    /// text. Under 12 characters detection is noise ("Ja." reads as Finnish),
    /// so short lines never skip.
    private func alreadyInTargetLanguage(_ text: String) -> Bool {
        guard text.count >= 12, let target = translateTo else { return false }
        let fallback = LanguageDetector.languageCode(in: text)
            ?? detectedLanguage
            ?? locale.identifier(.bcp47)
        let spans = CaptionLanguageSpanDetector.analyze(text,
                                                         fallbackLanguage: fallback)
        guard !spans.isEmpty else { return false }
        return spans.allSatisfy { span in
            guard let language = span.language else { return false }
            return TranslationLanguage.isSame(language, as: target)
        }
    }

    private func captionSourceLanguage(for text: String) -> String {
        LanguageDetector.languageCode(in: text)
            ?? detectedLanguage
            ?? locale.identifier(.bcp47)
    }

    /// Translate a mixed-language caption span by span. A dominant language is
    /// still useful for short, single-language lines, but it must never be
    /// passed as the source for an obviously mixed sentence.
    private func translateCaptionText(_ text: String,
                                      fallbackSource: String,
                                      target: String,
                                      engine: any Translating) async -> String? {
        let spans = CaptionLanguageSpanDetector.analyze(
            text,
            fallbackLanguage: fallbackSource)
        guard !spans.isEmpty else { return nil }
        guard CaptionLanguageSpanDetector.isMixed(spans) else {
            return await engine.translate(text, from: fallbackSource, to: target)
        }

        var translated = spans.map(\.text)
        var pending: [(index: Int, span: CaptionLanguageSpan)] = []
        for (index, span) in spans.enumerated() {
            guard let source = span.language else { continue }
            if TranslationLanguage.isSame(source, as: target) { continue }
            pending.append((index, span))
        }

        if pending.count > 1 {
            let regions = pending.map {
                TranslationRegion(text: $0.span.text, source: $0.span.language ?? "auto")
            }
            if let values = await engine.translateRegions(regions, to: target),
               values.count == pending.count {
                for (item, value) in zip(pending, values) where !value.isEmpty {
                    translated[item.index] = value
                }
            }
        }

        for item in pending where translated[item.index] == item.span.text {
            guard let source = item.span.language else { continue }
            guard let value = await engine.translate(item.span.text,
                                                     from: source,
                                                     to: target),
                  !value.isEmpty else { continue }
            translated[item.index] = value
        }
        return CaptionTextMerger.join(translated)
    }

    private func emitSentence(_ text: String, chunk: TranscriptChunk, sentenceID: Int) {

        // Detection runs on the ACCUMULATED transcript, never a single line:
        // one-word lines are noise ("Ja." reads as Finnish, "Okay." as English).
        if let changed = detector.add(text) {
            if TestHooks.verboseLogging {
                NSLog("sAiity detected language: \(changed)")
            }
            detectedLanguage = changed
            languageDetected(changed)
        } else if detectedLanguage == nil {
            // The text detector needs 60 characters and two agreeing readings.
            // Nemotron identifies the language from the audio itself and has an
            // answer within a couple of seconds, which is the difference between
            // warning about a wrong engine now and warning about it a paragraph
            // from now. It latches once per session, so the text detector still
            // owns any later switch.
            Task { @MainActor [weak self] in
                guard let self, self.detectedLanguage == nil,
                      let backend = self.captionBackend,
                      let audio = await backend.detectedLanguage() else { return }
                let code = audio.split(separator: "-").first.map(String.init) ?? audio
                self.detectedLanguage = code
                self.languageDetected(code)
            }
        }

        // Skip TRANSLATION when the line is already in the target language —
        // cheaper than asking any engine, and it silences an LLM's temptation
        // to paraphrase. Only the translation: this used to `return`, which
        // silently dropped the line from the transcript as well, so a session
        // in the target language recorded nothing at all.
        var wantsTranslation = translateTo != nil
        if wantsTranslation, alreadyInTargetLanguage(text) {
            wantsTranslation = false
        }

        // The segment claims its index NOW, synchronously — never after an
        // await. Each line's translation takes as long as the model takes, so
        // two in-flight lines routinely finish out of order; claiming the index
        // on completion wrote sentence B before sentence A, and every SRT
        // export of that session was permanently mis-ordered.
        let idx = sessionLines.count
        let generation = sessionGeneration

        // Frozen here, not re-read after the awaits below. The translate task
        // and the write chain both used to read the mutable `translateTo`, so a
        // target changed from the menu bar mid-flight could translate a line
        // into one language and record another.
        let target = translateTo
        let translationEngine = activeTranslatorEngine ?? TranslationEngine.effective
        let translationGeneration = translatorGeneration

        // Backpressure: see maxPendingTranslations. `translatorReady` is in the
        // test as well, so a line is not queued against a translator that has
        // not loaded — it kept a slot and produced nothing.
        let translating = wantsTranslation && translatorReady
            && pendingTranslations < Self.maxPendingTranslations
        if translating {
            pendingTranslations += 1
        } else if wantsTranslation {
            NSLog("sAiity translate: skipped, ready=\(translatorReady), \(pendingTranslations) queued")
        }

        // A turn break when ≥2 s of audio-clock silence sits between this
        // sentence and the last — measured on the segments' own timestamps,
        // so it needs no extra state and no acoustic guesswork.
        let turn = idx > 0 && chunk.start - sessionLines[idx - 1].t1 >= 2.0

        // `trLoc` is nil here on purpose. It is a record of OUTCOME, not of
        // intent, so only the site that assigns `tr` may assign it — otherwise
        // every line of a session whose translator failed to load claims a
        // translation that was never attempted. Session-level intent already
        // has a home in SessionMeta.translateTo.
        let srcCode = captionSourceLanguage(for: text)
        let translationKey = CaptionTranslationKey(text: text,
                                                   source: srcCode,
                                                   target: target ?? "",
                                                   engine: translationEngine)
        let cachedTranslation = translating ? captionTranslationCache[translationKey] : nil
        sessionLines.append(Segment(i: idx, t0: chunk.start, t1: chunk.end,
                                    text: text, loc: srcCode,
                                    tr: nil, trLoc: nil,
                                    words: chunk.words.isEmpty ? nil : chunk.words,
                                    turn: turn ? true : nil))

        // Translate concurrently; the result is patched in by index.
        let translation: Task<String?, Never> = Task { @MainActor in
            guard translating else { return nil }
            defer {
                // A task from the previous session can finish after the next
                // session has reset the counter and reused this index. Do not
                // decrement the new session or remove its cancellation entry.
                if self.sessionGeneration == generation {
                    self.pendingTranslations -= 1
                    self.captionTranslationTasks[idx] = nil
                }
                self.scheduleTranslatorEvictionIfIdle()
            }
            guard self.sessionGeneration == generation,
                  self.translatorGeneration == translationGeneration,
                  let target else { return nil }

            let out: String
            if let cachedTranslation {
                // Cache hits still go through the same generation and overlay
                // patch path as fresh inference. Returning early here used to
                // save the translation on disk while leaving the live row stale.
                out = cachedTranslation
            } else {
                self.beginTranslatorUse()
                defer { self.endTranslatorUse() }
                guard let engine = activeTranslator else { return nil }
                let engineKind = activeTranslatorEngine
                let translationStarted = ContinuousClock.now
                // Empty counts as nothing translated. MADLAD returns "" for a
                // short or noisy caption — it has no emptiness check, unlike
                // the LLM path's sanitizer — and an empty string is non-nil,
                // so it would otherwise record a translation that is not there.
                guard let translated = try? await translatorInferenceGate.run({
                    await self.translateCaptionText(text,
                                                    fallbackSource: srcCode,
                                                    target: target,
                                                    engine: engine)
                }), !translated.isEmpty else {
                    Diagnostics.recordTiming(operation: "captions.translation",
                                             seconds: self.elapsedSeconds(since: translationStarted),
                                             cold: false)
                    if let engineKind {
                        self.retireFailedTranslator(engineKind,
                                                    reason: "caption inference returned no output")
                    }
                    return nil
                }
                Diagnostics.recordTiming(operation: "captions.translation",
                                         seconds: self.elapsedSeconds(since: translationStarted),
                                         cold: false)
                out = translated
            }

            guard self.sessionGeneration == generation,
                  self.translatorGeneration == translationGeneration else { return nil }
            if cachedTranslation == nil {
                self.captionTranslationCache[translationKey] = out
            }
            if TestHooks.verboseLogging, cachedTranslation == nil {
                NSLog("sAiity translated engine=%@ chars=%d target=%@",
                      activeTranslatorEngine?.rawValue ?? "unknown", out.count, target)
            }
            if idx < self.sessionLines.count {
                self.sessionLines[idx].tr = out
                // Assigned beside `tr`, never before it.
                self.sessionLines[idx].trLoc = target
            }
            // Current sentence: show it plainly. One sentence late: still show
            // it, dimmed — the viewer just read that line, and a slightly late
            // translation they can attach to it beats the empty row that
            // discarding produced. Older than that: drop, it helps nobody.
            // A sentence the user cleared does not get its translation painted
            // back under the empty line a moment later.
            if CaptionStyle.current.showTranslation,
               !self.displayLifecycle.isCleared(sentenceID) {
                let behind = self.displayLifecycle.sentenceID - sentenceID
                if behind <= 0 {
                    self.overlay.showTranslation(out, forSentenceID: sentenceID)
                    self.shownTranslationID = sentenceID
                } else if behind == 1 {
                    self.overlay.showTranslation(out, forSentenceID: sentenceID, stale: true)
                    self.shownTranslationID = sentenceID
                }
            }
            return out
        }
        if translating { captionTranslationTasks[idx] = translation }

        // The on-disk store is append-only, so ORDER at the write is what makes
        // exports correct. Chain the writes: each link awaits the previous one,
        // then its own translation — lines land in claim order however long any
        // individual translation takes, and each still hits disk as soon as it
        // can, preserving the crash-safety of line-at-a-time appends.
        pendingTranscriptWrites += 1
        transcriptWriteChain = Task { @MainActor [previous = transcriptWriteChain] in
            // Counted, not chained: `transcriptWriteChain` is only cleared on
            // teardown, so it cannot say whether a write is still outstanding.
            // Quitting needs exactly that answer.
            defer { self.pendingTranscriptWrites -= 1 }
            await previous?.value
            let tr = await translation.value
            if await TranscriptStore.shared.isRecording {
                // Same rule on disk: the target is recorded only when there is a
                // translation to attach it to. This path never saw `translating`
                // at all, so it was the one that always claimed one.
                do {
                    try await TranscriptStore.shared.append(
                        chunk, locale: self.locale.identifier(.bcp47),
                        translation: tr,
                        translateTo: tr == nil ? nil : target,
                        turn: turn)
                    self.recordedLines += 1
                } catch {
                    self.transcriptRecordingFailed(error)
                }
            }
        }
    }
}
