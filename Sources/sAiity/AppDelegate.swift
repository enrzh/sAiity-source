import AppKit
import Sparkle
import AVFoundation
import CoreGraphics
import Foundation
import NaturalLanguage

/// Menu-bar app. No dock icon, no main window — just the caption bar.
///
/// Isolated to the main actor as a whole. Everything here is AppKit or drives
/// AppKit, and the alternative — a nonisolated class with `assumeIsolated` at
/// each entry point — let `beginRecording()` and `endRecording()` mutate an
/// NSView hierarchy and the status-item image from a cooperative-pool thread
/// after their first `await`. The compiler warned about it; nothing enforced it.
/// Class-level isolation makes that a build error instead.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    #if SAIITY_TEST_HOOKS
    var whisperPreparationForTests: (@Sendable (WhisperDictationBackend.ModelChoice, @escaping @Sendable (Progress) -> Void) async throws -> Void)?
    #endif
    private var statusItem: NSStatusItem!
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
    private var dictationHotkeyRetryTask: Task<Void, Never>?
    /// Captions and push-to-talk share this one prepared backend. The pool owns
    /// the warm model; callers hold only a temporary lease while feeding audio.
    private lazy var asrBackendPool = ASRBackendPool(makeBackend: AppDelegate.makeActiveBackend)
    private lazy var dictationController = DictationController(
        backendProvider: asrBackendPool,
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
        cleanupConfiguration: {
            DictationCleanupConfiguration(enabled: UserDefaults.standard.bool(forKey: "dictationCleanupEnabled"))
        },
        cleanup: { [weak self] text in
            guard let self,
                  LocalModel.selected?.isCleanupCompatible() == true,
                  let translator = self.activeTranslator as? LocalLLMTranslator else { return nil }
            return await translator.cleanup(text)
        },
        dictationUsesWhisper: { WhisperDictationBackend.isSelected },
        transcribeWhisper: { samples, locale in
            try await WhisperDictationBackend().transcribe(samples: samples, locale: locale)
        },
        whisperIsReady: { WhisperDictationBackend.isReady(WhisperDictationBackend.model) },
        onPhaseChanged: { [weak self] phase in
            self?.updateDictationToast(phase)
            self?.scheduleTranslatorEvictionIfIdle()
        })
    private let dictationHotkeyMonitor = DictationHotkeyMonitor()
    private let capture = SystemAudioCapture()
    private var engine = ASREngine.effective

    /// Production action for the deferred Task6 settings control.
    func prepareSelectedWhisperModelForUse(progress: @escaping @Sendable (Progress) -> Void = { _ in }) async throws {
        let choice = WhisperDictationBackend.model
        #if SAIITY_TEST_HOOKS
        if let hook = whisperPreparationForTests {
            try await hook(choice, progress)
            return
        }
        #endif
        let backend = WhisperDictationBackend()
        try await backend.prepareModelForUse(choice, progress: progress)
    }

    #if SAIITY_TEST_HOOKS
    var captionEngineForTests: ASREngine { engine }
    var captionPoolPreparedForTests: Bool { asrBackendPool.preparedForTests }
    var captionPoolLeaseForTests: Bool { asrBackendPool.hasActiveLeaseForTests }
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
        ASREngine.effective.makeBackend()
    }

    private var activeTranslator: Translating?
    private var translatorReady = false
    private let translatorIdleEviction = IdleEviction()

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
    private func swapTranslator() {
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
            let outgoing = self.activeTranslator
            self.activeTranslator = nil
            self.translatorReady = false
            await outgoing?.stop()
            // A newer choice landed while we were releasing. Let that one do the
            // loading rather than paying for a model already superseded.
            guard generation == self.translatorGeneration else { return }
            self.activeTranslator = TranslationEngine.effective.makeTranslator()
            await self.prepareTranslatorIfNeeded()
        }
    }

    /// Hand back everything the translator holds, without disturbing the
    /// session. Used when the system is short of memory.
    @MainActor
    private func unloadTranslator(reason: String) async {
        translatorIdleEviction.cancel()
        let outgoing = activeTranslator
        activeTranslator = nil
        translatorReady = false
        await outgoing?.stop()
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

    /// Load (and if necessary download) the selected translator. This was the
    /// missing link: the translator object was constructed but `prepare()` was
    /// never called, so MADLAD and Qwen never downloaded their weights and
    /// `translate()` quietly returned nil forever.
    @MainActor
    @discardableResult
    private func prepareTranslatorIfNeeded(requestedTarget: String? = nil,
                                           allowWithoutCaptions: Bool = false,
                                           sourceLanguage: String? = nil) async -> Bool {
        translatorIdleEviction.cancel()
        guard let target = Self.translationTargetForPreparation(captionsTarget: translateTo,
                                                                requestedTarget: requestedTarget) else {
            return false
        }
        guard !translatorReady else { return true }
        guard TranslationEngine.selected != nil else {
            // A target without a translator: honest, and recoverable in one step.
            setStatus("No translator chosen — pick one in Settings → Captions")
            return false
        }
        if activeTranslator == nil {
            activeTranslator = TranslationEngine.effective.makeTranslator()
        }
        guard let engine = activeTranslator else { return false }
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
        let src = sourceLanguage ?? detectedLanguage ?? locale.identifier(.bcp47)
        NSLog("sAiity translator: selected=\(TranslationEngine.effective.rawValue) object=\(engine.name) src=\(src) dst=\(target)")
        // Frozen BEFORE the await, like `target` above and for the same
        // reason: the user can switch translator — or Qwen model — while
        // prepare() runs, and reading `.effective` again at the end would
        // pin this load's outcome on whichever asset happens to be selected
        // then. A health record against a model that never ran is worse than
        // none: it offers "Re-download" for a file that is perfectly fine.
        let assetID = TranslationEngine.effective.activeAssetID
        do {
            try await engine.prepare(from: src, to: target) { [weak self] msg in
                NSLog("sAiity translator progress: \(msg)")
                Task { @MainActor in self?.setStatus(localized: msg) }
            }
            translatorReady = true
            if let assetID { LoadHealth.clear(assetID) }
            setStatus("Translating with \(TranslationEngine.effective.displayName)")
            return true
        } catch {
            translatorReady = false
            // Bytes on disk that refuse to load are damage worth remembering —
            // the Models page turns this into a "Re-download" the user can
            // actually connect to the error, instead of the same status-line
            // failure on every future session.
            switch error {
            case is CancellationError: break
            case let e as URLError where e.code == .cancelled: break
            default:
                if let assetID {
                    LoadHealth.recordFailureIfInstalled(assetID, reason: error.localizedDescription)
                }
            }
            setStatus("Translation unavailable: \(error.localizedDescription)")
            NSLog("sAiity translator prepare failed: \(error.localizedDescription)")
            return false
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
        translatorIdleEviction.cancel()
        defer { scheduleTranslatorEvictionIfIdle() }
        // A settings change replaces the translator asynchronously. Do not
        // translate against the old model while that replacement is in flight.
        await translatorSwap?.value
        guard SettingsWindowController.state.translateDictation,
              SettingsWindowController.state.dictationTranslateTo == target else {
            return nil
        }
        guard await prepareTranslatorIfNeeded(requestedTarget: target,
                                              allowWithoutCaptions: true,
                                              sourceLanguage: source),
              let engine = activeTranslator else { return nil }
        return await engine.translate(text, from: source, to: target)
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
              pendingTranslations == 0 else { return }
        translatorIdleEviction.schedule(
            after: .seconds(45),
            shouldEvict: { [weak self] in
                guard let self else { return false }
                return self.translatorReady
                    && self.state == .idle
                    && !self.dictationController.isBusy
                    && self.translatorSwap == nil
                    && !self.liveTranslationBusy
                    && self.pendingTranslations == 0
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

    private var locale = Locale(identifier: "en-US")
    /// BCP-47, nil = off. Persisted — it was previously an in-memory var, so the
    /// chosen target silently reset to "off" on every launch, which is one of the
    /// two reasons translation appeared not to work at all.
    private var translateTo: String? = UserDefaults.standard.string(forKey: "translateTo") {
        didSet { UserDefaults.standard.set(translateTo, forKey: "translateTo") }
    }
    private var statusLine = String(localized: "Idle")
    private var showedAnyCaption = false

    // Recording is deliberately separate from captioning and defaults to OFF:
    // captions are ephemeral, a transcript is a durable record of a conversation
    // other people were part of.
    private var saveTranscript = UserDefaults.standard.bool(forKey: "saveTranscript")
    private var recordingSince: Date?
    private var recordedLines = 0
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
    /// The sentence the user cleared from the bubble, if any. Captions for it
    /// stay suppressed; the next sentence renders normally.
    private var clearedSentenceID: Int?
    /// Live-mode translation of the still-open sentence: single-flight with
    /// latest-wins, because neither translator can be cancelled mid-decode —
    /// queueing every clause would fall permanently behind, and what matters is
    /// only ever the newest text.
    private var liveTranslationBusy = false
    private var pendingLiveText: (text: String, sentenceID: Int)?
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
    private var displaySentenceID = 0
    /// Set when a sentence is closed: the next content rendered belongs to the
    /// next sentence, whether it arrives as a final clause or as volatile text.
    private var sentenceClosed = false

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
        parts.reduce(into: "") { out, part in
            guard !out.isEmpty else { out = part; return }
            let runOn = (out.last.map(isSpaceless) ?? false)
                || (part.first.map(isSpaceless) ?? false)
            out += runOn ? part : " " + part
        }
    }

    private static func isSpaceless(_ c: Character) -> Bool {
        guard let s = c.unicodeScalars.first else { return false }
        switch s.value {
        // CJK punctuation and kana, CJK ideographs, Thai. Korean is written
        // WITH spaces despite being written in Hangul, so it is not here.
        case 0x3000...0x30FF, 0x3400...0x4DBF, 0x4E00...0x9FFF, 0x0E00...0x0E7F:
            return true
        default:
            return false
        }
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

    /// Recently chosen targets, so the menu stays short without being a fixed
    /// list that ignores what this person actually uses.
    @Defaults("recentTranslateTargets") private var recentTargets: [String] = []
    @Defaults("recentDictationTranslateTargets") private var recentDictationTargets: [String] = []

    private func rememberTarget(_ code: String) {
        var r = recentTargets.filter { $0 != code }
        r.insert(code, at: 0)
        recentTargets = Array(r.prefix(6))
    }

    private func rememberDictationTarget(_ code: String) {
        var r = recentDictationTargets.filter { $0 != code }
        r.insert(code, at: 0)
        recentDictationTargets = Array(r.prefix(6))
    }

    @objc private func showLanguagePicker() {
        SettingsWindowController.show()
        SettingsWindowController.state.showTranslationPicker = true
    }

    @objc private func showDictationLanguagePicker() {
        SettingsWindowController.showDictationTranslationPicker()
    }

    /// An LSUIElement app has no App menu, so this is the ONLY route to the
    /// version string and to the third-party notices the licences require to
    /// travel with the binary.
    @objc private func showAbout() {
        let credits: NSAttributedString
        if let url = Bundle.main.url(forResource: "Credits", withExtension: "txt"),
           let text = try? String(contentsOf: url, encoding: .utf8) {
            credits = NSAttributedString(
                string: text,
                attributes: [.font: NSFont.monospacedSystemFont(ofSize: 10, weight: .regular)])
        } else {
            credits = NSAttributedString(string: String(localized: "Credits file missing from this build."))
        }
        // Only take a Dock presence if we are not already holding one. begin()
        // used to run on every invocation while end() ran once, so opening
        // About twice left the agent app with a Dock icon for the rest of the
        // run. The observer below is the single owner of that balance.
        if aboutResignObserver == nil { ForegroundActivation.begin() }
        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationName: "sAiity",
            .credits: credits,
            .init(rawValue: "Copyright"): String(localized: "On-device live subtitles."),
        ])
        // The standard About panel has no close callback, so give up the Dock
        // presence when the app next loses focus. One-shot: the token has to be
        // held to be removed, and re-registering on every About would leak an
        // observer per invocation.
        guard aboutResignObserver == nil else { return }
        aboutResignObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated {
                    ForegroundActivation.end()
                    if let t = self.aboutResignObserver {
                        NotificationCenter.default.removeObserver(t)
                        self.aboutResignObserver = nil
                    }
                }
            }
    }

    private var aboutResignObserver: NSObjectProtocol?

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
        overlay.onOpenWindow = { SettingsWindowController.show() }
        overlay.onClear = { [weak self] in self?.clearCaption() }
        NotificationCenter.default.addObserver(
            self, selector: #selector(saveTranscriptChangedExternally(_:)),
            name: .saiitySaveTranscriptChanged, object: nil)
        // The gap threshold decides where sentences break, so a change should
        // land on the session the user is watching rather than the next one.
        NotificationCenter.default.addObserver(
            forName: .saiitySpeechGapChanged, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.capture.applySpeechGapSettings() }
            }
        rebuildMenu()
        if SettingsWindowController.state.dictationEnabled {
            Self.scheduleAfterLaunch { [weak self] in
                self?.ensureDictationHotkey()
            }
        }
        NotificationCenter.default.addObserver(forName: .saiityDictationSettingChanged,
                                               object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.dictationHotkeyMonitor.updateChord(SettingsWindowController.state.dictationChord)
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
            MainActor.assumeIsolated {
                self?.dictationHotkeyMonitor.setSuspended(note.object as? Bool ?? false)
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
            self?.overlay.resetPosition()
        }
        NotificationCenter.default.addObserver(forName: .saiityShowAbout, object: nil,
                                               queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.showAbout() }
        }
        NotificationCenter.default.addObserver(forName: .saiityMicSettingChanged, object: nil,
                                               queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                Task { @MainActor in
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
            MainActor.assumeIsolated {
                guard let self else { return }
                self.translateTo = t
                // Hold the row open for as long as translation is on, so the
                // bubble does not change height every time a translation
                // lands and clears.
                self.overlay.reservesTranslationRow =
                    t != nil && CaptionStyle.current.showTranslation
                if t == nil { self.overlay.showTranslation("") }
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
                  let e = ASREngine(rawValue: raw) else { return }
            // Delivered on .main, but the closure itself is nonisolated.
            MainActor.assumeIsolated { self?.engineChanged(to: e) }
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
    }

    private func startDictationHotkey() -> Bool {
        guard dictationHotkeyMonitor.start(
            onPress: { [weak self] in
                Task { @MainActor in self?.dictationController.press() }
            },
            onRelease: { [weak self] in
                Task { @MainActor in self?.dictationController.release() }
            }) else { return false }
        dictationController.prepare()
        return true
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

    /// Close the transcript cleanly on quit, otherwise the last lines are on
    /// disk but meta.json still says the session never ended.
    func applicationWillTerminate(_ note: Notification) {
        dictationHotkeyMonitor.stop()
        dictationHotkeyRetryTask?.cancel()
        dictationController.cancel()
        dictationToast.dismiss()
        guard recordingSince != nil else { return }
        let sem = DispatchSemaphore(value: 0)
        Task.detached {
            try? await TranscriptStore.shared.end()
            sem.signal()
        }
        _ = sem.wait(timeout: .now() + 2)
    }

    private func updateDictationToast(_ phase: DictationPhase) {
        switch phase {
        case .idle:
            dictationToast.dismiss()
        case .waitingForInputMonitoring:
            dictationToast.show(text: String(localized: "Allow Input Monitoring for Dictation"), animated: false)
        case .preparing:
            dictationToast.show(text: String(localized: "Preparing Dictation…"), animated: true)
        case .ready:
            let chord = SettingsWindowController.state.dictationChord.displayString
            dictationToast.show(text: String(localized: "Ready to Dictate · Hold \(chord)"),
                                animated: false,
                                autoDismissAfter: .seconds(4.5))
        case .starting:
            dictationToast.show(text: String(localized: "Starting Dictation…"), animated: true)
        case .dictating:
            dictationToast.show(text: String(localized: "Dictating…"), animated: true)
        case .transcribing, .cleaning, .inserting:
            dictationToast.show(text: String(localized: "Transcribing…"), animated: true)
        case .translating:
            dictationToast.show(text: String(localized: "Translating…"), animated: true)
        case .limit:
            dictationToast.show(text: String(localized: "Dictation limit reached"), animated: false)
        case .recovery(let text), .result(let text), .failure(let text):
            dictationToast.show(text: text, animated: false)
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(2))
                if self.dictationController.phase.automaticallyDismissesToast {
                    self.dictationController.markReadyAfterFeedback()
                }
            }
        }
        guard phase != .idle else { return }
        positionDictationToast()
    }

    private func positionDictationToast() {
        let mouse = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(mouse) })
                ?? NSScreen.main
                ?? NSScreen.screens.first else { return }
        let frame = screen.visibleFrame
        let size = dictationToast.frame.size
        dictationToast.setFrameOrigin(NSPoint(x: frame.midX - size.width / 2,
                                               y: frame.minY + 80))
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

        let chord = SettingsWindowController.state.dictationChord.displayString
        let dictationItem = NSMenuItem(title: String(localized: "Hold \(chord) to Dictate"),
                                       action: nil, keyEquivalent: "")
        dictationItem.image = Self.menuSymbol("mic")
        dictationItem.isEnabled = false
        menu.addItem(dictationItem)

        let captionsTranslation = translationMenuItem(
            scope: .captions,
            title: "Captions: Translate to",
            currentTarget: translateTo,
            recentTargets: recentTargets)
        captionsTranslation.image = Self.menuSymbol("globe")
        menu.addItem(captionsTranslation)

        let dictationTranslation = translationMenuItem(
            scope: .dictation,
            title: "Dictation: Translate to",
            currentTarget: SettingsWindowController.state.dictationTranslateTo,
            recentTargets: recentDictationTargets)
        dictationTranslation.image = Self.menuSymbol("globe")
        menu.addItem(dictationTranslation)

        // Everything about transcripts has left this menu: the saved-session
        // submenu, the Save-transcript toggle, and both Copy commands. They
        // live on the Transcripts page, which can do what a menu never could —
        // show the lines, search them, export them. Copying the current line
        // is still one click away on the bubble itself, where you are already
        // looking when you want it.

        menu.addItem(.separator())
        // "Settings…" with ⌘, — the name and the shortcut every Mac app uses
        // for this command. "Open sAiity…" described the window, not the verb.
        let settings = NSMenuItem(title: String(localized: "Settings…"), action: #selector(openMainWindow),
                                  keyEquivalent: ",")
        settings.image = Self.menuSymbol("gear")
        menu.addItem(settings)
        // About moved to Settings → General. It is not a thing you reach for
        // mid-session, but it must stay reachable *somewhere*: it is the only
        // surface for the third-party licences and the credits this app ships.
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
        statusItem.menu = menu
    }


    private func translationMenuItem(scope: TranslationMenuScope,
                                     title: String.LocalizationValue,
                                     currentTarget: String?,
                                     recentTargets: [String]) -> NSMenuItem {
        let item = NSMenuItem(title: String(localized: title), action: nil, keyEquivalent: "")
        let menu = NSMenu()
        let preferred = Locale.preferredLanguages.prefix(4).map {
            Locale(identifier: $0).language.languageCode?.identifier ?? $0
        }
        let entries = TranslationMenuModel.entries(
            scope: scope,
            currentTarget: currentTarget,
            recentTargets: recentTargets,
            preferredLanguages: Array(preferred),
            fallbackLanguages: ["en", "de"])
        for entry in entries {
            let title = entry.selection.code.map { AppLanguage(code: $0).displayName }
                ?? String(localized: "Off")
            let mi = NSMenuItem(title: title,
                                action: #selector(pickTranslation(_:)), keyEquivalent: "")
            mi.representedObject = entry.selection
            mi.state = entry.isSelected ? .on : .off
            menu.addItem(mi)
        }

        menu.addItem(.separator())
        let allSelector: Selector = scope == .captions
            ? #selector(showLanguagePicker)
            : #selector(showDictationLanguagePicker)
        let all = NSMenuItem(title: String(localized: "All languages…"), action: allSelector,
                             keyEquivalent: "")
        menu.addItem(all)

        assignTargets(menu)
        item.submenu = menu
        return item
    }

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
        rebuildMenu()
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
            await asrBackendPool.replace(with: new.makeBackend())
            setStatus("Engine: \(new.displayName)")
            if wasRunning, state == .idle { start() }
            rebuildMenu()
        }
    }

    @objc private func openMainWindow() {
        Task { @MainActor in SettingsWindowController.show() }
    }



    /// Picking from the menu bar only announces the choice. The notification
    /// handler is the single place that rebuilds the translator, so the menu and
    /// the Settings window cannot drift apart or do the work twice.
    @objc private func pickTranslation(_ sender: NSMenuItem) {
        guard let selection = sender.representedObject as? TranslationMenuSelection else { return }
        switch selection.scope {
        case .captions:
            guard selection.code != translateTo else { return }
            if let target = selection.code { rememberTarget(target) }
            NotificationCenter.default.post(name: .saiityTranslateTargetChanged, object: nil,
                                            userInfo: ["target": selection.code as Any])
        case .dictation:
            let state = SettingsWindowController.state
            guard selection.code != state.dictationTranslateTo else { return }
            if let target = selection.code { rememberDictationTarget(target) }
            state.dictationTranslateTo = selection.code
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
    }

    /// "What did I miss": flash the last few closed sentences in the bubble,
    /// then hand the display back to the live caption. Recognition already
    /// holds them — sessionLines is the in-memory session record whether or
    /// not saving is on — the overlay just never looked back. A new chunk
    /// arriving mid-flash simply overwrites it; live always wins.
    private var recentFlashTask: Task<Void, Never>?
    private func showRecentCaptions() {
        guard state == .running else { return }
        let recent = sessionLines.suffix(3).map(\.text)
        guard !recent.isEmpty else { return }
        recentFlashTask?.cancel()
        overlay.show(text: recent.joined(separator: "\n"), isFinal: true)
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
            if live.isEmpty {
                guard !self.lastFinalText.isEmpty else { return }
                self.overlay.show(text: self.lastFinalText, isFinal: true)
            } else {
                self.overlay.show(text: live, isFinal: self.lastVolatileText.isEmpty)
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
        clearedSentenceID = displaySentenceID
        recentFlashTask?.cancel()
        recentFlashTask = nil
        overlay.show(text: "", isFinal: true)
        overlay.showTranslation("")
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
        translatorIdleEviction.cancel()
        showedAnyCaption = false
        overlay.reservesTranslationRow =
            translateTo != nil && CaptionStyle.current.showTranslation
        sessionLines.removeAll()
        pendingTranslations = 0
        shownTranslationID = nil
        clearedSentenceID = nil
        pendingLiveText = nil
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
                    // Every await below is a place the user may have pressed
                    // Stop — prepare() alone can be a multi-gigabyte download.
                    // Bail before touching the microphone-equivalent, not after.
                    try Task.checkCancellation()

                    try await acquired.start { [weak self] chunk in
                        Task { @MainActor [weak self] in self?.render(chunk) }
                    }
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
                try await capture.start(
                    targetFormat: fmt,
                    // Capture the backend we are starting WITH, rather than
                    // reading self.backend on each buffer. This closure runs on
                    // the capture queue ~50×/s while the main actor may be
                    // reassigning that property during an engine swap — an
                    // unsynchronised read/write of a class reference. Binding it
                    // once also guarantees the audio goes to the engine the
                    // stream was configured for.
                    onBuffer: { [captureSink] buf in captureSink.feed(buf) },
                    onState: { audio in
                        Task { @MainActor [self] in self.captureStateChanged(audio) }
                    })
                // Commit on a pause, which is what makes a finished sentence
                // translate when the speaker stops rather than when a 3.5 s
                // budget runs out.
                capture.onSpeechGap = { [weak self] in
                    Task { @MainActor in await self?.commitAtSpeechGap() }
                }

                if saveTranscript { await beginRecording() }
                state = .running
                setStatus("Listening · \(Self.coverageNote())")
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
                overlay.show(text: String(localized: "listening…"), isFinal: false)
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
    @MainActor
    /// Commit whatever is pending because the speaker paused.
    ///
    /// Delayed deliberately. The recogniser decodes in 2240 ms chunks, so at the
    /// instant a gap is detected the words leading up to it may not have been
    /// decoded yet — flushing immediately would push the end of the sentence
    /// into the NEXT line. Waiting a beat lets the trailing chunk land first.
    private func commitAtSpeechGap() async {
        guard state == .running else { return }
        try? await Task.sleep(nanoseconds: 350_000_000)
        guard state == .running else { return }
        guard let backend = captionBackend else { return }
        await backend.flushPending()
        // flushPending emits the tail through the same callback as every other
        // chunk, and that callback hops to the main actor — so the tail is still
        // in flight right here. Closing now strands it: measured, the final
        // "wird" of a sentence became the whole of the next one, alone on
        // screen. Let it land first.
        try? await Task.sleep(nanoseconds: 80_000_000)
        guard state == .running else { return }

        // A pause after a comma is a breath, not the end of a thought. Closing
        // on it split "Untertitel für alles, was der Mac abspielt, direkt auf
        // dem Gerät." into three, each translated without the others. If the
        // text so far ends mid-clause, give the speaker a moment to carry on;
        // if more arrives, the gap that follows *it* will do the closing.
        if let last = lastFinalText.last, Self.clauseContinuations.contains(last) {
            let partsBefore = sentenceParts.count
            try? await Task.sleep(nanoseconds: 700_000_000)
            guard state == .running else { return }
            guard sentenceParts.count == partsBefore else { return }
        }

        // The pause IS the end of the sentence. That matters most for the
        // multilingual model, which frequently emits no punctuation at all —
        // without this its sentences would only ever be closed by the length
        // cap, in the middle of a word.
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
            setStatus("\(engine.displayName) recognises English only — this sounds like \(name)")
            overlay.show(text: String(localized: "\(engine.displayName) only recognises English. This sounds like \(name) — switch engine in Settings → Captions."),
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
        let text = chunk.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        // After committing a sentence the engine often emits a lone "." as the
        // start of the next one; showing that would blank the bar to a dot.
        guard text.rangeOfCharacter(from: .alphanumerics) != nil else { return }
        if TestHooks.verboseLogging {
            NSLog("sAiity chunk final=\(chunk.isFinal): \(text)")
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
        if sentenceClosed, sentenceParts.isEmpty {
            sentenceClosed = false
            displaySentenceID += 1
            // A new sentence is the natural end of a manual clear.
            if let cleared = clearedSentenceID, cleared < displaySentenceID {
                clearedSentenceID = nil
            }
            if let shown = shownTranslationID, displaySentenceID - shown >= 2 {
                overlay.showTranslation("")
                shownTranslationID = nil
            } else {
                overlay.markTranslationStale()
            }
        }

        // The user cleared this sentence off the screen. Keep tracking it —
        // the transcript still gets it — but do not paint it back.
        let suppressed = clearedSentenceID == displaySentenceID

        guard chunk.isFinal else {
            // Still being revised: show it after the part of the sentence that
            // has already settled, so the line reads forward instead of being
            // replaced by its own tail.
            lastVolatileText = text
            if !suppressed {
                overlay.show(text: Self.trimmedForDisplay(sentenceParts + [text]), isFinal: false)
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
            overlay.show(text: Self.trimmedForDisplay(sentenceParts), isFinal: true)
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
            kickLiveTranslation(of: lastFinalText, sentenceID: displaySentenceID)
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
        // translation from emitSentence owns the row. displaySentenceID does
        // not bump until the NEXT sentence renders, so the ID check alone
        // leaves a window where a stale partial still passes.
        guard sentenceID == displaySentenceID, !sentenceClosed,
              clearedSentenceID != sentenceID,
              translateTo != nil, translatorReady,
              CaptionStyle.current.showTranslation else { return }
        // The close path skips lines already in the target language; making
        // the same call about the same text here keeps live mode from filling
        // the row with an LLM's paraphrase of a line the close path then
        // deliberately refuses to translate — which would stand for two
        // sentences with nothing to correct it.
        if alreadyInTargetLanguage(text) { return }
        if liveTranslationBusy {
            pendingLiveText = (text, sentenceID)
            return
        }
        liveTranslationBusy = true
        let srcCode = detectedLanguage ?? locale.identifier(.bcp47)
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
            guard let target = translateTo, let engine = activeTranslator else { return }
            guard let out = await engine.translate(text, from: srcCode, to: target),
                  !out.isEmpty else { return }
            // Same guards as the authoritative path: not across a session
            // boundary, and only under the sentence it translates. The
            // `!sentenceClosed` leg drops a partial that resolves after the
            // sentence closed — it would race the authoritative translation
            // behind the translator's serial lock, and landing second it
            // rewrote the settled row with an older, shorter text.
            guard sessionGeneration == generation,
                  displaySentenceID == sentenceID, !sentenceClosed,
                  CaptionStyle.current.showTranslation else { return }
            if TestHooks.verboseLogging {
                NSLog("sAiity live translated: \(out)")
            }
            overlay.showTranslation(out)
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
        sentenceClosed = true
        // A live partial queued behind the busy slot is now superseded: the
        // close translates the full sentence anyway, so re-kicking the queued
        // partial would translate the same words twice and race the result.
        pendingLiveText = nil
        // Sentence-final is the natural throttle: volatile revisions would
        // queue faster than VoiceOver speech or a braille display can render.
        if UserDefaults.standard.bool(forKey: "announceCaptions") {
            announce(text)
        }
        emitSentence(text, chunk: chunk, sentenceID: displaySentenceID)
    }

    /// True when the line already reads as the target language. Shared by the
    /// close path and live mode so both make the same call about the same
    /// text. Under 12 characters detection is noise ("Ja." reads as Finnish),
    /// so short lines never skip.
    private func alreadyInTargetLanguage(_ text: String) -> Bool {
        guard text.count >= 12,
              let want = translateTo?.split(separator: "-").first else { return false }
        let r = NLLanguageRecognizer()
        r.processString(text)
        guard let lang = r.dominantLanguage?.rawValue.split(separator: "-").first
        else { return false }
        return lang == want
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
        sessionLines.append(Segment(i: idx, t0: chunk.start, t1: chunk.end,
                                    text: text, loc: locale.identifier(.bcp47),
                                    tr: nil, trLoc: nil,
                                    words: chunk.words.isEmpty ? nil : chunk.words,
                                    turn: turn ? true : nil))

        // Translate concurrently; the result is patched in by index.
        let srcCode = detectedLanguage ?? locale.identifier(.bcp47)
        let translation: Task<String?, Never> = Task { @MainActor in
            guard translating else { return nil }
            defer {
                self.pendingTranslations -= 1
                self.scheduleTranslatorEvictionIfIdle()
            }
            guard let target, let engine = activeTranslator else { return nil }
            // Empty counts as nothing translated. MADLAD returns "" for a short
            // or noisy caption — it has no emptiness check, unlike the LLM path's
            // sanitizer — and an empty string is non-nil, so it would otherwise
            // record a translation that is not there.
            guard let out = await engine.translate(text, from: srcCode, to: target),
                  !out.isEmpty else { return nil }
            if TestHooks.verboseLogging {
                NSLog("sAiity translated [\(TranslationEngine.effective.rawValue)]: \(out)")
            }
            // Guard the generation: Stop clears sessionLines, and a translation
            // resolving across that boundary would patch a line of the NEXT
            // session that happens to share the index.
            if self.sessionGeneration == generation, idx < self.sessionLines.count {
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
            if CaptionStyle.current.showTranslation, self.clearedSentenceID != sentenceID {
                let behind = self.displaySentenceID - sentenceID
                if behind <= 0 {
                    self.overlay.showTranslation(out)
                    self.shownTranslationID = sentenceID
                } else if behind == 1 {
                    self.overlay.showTranslation(out, stale: true)
                    self.shownTranslationID = sentenceID
                }
            }
            return out
        }

        // The on-disk store is append-only, so ORDER at the write is what makes
        // exports correct. Chain the writes: each link awaits the previous one,
        // then its own translation — lines land in claim order however long any
        // individual translation takes, and each still hits disk as soon as it
        // can, preserving the crash-safety of line-at-a-time appends.
        transcriptWriteChain = Task { @MainActor [previous = transcriptWriteChain] in
            await previous?.value
            let tr = await translation.value
            if await TranscriptStore.shared.isRecording {
                // Same rule on disk: the target is recorded only when there is a
                // translation to attach it to. This path never saw `translating`
                // at all, so it was the one that always claimed one.
                await TranscriptStore.shared.append(chunk, locale: self.locale.identifier(.bcp47),
                                                    translation: tr,
                                                    translateTo: tr == nil ? nil : target,
                                                    turn: turn)
                self.recordedLines += 1
            }
        }
    }
}
