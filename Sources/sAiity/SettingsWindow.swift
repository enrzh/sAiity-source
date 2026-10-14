import AppKit
import Foundation
import ServiceManagement
import SwiftUI

#if canImport(FoundationModels)
import FoundationModels
#endif

extension Notification.Name {
    static let saiitySaveTranscriptChanged = Notification.Name("sAiitySaveTranscriptChanged")
    static let saiityEngineChanged = Notification.Name("sAiityEngineChanged")
    static let saiityTranslateTargetChanged = Notification.Name("sAiityTranslateTargetChanged")
    static let saiityResetBubble = Notification.Name("sAiityResetBubble")
    /// "Include my microphone" changed; a running capture must act on it now.
    static let saiityMicSettingChanged = Notification.Name("sAiityMicSettingChanged")
    static let saiityDictationSettingChanged = Notification.Name("sAiityDictationSettingChanged")
    static let saiityDictationShortcutRecordingChanged = Notification.Name("sAiityDictationShortcutRecordingChanged")
    static let saiitySelectSettingsPane = Notification.Name("sAiitySelectSettingsPane")
    static let saiityToggleSettingsSidebar = Notification.Name("sAiityToggleSettingsSidebar")
    /// Start or stop captioning, from anywhere.
    ///
    /// Posted by the Captions pane primary action so it reaches the same
    /// toggle() the hot key and the menu bar item use, rather than a second
    /// code path that could quietly drift from the one the hot key drives.
    static let saiityToggleCaptions = Notification.Name("saiityToggleCaptions")
    static let saiityCaptionTranslationTimingChanged = Notification.Name("saiityCaptionTranslationTimingChanged")
}

// MARK: - Model

@MainActor
@Observable
final class AppState {

    var sessions: [SessionRef] = []
    var transcriptToOpen: SessionRef?
    var transcriptSegmentToReveal: Int?

    func openTranscript(_ session: SessionRef, revealing segment: Int? = nil) {
        transcriptSegmentToReveal = segment
        transcriptToOpen = session
    }

    var recentDictations: [RecentDictationResult] = []
    var showsRecentDictations = false
    var dictationUsesOriginalText = false
    @ObservationIgnored @Defaults("keepRecentDictations") private var recentDictationsPreference = false
    var keepRecentDictations: Bool {
        get { access(keyPath: \.keepRecentDictations); return recentDictationsPreference }
        set {
            withMutation(keyPath: \.keepRecentDictations) { recentDictationsPreference = newValue }
            if !newValue { recentDictations.removeAll() }
        }
    }
    @ObservationIgnored @Defaults("originalTextApplications") private var applicationPreference: [String] = []
    var originalTextApplications: [String] {
        get { access(keyPath: \.originalTextApplications); return applicationPreference }
        set { withMutation(keyPath: \.originalTextApplications) { applicationPreference = Array(Set(newValue)).sorted() } }
    }

    /// Routed through AppDelegate rather than written directly: enabling
    /// recording has to raise the one-time notice and, if a session is already
    /// running, actually start writing. Two code paths setting this flag meant
    /// the window silently skipped both.
    var saveTranscript = UserDefaults.standard.bool(forKey: "saveTranscript") {
        didSet {
            guard saveTranscript != oldValue else { return }
            NotificationCenter.default.post(name: .saiitySaveTranscriptChanged,
                                            object: nil, userInfo: ["on": saveTranscript])
        }
    }
    // Wrappers are ignored by @Observable; the public accessors still report
    // reads/mutations so bindings invalidate just like the other settings.
    @ObservationIgnored @Defaults("captionClickThrough") private var clickThroughPreference = false
    var captionClickThrough: Bool {
        get { access(keyPath: \.captionClickThrough); return clickThroughPreference }
        set { withMutation(keyPath: \.captionClickThrough) { clickThroughPreference = newValue } }
    }
    /// Speak each finished sentence through VoiceOver. Read per sentence by
    /// the caption pipeline, so no notification is needed.
    @ObservationIgnored @Defaults("announceCaptions") private var announcementPreference = false
    var announceCaptions: Bool {
        get { access(keyPath: \.announceCaptions); return announcementPreference }
        set { withMutation(keyPath: \.announceCaptions) { announcementPreference = newValue } }
    }

    var launchAtLogin = false
    var launchAtLoginNote = ""

    /// Optional so a fresh install can show no engine selected at all, rather
    /// than painting one segment of the picker and leaving the label underneath
    /// to admit it is not downloaded.
    var engine: ASREngine? = ASREngine.selected {
        didSet {
            guard engine != oldValue else { return }
            ASREngine.selected = engine
            enforceSettingsHonesty()
            guard let engine else { return }
            NotificationCenter.default.post(name: .saiityEngineChanged, object: nil,
                                            userInfo: ["engine": engine.rawValue,
                                                       "chunkMs": nemotronTier])
        }
    }

    /// Nemotron's latency tier. A tier is a separate model, so changing it goes
    /// through the same engine-changed path as changing the engine — the
    /// running backend has to be rebuilt either way.
    var nemotronTier = NemotronEngine.selectedChunkMs {
        didSet {
            guard nemotronTier != oldValue else { return }
            NemotronEngine.selectedChunkMs = nemotronTier
            guard let engine else { return }
            NotificationCenter.default.post(name: .saiityEngineChanged, object: nil,
                                            userInfo: ["engine": engine.rawValue,
                                                       "chunkMs": nemotronTier])
        }
    }

    /// Dictation's Nemotron tier, stored apart from the caption tier.
    ///
    /// Sharing one key was the bug: this property's setter is the engine-changed
    /// path, so choosing a dictation profile posted `saiityEngineChanged` and
    /// rebuilt the caption backend — press-to-talk silently restarting a live
    /// caption session, and a "Balanced" caption preference overwritten by a
    /// "Fast" dictation choice. A dictation change now refreshes dictation's
    /// runtime and nothing else.
    var dictationNemotronTier = NemotronEngine.dictationSelectedChunkMs {
        didSet {
            guard dictationNemotronTier != oldValue else { return }
            NemotronEngine.dictationSelectedChunkMs = dictationNemotronTier
            NotificationCenter.default.post(name: .saiityDictationSettingChanged,
                                            object: nil,
                                            userInfo: ["refreshRuntime": true])
        }
    }

    /// Languages to offer when translating an already-recorded transcript:
    /// the current target first, then recently used ones, then what this Mac
    /// is set up for. Same sources the menu bar draws on, so the two agree.
    private func recentTargets(current: String?, defaultsKey: String) -> [String] {
        var out: [String] = []
        func add(_ c: String?) {
            guard let c, !c.isEmpty, !out.contains(c) else { return }
            out.append(c)
        }
        add(current)
        (UserDefaults.standard.stringArray(forKey: defaultsKey) ?? []).forEach(add)
        Locale.preferredLanguages.prefix(4).forEach {
            add(Locale(identifier: $0).language.languageCode?.identifier)
        }
        ["en", "de"].forEach(add)
        return Array(out.prefix(8))
    }

    var recentTargetsForMenu: [String] {
        recentTargets(current: translateTo, defaultsKey: "recentTranslateTargets")
    }

    var recentDictationTargetsForMenu: [String] {
        recentTargets(current: dictationTranslateTo,
                      defaultsKey: "recentDictationTranslateTargets")
    }

