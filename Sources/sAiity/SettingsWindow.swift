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
}

/// Shared so non-UI types can report disk usage honestly.
enum AppStateSizeHelper {
    static func folderSize(_ url: URL) -> String? {
        let fm = FileManager.default
        guard let e = fm.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey]) else { return nil }
        var total: Int64 = 0
        for case let f as URL in e {
            total += Int64((try? f.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
        guard total > 0 else { return nil }
        return ByteCountFormatter.string(fromByteCount: total, countStyle: .file)
    }
}

// MARK: - Model

@MainActor
@Observable
final class AppState {

    var sessions: [SessionRef] = []
    var diskUsage: String?

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
    var captionClickThrough = UserDefaults.standard.bool(forKey: "captionClickThrough") {
        didSet { UserDefaults.standard.set(captionClickThrough, forKey: "captionClickThrough") }
    }
    /// Speak each finished sentence through VoiceOver. Read per sentence by
    /// the caption pipeline, so no notification is needed.
    var announceCaptions = UserDefaults.standard.bool(forKey: "announceCaptions") {
        didSet { UserDefaults.standard.set(announceCaptions, forKey: "announceCaptions") }
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
    /// Assets whose files are present but refused to load, by id → reason.
    /// Fed by LoadHealth; the observer keeps an open Models page truthful when
    /// a session fails in the background.
    var loadFailures: [String: String] = LoadHealth.all
    @ObservationIgnored private var loadHealthObserver: NSObjectProtocol?

    @ObservationIgnored private var gapObserver: NSObjectProtocol?
    @ObservationIgnored private var targetObserver: NSObjectProtocol?

    init() {
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
    }
    var ownedTotal: String = "—"
    /// Measured with the same inventory pass as `ownedTotal`, so the storage
    /// button does not rescan the model tree on every SwiftUI update.
    var ownedBytes: Int64 = 0
    /// Bytes under our models root that belong to no known asset.
    var strayTotal: String?
    /// The single in-flight download, by `ModelAsset.id`. One slot rather than a
    /// flag per family: the per-family flags never cross-checked each other, so
    /// two multi-gigabyte downloads could run at once on one connection.
    var activeDownload: String?
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

    /// Sentence-at-close or live retranslation of the growing sentence. Read
    /// by the caption pipeline per clause, so no notification is needed — the
    /// next clause simply behaves the new way.
    var translationTiming = TranslationTiming.current {
        didSet {
            guard translationTiming != oldValue else { return }
            TranslationTiming.current = translationTiming
        }
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

    /// Press-to-talk is separate from live captions. It is enabled by default,
    /// but can be disabled without changing any caption or microphone-mixing
    /// preference.
    var dictationEnabled = UserDefaults.standard.object(forKey: "dictationEnabled") as? Bool ?? true {
        didSet {
            guard dictationEnabled != oldValue else { return }
            UserDefaults.standard.set(dictationEnabled, forKey: "dictationEnabled")
            NotificationCenter.default.post(name: .saiityDictationSettingChanged, object: nil)
        }
    }
    var dictationRecognizer: DictationRecognizer = DictationRecognizer.selected {
        didSet {
            guard dictationRecognizer != oldValue else { return }
            DictationRecognizer.selected = dictationRecognizer
            NotificationCenter.default.post(name: .saiityDictationSettingChanged, object: nil)
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
            guard dictationCleanupEnabled != oldValue else { return }
            UserDefaults.standard.set(dictationCleanupEnabled, forKey: "dictationCleanupEnabled")
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

    /// Writing back to CaptionStyle.current persists AND posts the change
    /// notification, so the live bubble updates as the slider moves.
    var style: CaptionStyle = CaptionStyle.current {
        didSet { CaptionStyle.current = style }
    }

    func refreshModels() {
        let inventory = ModelRegistry.inventorySnapshot()
        assets = inventory.assets
        loadFailures = LoadHealth.all
        let total = inventory.ownedBytes
        ownedBytes = total
        ownedTotal = total > 0 ? ModelRegistry.format(total) : String(localized: "nothing downloaded")
        let stray = inventory.strayBytes
        // Only worth mentioning once it is a real amount; a few KB of cache
        // metadata is noise.
        strayTotal = stray > 8 << 20 ? ModelRegistry.format(stray) : nil
    }

    /// The in-flight download, so Cancel can actually cancel it. Before this a
    /// misclick on a multi-gigabyte model had no exit short of quitting the app.
    @ObservationIgnored private var downloadTask: Task<Void, Never>?

    /// Download one asset. Progress is whatever the underlying API can honestly
    /// report — some give bytes, some a fraction, some nothing at all.
    func download(_ asset: ModelAsset) async {
        guard activeDownload == nil, let install = asset.install else { return }
        if let required = asset.advertisedBytes,
           let available = ModelRegistry.availableDiskBytes(),
           available < required {
            modelError = String(localized: "Not enough free space for \(asset.title). Need about \(ModelRegistry.format(required)); only \(ModelRegistry.format(available)) is available.")
            refreshModels()
            return
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
            } catch is CancellationError {
                // The user pressed Cancel; not an error, so no red text.
            } catch let e as URLError where e.code == .cancelled {
                // URLSession's spelling of the same thing.
            } catch {
                self.modelError = error.localizedDescription
            }
        }
        downloadTask = task
        await task.value
        downloadTask = nil
        activeDownload = nil
        downloadProgress = nil
        refreshModels()
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
        if CaptionSession.shared.isRunning, asset.use.isSelected {
            modelError = String(localized: "\(asset.title) is running the live captions. Stop captions first.")
            return
        }
        // Recognition can be prewarmed for dictation even when no captions
        // engine has been selected: ASREngine.effective uses the recommended
        // fallback in that state. Release all loaded recognition resources
        // before deletion so the fallback cannot keep the file mapped.
        if !CaptionSession.shared.isRunning,
           asset.family == .recognition || asset.use.isSelected {
            await CaptionSession.shared.releaseEverything()
        }
        if !ModelRegistry.remove(asset) {
            modelError = String(localized: "Could not delete \(asset.title).")
        }
        refreshModels()
    }

    /// Remove every model the app downloaded. Returns the bytes freed, or nil if
    /// it refused or failed.
    @discardableResult
    func removeAllDownloads() async -> Int64? {
        modelError = nil
        guard !CaptionSession.shared.isRunning else {
            modelError = String(localized: "Captions are running. Stop them first.")
            return nil
        }
        await CaptionSession.shared.releaseEverything()
        do {
            let freed = try ModelRegistry.removeAllOwned()
            refreshModels()
            return freed
        } catch {
            modelError = error.localizedDescription
            refreshModels()
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
        // Re-read selections from defaults. Without this the window shows
        // whatever was current when the AppState singleton was created, which
        // is one of the ways "selecting a model appears to do nothing".
        engine = ASREngine.selected
        translationEngine = TranslationEngine.visibleSelection(TranslationEngine.selected)
        dictationTranslationEngine = TranslationEngine.visibleSelection(TranslationEngine.dictationSelected)
        llmModel = LocalModel.cleanupSelected
        // Was missing, so a target picked from the menu bar never appeared here.
        adoptTarget(UserDefaults.standard.string(forKey: "translateTo"))
        await refreshTargetSupport()
        // The three SpeechTranscriber/AssetInventory queries that used to live
        // here each round-trip to the system speech daemon and took seconds —
        // that was the whole reason this window opened slowly. With Apple's
        // engine gone, nothing needs them.
        refreshModels()
        refreshRunningApps()
        sessions = TranscriptStore.list()
        diskUsage = Self.folderSize(TranscriptStore.sessionsDir)
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
                launchAtLoginNote = String(localized: "Approve sAiity in System Settings → General → Login Items.")
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


    /// Nil when there is nothing stored — ByteCountFormatter renders 0 as
    /// "Zero KB", which reads like a glitch.
    static func folderSize(_ url: URL) -> String? { AppStateSizeHelper.folderSize(url) }

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
    /// Let a behind-window material actually show. An opaque window with a
    /// solid backgroundColor paints over the blur before it is ever composited
    /// — the effect silently does nothing, which is the usual reason vibrancy
    /// "doesn't work".
    func makeVibrant() {
        isOpaque = false
        backgroundColor = .clear
    }
}

@MainActor
enum SettingsWindowController {
    private static var window: NSWindow?
    /// Shared, so the menu bar can raise a specific sheet in this window.
    static let state = AppState()
    static var selectedPane: SettingsPane = .captions

    static func show() {
        if let w = window {
            NSApp.activate(ignoringOtherApps: true)
            w.makeKeyAndOrderFront(nil)
            Task { await state.refresh() }
            return
        }
        let w = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 980, height: 680),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false)
        w.isReleasedWhenClosed = false
        let host = NSHostingController(
            rootView: SettingsRootView(state: state,
                                        initialPane: selectedPane)
                .frame(minWidth: 900, minHeight: 600)
                .background(VibrantBackground()))
        host.view.wantsLayer = true
        host.view.layer?.backgroundColor = .clear
        w.contentViewController = host
        w.title = "sAiity"
        w.titlebarAppearsTransparent = false
        // The settings surface owns its navigation. A system toolbar or the
        // automatic NavigationSplitView toggle can move when macOS changes the
        // titlebar metrics, and can paint over the page header on macOS 27.
        w.toolbar = nil
        w.titleVisibility = .visible
        w.setContentSize(NSSize(width: 980, height: 680))
        w.contentMinSize = NSSize(width: 900, height: 600)
        w.center()
        window = w
        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
        Task { await state.refresh() }
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
    case captions, dictation, library

    // Legacy destinations remain valid for menu notifications and older tests,
    // but are deliberately not presented as top-level navigation items.
    case models, transcripts, general

    static var allCases: [SettingsPane] { [.captions, .dictation, .library] }

    var id: String { rawValue }
    var title: LocalizedStringKey {
        switch self {
        case .captions: "Captions"
        case .dictation: "Dictation"
        case .library: "Library"
        case .models: "Models"
        case .transcripts: "Transcripts"
        case .general: "General"
        }
    }
    var symbol: String {
        switch self {
        case .captions: "captions.bubble"
        case .dictation: "mic"
        case .library: "books.vertical"
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
    @State private var libraryTab: LibraryTab = .models
    @State private var sidebarVisible = true
    @State private var showSupport = false

    private let sidebarWidth: CGFloat = 190

    init(state: AppState, initialPane: SettingsPane = .captions) {
        self.state = state
        _selection = State(initialValue: Self.primaryPane(for: initialPane))
    }

    var body: some View {
        HStack(spacing: 0) {
            if sidebarVisible {
                VStack(spacing: 0) {
                    HStack {
                        Text("Settings")
                            .font(.headline)
                        Spacer()
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 14)
                    .padding(.bottom, 8)

                    List(selection: $selection) {
                        navigationRow(.captions)
                        navigationRow(.dictation)
                        navigationRow(.library)
                    }
                    .listStyle(.sidebar)

                    Button {
                        showSupport = true
                    } label: {
                        Label("About & Support", systemImage: "info.circle")
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                }
                .frame(width: sidebarWidth)
                .background(Color(nsColor: .underPageBackgroundColor))
            }

            Divider()

            detailView(for: selection)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .onChange(of: selection) { _, value in
            SettingsWindowController.selectedPane = value
        }
        .onReceive(NotificationCenter.default.publisher(for: .saiitySelectSettingsPane)) { note in
            guard let raw = note.object as? String,
                  let pane = SettingsPane(rawValue: raw) else { return }
            if pane == .general {
                showSupport = true
            } else {
                if pane == .models { libraryTab = .models }
                if pane == .transcripts { libraryTab = .transcripts }
                selection = Self.primaryPane(for: pane)
            }
        }
        .sheet(isPresented: $showSupport) {
            SheetShell(title: "About & Support",
                       subtitle: "Permissions, diagnostics, privacy, and app information.",
                       width: 620, height: 560) {
                GeneralView(state: state)
            }
        }
    }

    private func navigationRow(_ pane: SettingsPane) -> some View {
        Label(pane.title, systemImage: pane.symbol)
        .tag(pane)
    }

    private static func primaryPane(for pane: SettingsPane) -> SettingsPane {
        switch pane {
        case .models, .transcripts, .general: .library
        default: pane
        }
    }

    @ViewBuilder
    private func detailView(for pane: SettingsPane) -> some View {
        switch pane {
        case .captions:
            SettingsPage(title: pane.title, sidebarVisible: sidebarVisible,
                         onToggleSidebar: { sidebarVisible.toggle() }) {
                CaptionsView(state: state)
            }
        case .dictation:
            SettingsPage(title: pane.title, sidebarVisible: sidebarVisible,
                         onToggleSidebar: { sidebarVisible.toggle() }) {
                DictationView(state: state)
            }
        case .library:
            SettingsPage(title: pane.title, sidebarVisible: sidebarVisible,
                         onToggleSidebar: { sidebarVisible.toggle() }) {
                LibraryView(state: state, tab: $libraryTab)
            }
        case .models, .transcripts, .general:
            EmptyView()
        }
    }
}

struct SettingsPage<Content: View>: View {
    let title: LocalizedStringKey
    let sidebarVisible: Bool
    let onToggleSidebar: () -> Void
    let content: Content

    init(title: LocalizedStringKey,
         sidebarVisible: Bool = true,
         onToggleSidebar: @escaping () -> Void = {},
         @ViewBuilder content: () -> Content) {
        self.title = title
        self.sidebarVisible = sidebarVisible
        self.onToggleSidebar = onToggleSidebar
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: 14) {
                Text(title)
                    .font(.title2.weight(.semibold))
                Spacer(minLength: 12)
                Button(action: onToggleSidebar) {
                    Image(systemName: "sidebar.left")
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.borderless)
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
                .help(sidebarVisible ? "Hide sidebar" : "Show sidebar")
                .accessibilityLabel(sidebarVisible ? "Hide sidebar" : "Show sidebar")
            }
            .padding(.horizontal, 30)
            .padding(.top, 26)
            .padding(.bottom, 18)
            Divider()
            content
                .frame(maxWidth: 780, maxHeight: .infinity, alignment: .top)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        // Leave a small explicit buffer below the native titlebar/toolbar safe
        // area. This prevents the macOS 27 unified-titlebar overlap while
        // keeping the page header visually attached to its content.
        .safeAreaPadding(.top, 12)
    }
}

/// A consistent full-width setting band used by the settings pages. The
/// divider separates decisions without turning every group into a nested card.
struct SettingsSection<Content: View>: View {
    let title: LocalizedStringKey
    let subtitle: LocalizedStringKey
    let content: Content

    init(title: LocalizedStringKey,
         subtitle: LocalizedStringKey,
         @ViewBuilder content: () -> Content) {
        self.title = title
        self.subtitle = subtitle
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.headline)
            content
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 30)
        .padding(.vertical, 16)
        .overlay(alignment: .bottom) {
            Divider()
        }
    }
}
