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
            MainActor.assumeIsolated { self?.loadFailures = LoadHealth.all }
        }
        // The menu bar writes the same translate-target preference while the
        // Settings window is open, so follow it live rather than only on
        // reopen. Owned here, not by a root view — the toolbar-tabbed window
        // has no single SwiftUI root to hang an onReceive on.
        targetObserver = NotificationCenter.default.addObserver(
            forName: .saiityTranslateTargetChanged, object: nil,
            queue: .main) { [weak self] note in
            let t = note.userInfo?["target"] as? String
            MainActor.assumeIsolated {
                guard let self else { return }
                self.adoptTarget(t)
                Task { await self.refreshTargetSupport() }
            }
        }
        gapObserver = NotificationCenter.default.addObserver(
            forName: SystemAudioCapture.gapDiagnostics, object: nil,
            queue: .main) { [weak self] note in
            MainActor.assumeIsolated {
                guard let floor = note.userInfo?["floor"] as? Float,
                      let th = note.userInfo?["threshold"] as? Float else {
                    self?.gapReadout = nil
                    return
                }
                let fires = note.userInfo?["fires"] as? Int ?? 0
                // Digital silence is RMS 0; clamp so the dB stays displayable.
                self?.gapReadout = GapReadout(
                    floorDb: Double(20 * log10(max(floor, 1e-8))),
                    thresholdDb: Double(20 * log10(max(th, 1e-8))),
                    fires: fires)
            }
        }
    }
    var ownedTotal: String = "—"
    /// Bytes under our models root that belong to no known asset.
    var strayTotal: String?
    /// The single in-flight download, by `ModelAsset.id`. One slot rather than a
    /// flag per family: the per-family flags never cross-checked each other, so
    /// two multi-gigabyte downloads could run at once on one connection.
    var activeDownload: String?
    var downloadProgress: DownloadProgress?
    var modelError: String?
    var translationEngine: TranslationEngine? = TranslationEngine.selected {
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
        assets = ModelRegistry.snapshot()
        loadFailures = LoadHealth.all
        let total = ModelRegistry.ownedTotalBytes()
        ownedTotal = total > 0 ? ModelRegistry.format(total) : String(localized: "nothing downloaded")
        let stray = ModelRegistry.strayBytes()
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
        if asset.use.isSelected {
            if CaptionSession.shared.isRunning {
                modelError = String(localized: "\(asset.title) is running the live captions. Stop captions first.")
                return
            }
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

    /// Whether the selected engine can reach the selected target. Recomputed on
    /// every change to either, because a stored target outlives an engine swap.
    var targetSupportedByEngine = true

    func refreshTargetSupport() async {
        guard let t = translateTo else { targetSupportedByEngine = true; return }
        // Ask the engine that would actually run. Reporting "unsupported" when
        // nothing is chosen produced a flatly false claim — "MADLAD cannot
        // translate into English" — from an engine the user had not picked.
        let asked = translationEngine ?? .recommended
        targetSupportedByEngine = await asked.languages
            .supportedCanonicalCodes().contains(t)
    }
    var llmModel: LocalModel? = LocalModel.selected {
        didSet {
            guard llmModel != oldValue else { return }
            LocalModel.selected = llmModel
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
        translationEngine = TranslationEngine.selected
        llmModel = LocalModel.selected
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

/// Puts the selected pane's name in the title bar, the way every Apple
/// preferences window does.
///
/// `NSTabViewController` does NOT do this on its own — verified, not assumed:
/// a window whose contentViewController is a toolbar-style tab controller
/// keeps whatever title it had (empty, if never set) no matter which child
/// carries a `title`. Only the window's own contentViewController title is
/// tracked, and that is the tab controller's.
private final class PaneTitlingTabViewController: NSTabViewController {
    override func tabView(_ tabView: NSTabView, didSelect item: NSTabViewItem?) {
        super.tabView(tabView, didSelect: item)
        if let label = item?.label { view.window?.title = label }
    }
}

@MainActor
enum SettingsWindowController {
    private static var window: NSWindow?
    /// Shared, so the menu bar can raise a specific sheet in this window.
    static let state = AppState()

    static func show() {
        if let w = window {
            NSApp.activate(ignoringOtherApps: true)
            w.makeKeyAndOrderFront(nil)
            Task { await state.refresh() }
            return
        }
        let w = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 540),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false)
        w.isReleasedWhenClosed = false
        // NSTabViewController's toolbar style, not SwiftUI's TabView: this is
        // what every Apple preferences window is made of — toolbar items as
        // panes, the window title following the selected pane. TabView drew a
        // centred segmented control, which is a content control, not window
        // chrome.
        let tabs = PaneTitlingTabViewController()
        tabs.tabStyle = .toolbar
        let pages: [(String, String, AnyView)] = [
            (String(localized: "Captions"), "captions.bubble",
             AnyView(CaptionsView(state: state))),
            (String(localized: "Models"), "shippingbox",
             AnyView(ModelsView(state: state))),
            (String(localized: "Transcripts"), "text.document",
             AnyView(TranscriptsView(state: state))),
            (String(localized: "General"), "gearshape",
             AnyView(GeneralView(state: state))),
        ]
        for (title, symbol, view) in pages {
            let host = NSHostingController(
                rootView: view
                    .frame(minWidth: 700, minHeight: 480)
                    .background(VibrantBackground()))
            // The hosting view is opaque by default and would sit on top of
            // the material like a sheet of paper.
            host.view.wantsLayer = true
            host.view.layer?.backgroundColor = .clear
            host.title = title
            let item = NSTabViewItem(viewController: host)
            item.label = title
            item.image = NSImage(systemSymbolName: symbol,
                                 accessibilityDescription: title)
            tabs.addTabViewItem(item)
        }
        w.contentViewController = tabs
        // AFTER the assignment, and not optional: setting a tab controller as
        // contentViewController resizes the window to that controller's own
        // fitting size — measured at 500×500 here, which clipped ~200 pt off
        // every 700 pt-wide pane. The requested size has to be restated, and
        // a minimum enforced so a drag cannot reproduce the clipping.
        w.setContentSize(NSSize(width: 760, height: 540))
        w.contentMinSize = NSSize(width: 720, height: 480)
        w.title = tabs.tabViewItems.first?.label ?? "sAiity"
        w.makeVibrant()
        w.center()
        window = w
        // Deliberate: this is the one window the user explicitly asked for, so
        // unlike the caption bubble it may take focus.
        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
        Task { await state.refresh() }
    }
}

// MARK: - Views

// There is deliberately no custom window chrome anywhere in Settings. It used
// to share an accent-tinted gradient wash ("SettingsBackground") with the
// setup wizard, with every Form's own background suppressed so it showed
// through — which read as a web page wearing a Mac costume. Native grouped
// Forms inside a toolbar-tabbed preferences window are what Apple's own apps
// do; this app's personality lives in its words and the caption bubble, not
// in tinted air.