    /// Every downloadable asset with its live disk state, from one registry.
    var assets: [AssetStatus] = []
    /// Inventory and transcript discovery can touch a multi-gigabyte model root.
    /// Keep that work off the main actor and let pages show their structure while
    /// the first snapshot arrives.
    var isModelsLoading = false
    var isLibraryLoading = false
    var isRefreshing = false
    /// Whether a caption session is running right now.
    ///
    /// Written by the app delegate at every session-state transition. It exists so
    /// Settings → Captions can offer the app's one primary action with an honest
    /// label: that pane configures captioning but, until this existed, had no way
    /// to start it, so the only way in was learning the ⌥⌘C chord or finding the
    /// menu bar. Mirrors what the menu bar item says, from the same state.
    var isCaptioning = false
    @ObservationIgnored private var modelsLoaded = false
    @ObservationIgnored private var libraryLoaded = false
    @ObservationIgnored private var modelRefreshGeneration = 0
    @ObservationIgnored private var libraryRefreshGeneration = 0
    @ObservationIgnored private var modelRefreshTask: Task<ModelInventory, Never>?
    @ObservationIgnored private var libraryRefreshTask: Task<[SessionRef], Never>?
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    /// Assets whose files are present but refused to load, by id → reason.
    /// Fed by LoadHealth; the observer keeps an open Models page truthful when
    /// a session fails in the background.
    var loadFailures: [String: String] = LoadHealth.all
    func needsModelRepair(_ status: AssetStatus) -> Bool {
        !status.isInstalled || loadFailures[status.id] != nil
    }
    @ObservationIgnored private var loadHealthObserver: NSObjectProtocol?

    @ObservationIgnored private var gapObserver: NSObjectProtocol?
    @ObservationIgnored private var targetObserver: NSObjectProtocol?
    @ObservationIgnored private var transcriptObserver: NSObjectProtocol?

    init() {
        // Speaker identification was removed from the product. Drop its old
        // preference so a stale value cannot look like an active hidden mode;
        // downloaded weights and old transcript files are left untouched.
        UserDefaults.standard.removeObject(forKey: "speakerLabelsEnabled")
        loadHealthObserver = NotificationCenter.default.addObserver(
            forName: LoadHealth.changed, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in self?.loadFailures = LoadHealth.all }
        }
        // The menu bar writes the same translate-target preference while the
        // Settings window is open, so follow it live rather than only on
        // reopen. Owned here, not by a root view — the toolbar-tabbed window
        // has no single SwiftUI root to hang an onReceive on.
        targetObserver = NotificationCenter.default.addObserver(
            forName: .saiityTranslateTargetChanged, object: nil,
            queue: .main) { [weak self] note in
            let t = note.userInfo?["target"] as? String
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.adoptTarget(t)
                Task { await self.refreshTargetSupport() }
            }
        }
        transcriptObserver = NotificationCenter.default.addObserver(
            forName: .saiityTranscriptLibraryChanged, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.refreshLibraryAsync(force: true)
            }
        }
        gapObserver = NotificationCenter.default.addObserver(
            forName: SystemAudioCapture.gapDiagnostics, object: nil,
            queue: .main) { [weak self] note in
            let floor = note.userInfo?["floor"] as? Float
            let threshold = note.userInfo?["threshold"] as? Float
            let fires = note.userInfo?["fires"] as? Int ?? 0
            Task { @MainActor [weak self] in
                guard let floor, let threshold else {
                    self?.gapReadout = nil
                    return
                }
                // Digital silence is RMS 0; clamp so the dB stays displayable.
                self?.gapReadout = GapReadout(
                    floorDb: Double(20 * log10(max(floor, 1e-8))),
                    thresholdDb: Double(20 * log10(max(threshold, 1e-8))),
                    fires: fires)
            }
        }
        enforceSettingsHonesty()
    }
    var ownedTotal: String = "—"
    /// Measured with the same inventory pass as `ownedTotal`, so the storage
    /// button does not rescan the model tree on every SwiftUI update.
    var ownedBytes: Int64 = 0
    /// Incomplete files from retired engines, kept out of the visible model
    /// catalogue but included in the safe interrupted-download cleanup.
    var retiredPartialBytes: Int64 = 0
    /// Bytes under our models root that belong to no known asset.
    var strayTotal: String?
    /// The single in-flight download started by this settings state, by
    /// `ModelAsset.id`. Engine preparation also uses the shared coordinator;
    /// destructive actions re-check that coordinator before touching files.
    var activeDownload: String?
    var hasActiveDownloads: Bool { activeDownload != nil }
    var downloadProgress: DownloadProgress?
    var modelError: String?
    var translationEngine: TranslationEngine? = TranslationEngine.visibleSelection(TranslationEngine.selected) {
        didSet {
            guard translationEngine != oldValue else { return }
            TranslationEngine.selected = translationEngine
            // Whisper replaces recognition, so switching to or from it changes
            // which ASR backend runs.
            NotificationCenter.default.post(name: .saiityTranslateTargetChanged, object: nil,
                                            userInfo: ["target": translateTo as Any])
        }
    }
    var shortcutError: String?

    /// Live previews must be invalidated immediately when timing changes.
    var translationTiming = TranslationTiming.current {
        didSet {
            guard translationTiming != oldValue else { return }
            TranslationTiming.current = translationTiming
            NotificationCenter.default.post(name: .saiityCaptionTranslationTimingChanged, object: nil)
        }
    }

    @ObservationIgnored @Defaults(CaptionSpeakerTracker.preferenceKey) private var speakerPreference = false
    var identifyCaptionSpeakers: Bool {
        get { access(keyPath: \.identifyCaptionSpeakers); return speakerPreference }
        set { withMutation(keyPath: \.identifyCaptionSpeakers) { speakerPreference = newValue } }
    }

    /// Capture scope: one app's audio, or nil for the whole mix. Applies when
    /// captions next start.
    var captureApp: String? = CaptureScope.appBundleID {
        didSet {
            guard captureApp != oldValue else { return }
            CaptureScope.appBundleID = captureApp
        }
    }

    /// Mix the microphone into recognition — the one deliberate exception to
    /// "the microphone is never opened". Opt-in, loudly labelled, and the
    /// permission prompt only ever appears after this is switched on.
    var includeMic = MicMix.enabled {
        didSet {
            guard includeMic != oldValue else { return }
            MicMix.enabled = includeMic
            // Live, not at the next start. Switching this off must release the
            // microphone immediately — leaving the input open after the user
            // said stop is the one thing this app cannot be seen doing.
            NotificationCenter.default.post(name: .saiityMicSettingChanged, object: nil)
        }
    }

    /// Press-to-talk is separate from live captions, and starts off on a fresh
    /// install.
    ///
    /// The event tap is live from launch whenever this is on, which means an
    /// always-listening global shortcut and a microphone the app can open at any
    /// moment. That is a decision to make, not a default to inherit.
    ///
    /// Migration, which this got wrong first. Reading
    /// `object(forKey:) as? Bool ?? false` looks safe — a stored `true` stays on
    /// — but "no stored value" is not one case, it is two. In 2.5.5 dictation was
    /// **on by default**, so a user who accepted that default never wrote a
    /// preference at all, and the key is absent for them. They are exactly the
    /// "never set" branch, so upgrading would have switched their hotkey off
    /// with nothing on screen to say why. Meanwhile a genuine fresh install
    /// also has no value, and for that one off is the right answer.
    ///
    /// `Onboarding.hasLaunchedBefore` separates them: the onboarding version is
    /// written both by finishing and by dismissing, so any install that has run
    /// before has it and a new one does not.
    var dictationEnabled = AppState.resolveDictationEnabled() {
        didSet {
            guard dictationEnabled != oldValue else { return }
            UserDefaults.standard.set(dictationEnabled, forKey: "dictationEnabled")
            NotificationCenter.default.post(name: .saiityDictationSettingChanged, object: nil)
        }
    }
    private static let dictationEnabledKey = "dictationEnabled"

    /// Decide press-to-talk once, and write the decision down.
    ///
    /// Writing it back matters as much as choosing it: the `didSet` on
    /// `dictationEnabled` only writes when the value *changes*, so an install
    /// that resolves to the same value it loaded would never persist anything and
    /// the next release would face the identical ambiguity. After this runs
    /// once, the key is always present and always means what it says.
    ///
    /// `nonisolated` because it is preference-store arithmetic with no UI in it,
    /// and because a migration is exactly the sort of thing that must be
    /// testable without an actor hop.
    nonisolated static func resolveDictationEnabled() -> Bool {
        let defaults = UserDefaults.standard
        if let stored = defaults.object(forKey: dictationEnabledKey) as? Bool {
            return stored
        }
        // 2.5.5 shipped this on by default, so an install that has run before
        // almost certainly means it and must keep it. A fresh install has not
        // decided, and off is the right answer for a global microphone shortcut
        // that is live from launch.
        let resolved = Onboarding.hasLaunchedBefore
        defaults.set(resolved, forKey: dictationEnabledKey)
        return resolved
    }

    var dictationRecognizer: DictationRecognizer = DictationRecognizer.selected {
        didSet {
            guard dictationRecognizer != oldValue else { return }
            DictationRecognizer.selected = dictationRecognizer
            NotificationCenter.default.post(name: .saiityDictationSettingChanged, object: nil)
        }
    }

    /// Dictation's streaming recognizer, which has always been able to hold a
    /// model of its own — `dictationStreamingEngine` predates the caption picker —
    /// but had no control anywhere in the window. The detail section only printed
    /// the value, so the key was writable from defaults and unwritable from
    /// Settings: every install stayed on whatever it first resolved to.
    ///
    /// Optional for the same reason `engine` is: nil is a real state to show,
    /// not a value to invent. The setter normalizes through
    /// `ASREngine.dictationSelected`, which drops a retired or unselectable
    /// choice rather than letting an old preference come back.
    var dictationEngine: ASREngine? = ASREngine.dictationSelected {
        didSet {
            guard dictationEngine != oldValue else { return }
            ASREngine.dictationSelected = dictationEngine
            // refreshRuntime, not the bare post the recognizer uses: the
            // backend reads `dictationEffective` when it is built, so a model
            // change that only updated UserDefaults would leave the running
            // pool on the old model until something else rebuilt it.
            NotificationCenter.default.post(name: .saiityDictationSettingChanged,
                                            object: nil,
                                            userInfo: ["refreshRuntime": true])
        }
    }

    /// The profile is inferred from the real controls. A manual tweak becomes
    /// Custom immediately instead of leaving a stale preset badge behind.
    var dictationProfile: DictationProfile {
        get {
            let streaming = ASREngine.dictationEffective
            if dictationRecognizer == .whisper,
               WhisperDictationBackend.locale == "auto",
               dictationCleanupEnabled { return .accurate }
            if dictationRecognizer == .streaming,
               streaming == .nemotron,
               dictationNemotronTier == 1120,
               !dictationCleanupEnabled { return .fast }
            if dictationRecognizer == .streaming,
               streaming == .nemotron,
               dictationNemotronTier == NemotronEngine.chunkMs,
               dictationCleanupEnabled { return .balanced }
            return .custom
        }
        set {
            guard newValue != .custom else { return }
            // The streaming model goes through `dictationEngine`, never
            // straight to UserDefaults: that key is what the picker reads, so
            // writing it behind the observable left the control showing the
            // model the user had just moved away from.
            switch newValue {
            case .fast:
                dictationRecognizer = .streaming
                dictationEngine = ASREngine.nemotron
                dictationNemotronTier = 1120
                dictationCleanupEnabled = false
            case .balanced:
                dictationRecognizer = .streaming
                dictationEngine = ASREngine.nemotron
                dictationNemotronTier = NemotronEngine.chunkMs
                dictationCleanupEnabled = true
            case .accurate:
                dictationRecognizer = .whisper
                WhisperDictationBackend.locale = "auto"
                dictationCleanupEnabled = true
            case .custom:
                break
            }
            NotificationCenter.default.post(name: .saiityDictationSettingChanged,
                                            object: nil,
                                            userInfo: ["refreshRuntime": true])
        }
    }
    /// Optional dedicated engine for press-to-talk translation. When unset,
    /// dictation follows the existing Captions engine for compatibility.
    var dictationTranslationEngine: TranslationEngine? = TranslationEngine.visibleSelection(TranslationEngine.dictationSelected) {
        didSet {
            guard dictationTranslationEngine != oldValue else { return }
            TranslationEngine.dictationSelected = dictationTranslationEngine
            NotificationCenter.default.post(name: .saiityDictationSettingChanged, object: nil)
        }
    }
    var dictationCleanupEnabled = UserDefaults.standard.object(forKey: "dictationCleanupEnabled") as? Bool ?? true {
        didSet {
            enforceSettingsHonesty()
            guard dictationCleanupEnabled != oldValue else { return }
            UserDefaults.standard.set(dictationCleanupEnabled, forKey: "dictationCleanupEnabled")
            NotificationCenter.default.post(name: .saiityDictationSettingChanged, object: nil)
        }
    }
    /// Show the dictated words while they are still being spoken, and let the
    /// finished text take their place when the result lands.
    ///
    /// A display preference with a real cost. Drafts were gated behind the
    /// Fast profile because a live draft means the streaming backend runs
    /// *during* the utterance instead of being deferred to the stop, and Fast
    /// is the profile that turns cleanup and translation off — the two cases
    /// where the raw words are not the answer, so showing them was worse than
    /// showing nothing. Asking for this explicitly inverts that judgement: the
    /// point is to watch the raw text arrive and then watch the finished text
    /// replace it.
    var dictationRealtimeText = UserDefaults.standard.bool(forKey: "dictationRealtimeText") {
        didSet {
            guard dictationRealtimeText != oldValue else { return }
            UserDefaults.standard.set(dictationRealtimeText, forKey: "dictationRealtimeText")
            NotificationCenter.default.post(name: .saiityDictationSettingChanged, object: nil)
        }
    }
    var dictationChord = DictationChord.current {
        didSet {
            guard dictationChord != oldValue else { return }
            DictationChord.current = dictationChord
            NotificationCenter.default.post(name: .saiityDictationSettingChanged, object: nil)
        }
    }
    /// Translate the final dictation with the shared local engine and its own
    /// target. Off by default because it adds a model step and latency.
    var translateDictation = UserDefaults.standard.bool(forKey: "translateDictation") {
        didSet {
            enforceSettingsHonesty()
            guard translateDictation != oldValue else { return }
            UserDefaults.standard.set(translateDictation, forKey: "translateDictation")
            NotificationCenter.default.post(name: .saiityDictationSettingChanged, object: nil)
        }
    }
    /// Independent from captions after the one-time migration on first launch.
    /// A nil value is a real persisted Off state, not a signal to follow captions.
    var dictationTranslateTo: String? = DictationTargetPreference.load() {
        didSet {
            guard dictationTranslateTo != oldValue else { return }
            DictationTargetPreference.save(dictationTranslateTo)
            enforceSettingsHonesty()
            NotificationCenter.default.post(name: .saiityDictationSettingChanged, object: nil)
        }
    }
    struct RunningApp: Sendable {
        let bundleID: String
        let name: String
    }
    var runningApps: [RunningApp] = []

    /// Live speech-gap readout while a session runs, cleared when it stops.
    struct GapReadout {
        var floorDb: Double
        var thresholdDb: Double
        var fires: Int
    }
    var gapReadout: GapReadout?

    /// Whether a pause in speech ends a sentence, and how long a pause has to
    /// be. Mirrored here so the controls are bindings; the notification is what
    /// makes a running capture pick the change up.
    var speechGapEnabled = SpeechGap.enabled {
        didSet {
            guard speechGapEnabled != oldValue else { return }
            SpeechGap.enabled = speechGapEnabled
            NotificationCenter.default.post(name: .saiitySpeechGapChanged, object: nil)
        }
    }
    var speechGapHoldMs = Double(SpeechGap.holdMs) {
        didSet {
            guard Int(speechGapHoldMs) != SpeechGap.holdMs else { return }
            SpeechGap.holdMs = Int(speechGapHoldMs)
            NotificationCenter.default.post(name: .saiitySpeechGapChanged, object: nil)
        }
    }

    /// Caption and dictation bubbles keep separate persisted appearances, even
    /// though they share the same rendering surface.
    var style: CaptionStyle = CaptionStyle.current {
        didSet {
            enforceSettingsHonesty()
            CaptionStyle.current = style
        }
    }
    var dictationStyle: CaptionStyle = CaptionStyle.currentDictation {
        didSet { CaptionStyle.currentDictation = dictationStyle }
    }

    private func applyModelInventory(_ inventory: ModelInventory) {
        assets = inventory.assets
        loadFailures = LoadHealth.all
        let total = inventory.ownedBytes
        ownedBytes = total
        retiredPartialBytes = inventory.retiredPartialBytes
        ownedTotal = total > 0 ? ModelRegistry.format(total) : String(localized: "nothing downloaded")
        let stray = inventory.strayBytes
        // Only worth mentioning once it is a real amount; a few KB of cache
        // metadata is noise.
        strayTotal = stray > 8 << 20 ? ModelRegistry.format(stray) : nil
        modelsLoaded = true
        isModelsLoading = false
        enforceSettingsHonesty()
    }

    /// Synchronous compatibility hook for small post-mutation refreshes. New
    /// page presentation should use `refreshModelsAsync()` so the first open
    /// never blocks the main actor on a large model tree.
    func refreshModels() {
        applyModelInventory(ModelRegistry.inventorySnapshot())
    }

    func refreshModelsAsync(force: Bool = false) async {
        if modelsLoaded && !force { return }
        if !force, let task = modelRefreshTask {
            let generation = modelRefreshGeneration
            let inventory = await task.value
            guard generation == modelRefreshGeneration, !Task.isCancelled else { return }
            applyModelInventory(inventory)
            return
        }

        modelRefreshGeneration &+= 1
        let generation = modelRefreshGeneration
        isModelsLoading = true
        let task = Task.detached(priority: .userInitiated) {
            ModelRegistry.inventorySnapshot()
        }
        modelRefreshTask = task
        let inventory = await task.value
        guard generation == modelRefreshGeneration else { return }
        guard !Task.isCancelled else {
            modelRefreshTask = nil
            isModelsLoading = false
            return
        }
        modelRefreshTask = nil
        applyModelInventory(inventory)
    }

    func refreshLibraryAsync(force: Bool = false) async {
        if libraryLoaded && !force { return }
        if !force, let task = libraryRefreshTask {
            let generation = libraryRefreshGeneration
            let loadedSessions = await task.value
            guard generation == libraryRefreshGeneration, !Task.isCancelled else { return }
            sessions = loadedSessions
            libraryLoaded = true
            isLibraryLoading = false
            return
        }

        libraryRefreshGeneration &+= 1
        let generation = libraryRefreshGeneration
        isLibraryLoading = true
        let library = TranscriptStore.sessionsDir
        let task = Task.detached(priority: .userInitiated) {
            TranscriptStore.list(in: library)
        }
        libraryRefreshTask = task
        let loadedSessions = await task.value
        guard generation == libraryRefreshGeneration else { return }
        guard !Task.isCancelled else {
            libraryRefreshTask = nil
            isLibraryLoading = false
            return
        }
        libraryRefreshTask = nil
        sessions = loadedSessions
        libraryLoaded = true
        isLibraryLoading = false
    }

    /// Re-reads the three settings that can claim work this Mac cannot do.
    /// Writes the corrected values directly because `didSet` does not run for
    /// assignments made while `AppState` is still initializing.
    @ObservationIgnored private var enforcingHonesty = false

    func enforceSettingsHonesty() {
        guard !enforcingHonesty else { return }
        enforcingHonesty = true
        defer { enforcingHonesty = false }
        if translationEngine != TranslationEngine.visibleSelection(translationEngine) {
            translationEngine = nil
        }
        if dictationTranslationEngine != TranslationEngine.visibleSelection(dictationTranslationEngine) {
            dictationTranslationEngine = nil
        }
        let next = SettingsStateHonesty.reconcile(
            recognition: engine,
            recommendedRecognitionInstalled: !ASREngine.recommended.needsDownload,
            showCaptionTranslation: style.showTranslation,
            captionTarget: translateTo,
            dictationTranslationEnabled: translateDictation,
            dictationTarget: dictationTranslateTo,
            cleanupEnabled: dictationCleanupEnabled,
            cleanupReady: llmModel?.isDownloaded == true)
        if engine != next.recognition {
            engine = next.recognition
            ASREngine.selected = next.recognition
        }
        if style.showTranslation != next.showCaptionTranslation {
            var corrected = style
            corrected.showTranslation = next.showCaptionTranslation
            style = corrected
            CaptionStyle.current = corrected
        }
        if translateDictation != next.dictationTranslationEnabled {
            translateDictation = next.dictationTranslationEnabled
            UserDefaults.standard.set(next.dictationTranslationEnabled, forKey: "translateDictation")
        }
        if dictationCleanupEnabled != next.cleanupEnabled {
            dictationCleanupEnabled = next.cleanupEnabled
            UserDefaults.standard.set(next.cleanupEnabled, forKey: "dictationCleanupEnabled")
        }
    }

    /// The in-flight download, so Cancel can actually cancel it. Before this a
    /// misclick on a multi-gigabyte model had no exit short of quitting the app.
    @ObservationIgnored private var downloadTask: Task<Bool, Never>?

    /// Download one asset. Progress is whatever the underlying API can honestly
    /// report — some give bytes, some a fraction, some nothing at all.
    @discardableResult
    func download(_ asset: ModelAsset) async -> Bool {
        guard activeDownload == nil, let install = asset.install else { return false }
        if let required = asset.advertisedBytes,
           let available = ModelRegistry.availableDiskBytes(),
           available < required {
            modelError = String(localized: "Not enough free space for \(asset.title). Need about \(ModelRegistry.format(required)); only \(ModelRegistry.format(available)) is available.")
            await refreshModelsAsync(force: true)
            return false
        }
        activeDownload = asset.id
        downloadProgress = DownloadProgress(note: "Starting…")
        modelError = nil

        let id = asset.id
        let task = Task {
            do {
                // The same door the engines use, so pressing Download on a row a
                // running session is already fetching joins that transfer rather
                // than starting a second one into the same staging file.
                try await DownloadCoordinator.shared.run(id) {
                    try await install { p in
                        Task { @MainActor in self.downloadProgress = p }
                    }
                }
                // Fresh bytes supersede whatever damage was recorded against
                // the old ones. Only on success — a cancelled or failed fetch
                // changed nothing about the files the record describes.
                LoadHealth.clear(id)
                return true
            } catch is CancellationError {
                // The user pressed Cancel; not an error, so no red text.
            } catch let e as URLError where e.code == .cancelled {
                // URLSession's spelling of the same thing.
            } catch {
                self.modelError = error.localizedDescription
            }
            return false
        }
        downloadTask = task
        let installed = await task.value
        downloadTask = nil
        activeDownload = nil
        downloadProgress = nil
        await refreshModelsAsync(force: true)
        return installed
    }

    /// Delete the damaged files, then fetch fresh — the one recovery path for
    /// an asset that is present on disk but refuses to load.
    func redownload(_ asset: ModelAsset) async {
        await delete(asset)
        guard modelError == nil else { return }
        await download(asset)
    }

    /// Stop the in-flight download. Cancellation propagates through the
    /// URLSession awaits, so the transfer stops rather than running on unseen.
    func cancelDownload() {
        // Both, and in this order. Cancelling only our own await would leave the
        // shared transfer running with nobody watching it; cancelling only the
        // shared task would leave this one awaiting a task that is already gone.
        if let id = activeDownload {
            Task { await DownloadCoordinator.shared.cancel(id) }
        }
        downloadTask?.cancel()
    }

    /// Delete one asset's files.
    ///
    /// Two rules, both load-bearing. Refuse while captions are running, because
    /// silently killing a live session from another window is worse than saying
    /// no. And when idle, unload first: deleting a file the engine still has
    /// mmap'd succeeds without freeing a single block, so the app would report
    /// space reclaimed that was not.
    func delete(_ asset: ModelAsset) async {
        guard case .remove = asset.removal else { return }
        modelError = nil
        if await DownloadCoordinator.shared.activeIDs.contains(asset.id) {
            modelError = String(localized: "A download is still in progress.")
            return
        }
        // A re-translation is a live session with a multi-gigabyte translator
        // open. It is the mirror of the rule below — that one stops a session
        // from starting during a re-translation — and it was missing: the
        // Models page could unlink the weights a running re-translation was
        // decoding from, which frees nothing and then fails at the next line.
        if CaptionSession.shared.isProcessingTranscript {
            modelError = String(localized: CaptionSession.shared.transcriptWorkMessage)
            return
        }
        if CaptionSession.shared.isRunning, asset.use.isSelected {
            modelError = String(localized: "\(asset.title) is running the live captions. Stop captions first.")
            return
        }
        // Recognition can be prewarmed for dictation even when no captions
        // engine has been selected: ASREngine.effective uses the recommended
        // fallback in that state. Release all loaded recognition resources
        // before deletion so the fallback cannot keep the file mapped.
        //
        // The parentheses are load-bearing and the line is deliberately not
        // written as a bare `,`-separated list. Swift would parse the list form
        // as intended, but a reader — or a port to a language where the list
        // separator does not exist — reasonably reads it as
        // `(!running && recognition) || isSelected`, which would release a live
        // session's caption model out from under it.
        if !CaptionSession.shared.isRunning,
           (asset.family == .recognition || asset.use.isSelected) {
            await CaptionSession.shared.releaseEverything()
            // Dictation keeps its own prepared backend, which the caption pool
            // release does not own. Drop it too, or the next dictation press
            // loads a model whose files are seconds from being unlinked.
            await (NSApp.delegate as? AppDelegate)?.invalidateDictationBackend()
        }
        if !ModelRegistry.remove(asset) {
            modelError = String(localized: "Could not delete \(asset.title).")
        }
        await refreshModelsAsync(force: true)
    }

    /// Remove only interrupted download state, leaving completed models alone.
    /// For each known incomplete asset this removes its incomplete destination
    /// plus `.part` and `.part.etag`; an installed asset is never included.
    /// Returns the approximate bytes reclaimed, or nil if the operation was
    /// refused or any partial could not be removed.
    @discardableResult
    func clearInterruptedDownloads(includeRetired: Bool = true) async -> Int64? {
        modelError = nil
        let coordinatorIDs = await DownloadCoordinator.shared.activeIDs
        guard activeDownload == nil, coordinatorIDs.isEmpty else {
            modelError = String(localized: "A download is still in progress.")
            return nil
        }
        guard !CaptionSession.shared.isRunning else {
            modelError = String(localized: "Captions are running. Stop them first.")
            return nil
        }
        // Same reasoning as `delete`: a re-translation holds the translator
        // open, and the partial files it needs to fetch again are not ours to
        // clear underneath it.
        guard !CaptionSession.shared.isProcessingTranscript else {
            modelError = String(localized: CaptionSession.shared.transcriptWorkMessage)
            return nil
        }

        let partials: [AssetStatus] = assets.filter(\.isPartial)
            + (includeRetired
                ? ModelRegistry.retiredPartialAssets().map { ModelRegistry.status(of: $0) }
                : [])
        guard !partials.isEmpty else { return 0 }

        if partials.contains(where: { $0.asset.use.isSelected }) {
            guard let delegate = NSApp.delegate as? AppDelegate,
                  await delegate.prepareForModelCleanup() else {
                modelError = String(localized: "Stop captions or dictation before clearing this model's files.")
                return nil
            }
            await CaptionSession.shared.releaseEverything()
        }

        var freed: Int64 = 0
        var failed = false
        for status in partials {
            if ModelRegistry.remove(status.asset) {
                freed += status.bytesOnDisk
            } else {
                failed = true
            }
        }
        await refreshModelsAsync(force: true)
        guard !failed else {
            modelError = String(localized: "Some interrupted downloads could not be cleared.")
            return nil
        }
        return freed
    }

    /// Remove every model the app downloaded. Returns the bytes freed, or nil if
    /// it refused or failed.
    @discardableResult
    func removeAllDownloads() async -> Int64? {
        modelError = nil
        guard await DownloadCoordinator.shared.activeIDs.isEmpty else {
            modelError = String(localized: "A download is still in progress.")
            return nil
        }
        guard !CaptionSession.shared.isRunning else {
            modelError = String(localized: "Captions are running. Stop them first.")
            return nil
        }
        guard !CaptionSession.shared.isProcessingTranscript else {
            modelError = String(localized: CaptionSession.shared.transcriptWorkMessage)
            return nil
        }
        await CaptionSession.shared.releaseEverything()
        do {
            let freed = try ModelRegistry.removeAllOwned()
            await refreshModelsAsync(force: true)
            return freed
        } catch {
            modelError = error.localizedDescription
            await refreshModelsAsync(force: true)
            return nil
        }
    }


    /// Set when the change arrived FROM the notification, so echoing it back
    /// would be a loop rather than news.
    @ObservationIgnored private var applyingRemoteTarget = false

    var translateTo: String? = UserDefaults.standard.string(forKey: "translateTo") {
        didSet {
            guard translateTo != oldValue else { return }
            UserDefaults.standard.set(translateTo, forKey: "translateTo")
            enforceSettingsHonesty()
            guard !applyingRemoteTarget else { return }
            NotificationCenter.default.post(name: .saiityTranslateTargetChanged, object: nil,
                                            userInfo: ["target": translateTo as Any])
        }
    }

    /// Adopt a target chosen elsewhere — the menu bar writes the same
    /// preference, and without this the window went on showing the old one.
    func adoptTarget(_ code: String?) {
        applyingRemoteTarget = true
        translateTo = code
        applyingRemoteTarget = false
    }
    var showLocalModels = false
    /// The searchable target-language sheet. Also raised from the menu bar's
    /// "All languages…" item, which is why it lives on shared state.
    var showTranslationPicker = false
    /// Separate sheet state so a menu request for dictation can never open the
    /// captions picker with the wrong binding.
    var showDictationTranslationPicker = false

    /// Whether the selected engine can reach the selected target. Recomputed on
    /// every change to either, because a stored target outlives an engine swap.
    var targetSupportedByEngine = true

    func refreshTargetSupport() async {
        guard let t = translateTo else { targetSupportedByEngine = true; return }
        // Ask the engine that would actually run. Reporting "unsupported" when
        // nothing is chosen produced a flatly false claim — "MADLAD cannot
        // translate into English" — from an engine the user had not picked.
        let asked = translationEngine ?? .recommended
        targetSupportedByEngine = LanguageCatalog.supportedCodes(for: asked).contains(t)
    }
    var llmModel: LocalModel? = LocalModel.cleanupSelected {
        didSet {
            guard llmModel != oldValue else { return }
            enforceSettingsHonesty()
            LocalModel.cleanupSelected = llmModel
            // Writing the preference is not enough: the translator holds an LLM
            // built from the *old* file, so without this the app kept using —
            // and kept several gigabytes of — the model the user just switched
            // away from, and the new selection took effect only after a restart.
            // The same notification the engine picker posts rebuilds it.
            NotificationCenter.default.post(name: .saiityTranslateTargetChanged, object: nil,
                                            userInfo: ["target": translateTo as Any])
        }
    }

    func refresh() async {
        if let task = refreshTask {
            await task.value
            return
        }
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.performRefresh()
        }
        refreshTask = task
        await task.value
        refreshTask = nil
    }

    private func performRefresh() async {
        isRefreshing = true
        defer { isRefreshing = false }
        // Re-read selections from defaults. Without this the window shows
        // whatever was current when the AppState singleton was created, which
        // is one of the ways "selecting a model appears to do nothing".
        engine = ASREngine.selected
        translationEngine = TranslationEngine.visibleSelection(TranslationEngine.selected)
        dictationTranslationEngine = TranslationEngine.visibleSelection(TranslationEngine.dictationSelected)
        // Same gap as the caption engine: a dictation model chosen elsewhere
        // (defaults, a preset) has to be re-read or the window shows whatever
        // was current when AppState was created.
        dictationEngine = ASREngine.dictationSelected
        llmModel = LocalModel.cleanupSelected
        // Was missing, so a target picked from the menu bar never appeared here.
        adoptTarget(UserDefaults.standard.string(forKey: "translateTo"))
        await refreshTargetSupport()
        // The inventory is cached after its first pass. Model mutations call
        // `refreshModelsAsync(force: true)` explicitly, while ordinary window
        // reveals should not walk a multi-gigabyte tree again.
        await refreshModelsAsync()
        // Transcript discovery is intentionally deferred until the Transcripts
        // page is visible. Opening Captions or Models should not walk the
        // transcript directory at all.
        refreshRunningApps()
        refreshLaunchAtLogin()
    }

    /// Candidates for the capture-scope picker: ordinary windowed apps, plus
    /// the persisted choice even when that app is not running — the picker
    /// must never silently show "Everything" while capture is scoped.
    func refreshRunningApps() {
        var apps = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .filter { $0.bundleIdentifier != Bundle.main.bundleIdentifier }
            .compactMap { a in
                a.bundleIdentifier.map {
                    RunningApp(bundleID: $0, name: a.localizedName ?? $0)
                }
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        if let chosen = captureApp, !apps.contains(where: { $0.bundleID == chosen }) {
            apps.insert(RunningApp(bundleID: chosen,
                                   name: String(localized: "\(CaptureScope.displayName(for: chosen)) (not running)")),
                        at: 0)
        }
        runningApps = apps
    }

    /// `keepNote` preserves a message set by `setLaunchAtLogin` — otherwise the
    /// status refresh immediately overwrites the real error with a generic one.
    func refreshLaunchAtLogin(keepNote: Bool = false) {
        let status = SMAppService.mainApp.status
        switch status {
        case .enabled:
            launchAtLogin = true
            if !keepNote { launchAtLoginNote = "" }
        case .requiresApproval:
            launchAtLogin = true
            if !keepNote {
                launchAtLoginNote = String(localized: "Approve Syllivra in System Settings → General → Login Items.")
            }
        case .notFound, .notRegistered:
            // Both are simply "not a login item yet" — NOT a signing failure.
            // Registering flips this straight to .enabled; only a thrown error
            // means something is actually wrong.
            launchAtLogin = false
            if !keepNote { launchAtLoginNote = "" }
        default:
            launchAtLogin = false
            if !keepNote { launchAtLoginNote = "" }
        }
    }

    func setLaunchAtLogin(_ on: Bool) {
        var failure: String?
        do {
            if on { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
        } catch {
            let ns = error as NSError
            failure = "\(error.localizedDescription) [\(ns.domain) \(ns.code)]"
        }
        refreshLaunchAtLogin(keepNote: failure != nil)
        if let failure { launchAtLoginNote = failure }
        NSLog("sAiity launchAtLogin request=\(on) -> status=\(SMAppService.mainApp.status.rawValue) "
              + "error=\(failure ?? "none")")
    }

    static func openLoginItemsSettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension")!
        NSWorkspace.shared.open(url)
    }

}

// MARK: - Window

/// The window's own translucency, as the OS draws it.
///
/// This is deliberately NOT a painted background. The app used to wash its
/// windows in an accent gradient, which is the thing that made them read as a
/// web page wearing a Mac costume. `NSVisualEffectView` blending *behind the
/// window* is the real effect: it samples the desktop and windows underneath,
/// reacts to the window becoming inactive, and follows light/dark and the
/// accessibility settings without being told. The grouped form's rounded
/// section cards then float on it, which is exactly the composition System
/// Settings uses.
struct VibrantBackground: NSViewRepresentable {
    /// `.windowBackground`, not `.underWindowBackground`. The latter is the
    /// most transparent material AppKit has — measured on screen, text in the
    /// window *behind* Settings stayed readable through the gaps between the
    /// section cards, which is a legibility problem dressed up as a design.
    /// This one still tints and blurs what is behind it; it just does not
    /// compete with the settings on top of it.
    var material: NSVisualEffectView.Material = .windowBackground

    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = material
        v.blendingMode = .behindWindow
        // Not `.active`: an inactive window whose background keeps sampling
        // live content looks wrong next to every other window on the Mac.
        v.state = .followsWindowActiveState
        return v
    }

    func updateNSView(_ v: NSVisualEffectView, context: Context) {
        v.material = material
    }
}

extension NSWindow {
    /// Settings and setup use an opaque semantic base so the titlebar cannot
    /// sample a bright window behind it. The content can still use its own
    /// system materials without turning the window chrome into a see-through
    /// layer.
    func makeOpaqueSettingsSurface() {
        isOpaque = true
        backgroundColor = .windowBackgroundColor
        titlebarAppearsTransparent = false
    }
}

@MainActor
private final class SettingsToolbarTarget: NSObject, NSToolbarDelegate {
    static let sidebarIdentifier = NSToolbarItem.Identifier("sAiity.sidebar")

    @objc func toggleSidebar() {
        NotificationCenter.default.post(name: .saiityToggleSettingsSidebar, object: nil)
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [Self.sidebarIdentifier]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [Self.sidebarIdentifier]
    }

    func toolbar(_ toolbar: NSToolbar,
                 itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        guard itemIdentifier == Self.sidebarIdentifier else { return nil }
        let item = NSToolbarItem(itemIdentifier: itemIdentifier)
        let sidebarVisible = UserDefaults.standard.object(forKey: "saiity.settings.sidebarVisible") as? Bool ?? true
        let label = sidebarVisible ? String(localized: "Hide sidebar") : String(localized: "Show sidebar")
        item.label = label
        item.toolTip = label
        item.image = NSImage(systemSymbolName: "sidebar.left", accessibilityDescription: label)
        item.isNavigational = true
        item.target = self
        item.action = #selector(toggleSidebar)
        return item
    }
}

/// The settings window keeps the standard AppKit title bar and window
/// controls. The AppKit toolbar owns the sidebar action; the system owns
/// resizing, minimizing, full screen, and the traffic-light state.
final class SettingsChromeWindow: NSWindow {}

@MainActor
private final class SettingsWindowDelegate: NSObject, NSWindowDelegate {
    func windowDidExitFullScreen(_ notification: Notification) {
        SettingsWindowController.applyRequestedContentHeight()
    }
}

@MainActor
enum SettingsWindowController {
    private static var window: NSWindow?
    private static var requestedContentHeight: CGFloat?
    private static let windowDelegate = SettingsWindowDelegate()
    private static let toolbarTarget = SettingsToolbarTarget()
    static let settingsWindowIdentifier = NSUserInterfaceItemIdentifier("saiity.settings")
    /// Shared, so the menu bar can raise a specific sheet in this window.
    static let state = AppState()
    static var selectedPane: SettingsPane = .captions

    static func openTranscript(_ session: SessionRef) {
        state.openTranscript(session)
        selectedPane = .transcripts
        NotificationCenter.default.post(name: .saiitySelectSettingsPane,
                                        object: SettingsPane.transcripts.rawValue)
        show()
    }

    static func show() {
        if let w = window {
            NSApp.activate(ignoringOtherApps: true)
            w.makeKeyAndOrderFront(nil)
            if selectedPane == .library || selectedPane == .models || selectedPane == .transcripts {
                setContentHeight(600)
            } else {
                applyRequestedContentHeight()
            }
            applyChrome(to: w)
            Task { await state.refresh() }
            return
        }
        let w = SettingsChromeWindow(
            contentRect: NSRect(x: 0, y: 0, width: 860, height: 600),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false)
        w.isReleasedWhenClosed = false
        // Keep the titlebar and window controls on a stable semantic surface;
        // only the content cards should carry the visual treatment.
        w.makeOpaqueSettingsSurface()
        let host = NSHostingController(
            rootView: SettingsRootView(state: state,
                                        initialPane: selectedPane)
                .frame(minWidth: 760, minHeight: 420)
                .background(VibrantBackground()))
        host.view.wantsLayer = true
        host.view.layer?.backgroundColor = .clear
        w.contentViewController = host
        w.identifier = settingsWindowIdentifier
        w.delegate = windowDelegate
        let toolbar = NSToolbar(identifier: "sAiity.SettingsToolbar")
        toolbar.displayMode = .iconOnly
        toolbar.delegate = toolbarTarget
        toolbar.insertItem(withItemIdentifier: SettingsToolbarTarget.sidebarIdentifier, at: 0)
        w.toolbar = toolbar
        // Keep the system titlebar opaque so the window controls sit on a
        // stable surface instead of showing the settings content through it.
        w.titlebarAppearsTransparent = false
        w.toolbarStyle = .unified
        w.titleVisibility = .visible
        w.setContentSize(NSSize(width: 860, height: 600))
        w.contentMinSize = NSSize(width: 760, height: 420)
        window = w
        setContentHeight(selectedPane == .library || selectedPane == .models || selectedPane == .transcripts ? 600 : 420)
        w.center()
        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
        applyChrome(to: w)
        Task { await state.refresh() }
    }

    /// The title follows the pane on screen. The legacy Models destination
    /// maps to the Models page, and the old General destination lives inside Setup.
    static func applyChrome(to window: NSWindow? = nil) {
        guard let w = window ?? self.window else { return }
        w.title = presentedPane.windowTitle
    }

    static func updateSidebarToolbarLabel(_ sidebarVisible: Bool) {
        guard let item = window?.toolbar?.items.first(where: {
            $0.itemIdentifier == SettingsToolbarTarget.sidebarIdentifier
        }) else { return }
        let label = sidebarVisible ? String(localized: "Hide sidebar") : String(localized: "Show sidebar")
        item.label = label
        item.toolTip = label
        item.image = NSImage(systemSymbolName: "sidebar.left", accessibilityDescription: label)
    }

    /// Keep a compact page compact. Expanded settings still get the full
    /// work surface; a collapsed disclosure should not leave a dead black
    /// half-window below the primary controls.
    static func setContentHeight(_ height: CGFloat) {
        requestedContentHeight = min(max(height, 420), 600)
        applyRequestedContentHeight()
    }

    /// Apply the last requested page height once the window is back in a
    /// normal window state. Full Screen owns geometry while it is active, but
    /// it should not discard a disclosure choice made there.
    static func applyRequestedContentHeight() {
        guard let target = requestedContentHeight, let w = window else { return }
        guard !w.styleMask.contains(.fullScreen) else { return }
        let current = w.contentViewController?.view.bounds.height ?? target
        guard abs(current - target) > 1 else { return }
        let width = max(w.contentViewController?.view.bounds.width ?? 760, 760)
        w.setContentSize(NSSize(width: width, height: target))
    }

    private static var presentedPane: SettingsPane {
        switch selectedPane {
        case .models: .library
        case .general: .setup
        default: selectedPane
        }
    }

    /// Open the dictation target picker in the pane that owns it. Menu-bar
    /// commands can arrive while another settings pane is selected, so
    /// presenting the shared sheet state alone is not enough.
    static func showDictationTranslationPicker() {
        selectedPane = .dictation
        show()
        NotificationCenter.default.post(name: .saiitySelectSettingsPane,
                                        object: SettingsPane.dictation.rawValue)
        state.showDictationTranslationPicker = true
    }

    static func selectModelsPane() {
        selectedPane = .models
        show()
        NotificationCenter.default.post(name: .saiitySelectSettingsPane,
                                        object: SettingsPane.models.rawValue)
    }

    static func refreshDictationRuntime() {
        (NSApp.delegate as? AppDelegate)?.refreshDictationRuntime()
    }
}

// MARK: - Views

enum SettingsPane: String, CaseIterable, Hashable, Identifiable {
    case setup, captions, dictation, library, transcripts

    // Legacy destinations remain valid for menu notifications and older tests,
    // but are deliberately not presented as top-level navigation items.
    case models, general

    static var allCases: [SettingsPane] {
        [.setup, .captions, .dictation, .library, .transcripts]
    }

    var id: String { rawValue }
    var title: LocalizedStringKey {
        switch self {
        case .setup: "Setup"
        case .captions: "Captions"
        case .dictation: "Dictation"
        case .library: "Models"
        case .models: "Models"
        case .transcripts: "Transcripts"
        case .general: "General"
        }
    }
    var windowTitle: String {
        switch self {
        case .setup: String(localized: "Setup")
        case .captions: String(localized: "Captions")
        case .dictation: String(localized: "Dictation")
        case .library: String(localized: "Models")
        case .models: String(localized: "Models")
        case .transcripts: String(localized: "Transcripts")
        case .general: String(localized: "General")
        }
    }
    var symbol: String {
        switch self {
        case .setup: "checklist"
        case .captions: "captions.bubble"
        case .dictation: "mic"
        case .library: "shippingbox"
        case .models: "shippingbox"
        case .transcripts: "text.document"
        case .general: "gearshape"
        }
    }
}

/// The settings window is a work surface, not a collection of unrelated tabs.
/// Keep navigation visible so a user can see where model, caption, and
/// dictation decisions live without opening and closing panes repeatedly.
struct SettingsRootView: View {
    @Bindable var state: AppState
    @State private var selection: SettingsPane
    @AppStorage("saiity.settings.sidebarVisible") private var sidebarVisible = true

    private let sidebarWidth: CGFloat = 200

    init(state: AppState, initialPane: SettingsPane = .captions) {
        self.state = state
        _selection = State(initialValue: Self.primaryPane(for: initialPane))
    }

    var body: some View {
        HStack(spacing: 0) {
            if sidebarVisible {
                VStack(spacing: 0) {
                    List(selection: $selection) {
                        ForEach(SettingsPane.allCases) { pane in
                            navigationRow(pane)
                        }
                    }
                    .listStyle(.sidebar)
                    .scrollContentBackground(.hidden)
                }
                .frame(width: sidebarWidth)
                .background(.regularMaterial)
            }

            if sidebarVisible {
                Divider()
            }

            detailView(for: selection)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(.clear)
        .onAppear {
            SettingsWindowController.updateSidebarToolbarLabel(sidebarVisible)
        }
        .onChange(of: selection) { _, value in
            SettingsWindowController.selectedPane = value
            if value == .library || value == .models || value == .transcripts {
                SettingsWindowController.setContentHeight(600)
            }
            SettingsWindowController.applyChrome()
        }
        .onReceive(NotificationCenter.default.publisher(for: .saiityToggleSettingsSidebar)) { _ in
            sidebarVisible.toggle()
            SettingsWindowController.updateSidebarToolbarLabel(sidebarVisible)
        }
        .onReceive(NotificationCenter.default.publisher(for: .saiitySelectSettingsPane)) { note in
            guard let raw = note.object as? String,
                  let pane = SettingsPane(rawValue: raw) else { return }
            selection = Self.primaryPane(for: pane)
        }
    }

    private func navigationRow(_ pane: SettingsPane) -> some View {
        Label(pane.title, systemImage: pane.symbol)
        .tag(pane)
    }

    private static func primaryPane(for pane: SettingsPane) -> SettingsPane {
        switch pane {
        case .models: .library
        case .general: .setup
        default: pane
        }
    }

    @ViewBuilder
    private func detailView(for pane: SettingsPane) -> some View {
        switch pane {
        case .setup:
            SettingsPage(isRefreshing: state.isRefreshing) {
                GeneralView(state: state) { expanded in
                    SettingsWindowController.setContentHeight(expanded ? 600 : 420)
                }
            }
        case .captions:
            SettingsPage(isRefreshing: state.isRefreshing) {
                CaptionsView(state: state) { expanded in
                    SettingsWindowController.setContentHeight(expanded ? 600 : 420)
                }
            }
        case .dictation:
            SettingsPage(isRefreshing: state.isRefreshing) {
                DictationView(state: state) { expanded in
                    SettingsWindowController.setContentHeight(expanded ? 600 : 420)
                }
            }
        case .library:
            SettingsPage(isRefreshing: state.isRefreshing) {
                ModelsView(state: state)
            }
        case .transcripts:
            SettingsPage(isRefreshing: state.isRefreshing) {
                TranscriptsView(state: state)
                    .task { await state.refreshLibraryAsync() }
            }
        case .models, .general:
            EmptyView()
        }
    }
}

struct SettingsPage<Content: View>: View {
    let isRefreshing: Bool
    let content: Content

    init(isRefreshing: Bool = false,
         @ViewBuilder content: () -> Content) {
        self.isRefreshing = isRefreshing
        self.content = content()
    }

    var body: some View {
        content
            .frame(maxWidth: 780, maxHeight: .infinity, alignment: .top)
            .overlay(alignment: .topTrailing) {
                if isRefreshing {
                    HStack(spacing: 6) {
                        ProgressView()
                            .controlSize(.small)
                        Text("Refreshing…")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(.regularMaterial, in: Capsule())
                    .overlay(Capsule().stroke(Color(nsColor: .separatorColor).opacity(0.35), lineWidth: 0.5))
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("Refreshing settings")
                    .padding(.trailing, 24)
                    .padding(.top, 16)
                }
            }
            .background(.clear)
            .safeAreaPadding(.top, 20)
    }
}

/// A consistent grouped surface used by the settings pages. GroupBox supplies
/// the native macOS hierarchy and appearance states so the page does not need
/// a second card style of its own.
struct SettingsSection<Content: View>: View {
    let title: LocalizedStringKey
    let subtitle: LocalizedStringKey?
    let content: Content

    init(title: LocalizedStringKey,
         subtitle: LocalizedStringKey? = nil,
         @ViewBuilder content: () -> Content) {
        self.title = title
        self.subtitle = subtitle
        self.content = content()
    }

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                content
            }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 4)
        } label: {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.headline)
                if let subtitle {
                    Text(subtitle)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .groupBoxStyle(.automatic)
    }
}

/// A disclosure whose whole header is a real button target. SwiftUI's
/// macOS `DisclosureGroup` can leave the label inert and make only the tiny
/// chevron clickable, which is especially easy to miss in a settings page.
struct SettingsDisclosure<Content: View>: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Binding private var isExpanded: Bool
    let title: LocalizedStringKey
    private let content: () -> Content

    init(_ title: LocalizedStringKey = "More options",
         isExpanded: Binding<Bool>,
         @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self._isExpanded = isExpanded
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button {
                withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.18)) {
                    isExpanded.toggle()
                }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.body.weight(.medium))
                        .frame(width: 16, height: 20)
                        .accessibilityHidden(true)
                    Text(title)
                        .font(.body.weight(.medium))
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, minHeight: 28, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text(title))
            .accessibilityValue(Text(isExpanded ? "Expanded" : "Collapsed"))

            if isExpanded {
                content()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
