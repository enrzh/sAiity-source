import AppKit
import Foundation
import ServiceManagement
import Speech
import SwiftUI
import Translation

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

    var lastError: String?

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

    var launchAtLogin = false
    var launchAtLoginNote = ""

    var engine = ASREngine.current {
        didSet {
            guard engine != oldValue else { return }
            NotificationCenter.default.post(name: .saiityEngineChanged, object: nil,
                                            userInfo: ["engine": engine.rawValue])
        }
    }
    var engineNeedsDownload = ASREngine.current.needsDownload

    /// Every downloadable asset with its live disk state, from one registry.
    var assets: [AssetStatus] = []
    var ownedTotal: String = "—"
    /// Bytes under our models root that belong to no known asset.
    var strayTotal: String?
    /// The single in-flight download, by `ModelAsset.id`. One slot rather than a
    /// flag per family: the per-family flags never cross-checked each other, so
    /// two multi-gigabyte downloads could run at once on one connection.
    var activeDownload: String?
    var downloadProgress: DownloadProgress?
    var modelError: String?
    var translationEngine = TranslationEngine.current {
        didSet {
            guard translationEngine != oldValue else { return }
            TranslationEngine.current = translationEngine
            // Whisper replaces recognition, so switching to or from it changes
            // which ASR backend runs.
            NotificationCenter.default.post(name: .saiityTranslateTargetChanged, object: nil,
                                            userInfo: ["target": translateTo as Any])
        }
    }
    var shortcutError: String?
    var shortcutsVersion: Int = 0

    /// Writing back to CaptionStyle.current persists AND posts the change
    /// notification, so the live bubble updates as the slider moves.
    var style: CaptionStyle = CaptionStyle.current {
        didSet { CaptionStyle.current = style }
    }

    func refreshModels() {
        assets = ModelRegistry.snapshot()
        let total = ModelRegistry.ownedTotalBytes()
        ownedTotal = total > 0 ? ModelRegistry.format(total) : "nothing downloaded"
        let stray = ModelRegistry.strayBytes()
        // Only worth mentioning once it is a real amount; a few KB of cache
        // metadata is noise.
        strayTotal = stray > 8 << 20 ? ModelRegistry.format(stray) : nil
    }

    /// Download one asset. Progress is whatever the underlying API can honestly
    /// report — some give bytes, some a fraction, some nothing at all.
    func download(_ asset: ModelAsset) async {
        guard activeDownload == nil, let install = asset.install else { return }
        activeDownload = asset.id
        downloadProgress = DownloadProgress(note: "Starting…")
        modelError = nil
        defer { activeDownload = nil; downloadProgress = nil; refreshModels() }
        do {
            try await install { p in
                Task { @MainActor in self.downloadProgress = p }
            }
        } catch {
            modelError = error.localizedDescription
        }
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
                modelError = "\(asset.title) is running the live captions. Stop captions first."
                return
            }
            await CaptionSession.shared.releaseEverything()
        }
        if !ModelRegistry.remove(asset) {
            modelError = "Could not delete \(asset.title)."
        }
        refreshModels()
    }

    /// Remove every model the app downloaded. Returns the bytes freed, or nil if
    /// it refused or failed.
    @discardableResult
    func removeAllDownloads() async -> Int64? {
        modelError = nil
        guard !CaptionSession.shared.isRunning else {
            modelError = "Captions are running. Stop them first."
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


    // Translation. Apple will only translate between language pairs whose assets
    // are on disk, and `TranslationSession(installedSource:target:)` — the only
    // initializer callable outside SwiftUI — throws for anything else. The ONLY
    // supported way to get a pair downloaded is SwiftUI's .translationTask,
    // which vends a session we can call prepareTranslation() on. That is why
    // this lives in the window and not in the menu.
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
    var translationConfig: TranslationSession.Configuration?
    var showTranslationLanguages = false
    /// (code, display name, installed) for every target Apple supports.
    var translationLanguages: [(String, String, Bool)] = []
    var translationLanguagesLoading = false
    var downloadingPair: String?

    // Apple speech models. Queried lazily — these calls round-trip the system
    // speech daemon and are slow, which is why they no longer run on every
    // settings open.
    var showAppleLanguages = false
    var appleLocales: [String] = []
    var appleInstalled: Set<String> = []
    var appleReserved: Set<String> = []
    var appleMaxReserved = 0
    var appleLoading = false
    var appleDownloading: String?
    var appleSizeOnDisk: String?

    var showQwenModels = false
    /// The searchable target-language sheet. Also raised from the menu bar's
    /// "All languages…" item, which is why it lives on shared state.
    var showTranslationPicker = false

    /// Whether the selected engine can reach the selected target. Recomputed on
    /// every change to either, because a stored target outlives an engine swap.
    var targetSupportedByEngine = true

    func refreshTargetSupport() async {
        guard let t = translateTo else { targetSupportedByEngine = true; return }
        targetSupportedByEngine = await translationEngine.languages
            .supportedCanonicalCodes().contains(t)
    }
    var qwenModel = QwenModel.selected {
        didSet { QwenModel.selected = qwenModel }
    }
    func refreshAppleLocales() async {
        appleLoading = true
        defer { appleLoading = false }
        appleLocales = await SpeechTranscriber.supportedLocales
            .map { $0.identifier(.bcp47) }.sorted()
        appleInstalled = Set(await SpeechTranscriber.installedLocales.map { $0.identifier(.bcp47) })
        appleReserved = Set(await AssetInventory.reservedLocales.map { $0.identifier(.bcp47) })
        appleMaxReserved = AssetInventory.maximumReservedLocales
    }

    func downloadAppleLocale(_ tag: String) async {
        appleDownloading = tag
        modelError = nil
        defer { appleDownloading = nil }
        let t = SpeechTranscriber(locale: Locale(identifier: tag), transcriptionOptions: [],
                                  reportingOptions: [], attributeOptions: [])
        do {
            if let req = try await AssetInventory.assetInstallationRequest(supporting: [t]) {
                try await req.downloadAndInstall()
            }
        } catch {
            let ns = error as NSError
            modelError = (ns.domain == "SFSpeechErrorDomain" && ns.code == 11)
                ? "macOS allows only \(appleMaxReserved) languages at a time. Release one first."
                : error.localizedDescription
        }
        await refreshAppleLocales()
    }

    func releaseAppleLocale(_ tag: String) async {
        _ = await AssetInventory.release(reservedLocale: Locale(identifier: tag))
        await refreshAppleLocales()
    }

    /// Reads the on-disk asset folder directly. The API under-reports: Japanese
    /// weights sit there at 341 MB while `installedLocales` denies having them.
    static func appleAssetsSize() -> String? {
        let p = "/System/Library/AssetsV2/com_apple_MobileAsset_UAF_Speech_AutomaticSpeechRecognition/purpose_auto"
        let size = ModelRegistry.byteSize(of: URL(fileURLWithPath: p))
        return size > 0 ? ModelRegistry.format(size) : nil
    }

    /// Enumerate what Apple can translate into, and which pairs are already on
    /// disk. `supportedLanguages` gives the full set; `status(from:to:)` is the
    /// only way to know whether a specific PAIR is installed.
    func refreshTranslationLanguages(from source: String) async {
        translationLanguagesLoading = true
        defer { translationLanguagesLoading = false }
        let availability = LanguageAvailability()
        let src = Locale.Language(identifier: source)
        var out: [(String, String, Bool)] = []
        for lang in await availability.supportedLanguages {
            guard let code = lang.languageCode?.identifier else { continue }
            // Skip the source itself and duplicate script variants.
            if code == source { continue }
            if out.contains(where: { $0.0 == code }) { continue }
            let st = await availability.status(from: src, to: lang)
            let name = Locale.current.localizedString(forLanguageCode: code) ?? code
            out.append((code, name.capitalized, st == .installed))
        }
        translationLanguages = out.sorted { $0.1 < $1.1 }
    }
    var translationStatus = ""

    /// Kicks the SwiftUI task that owns the session. Setting a fresh
    /// Configuration is what re-triggers it.
    func prepareTranslation(from source: String, to explicit: String? = nil) {
        guard let t = explicit ?? translateTo else { return }
        translationStatus = "Preparing…"
        translationConfig = TranslationSession.Configuration(
            source: Locale.Language(identifier: source),
            target: Locale.Language(identifier: t))
    }

    func refresh() async {
        // Re-read selections from defaults. Without this the window shows
        // whatever was current when the AppState singleton was created, which
        // is one of the ways "selecting a model appears to do nothing".
        translationEngine = TranslationEngine.current
        qwenModel = QwenModel.selected
        // Was missing, so a target picked from the menu bar never appeared here.
        adoptTarget(UserDefaults.standard.string(forKey: "translateTo"))
        await refreshTargetSupport()
        // The three SpeechTranscriber/AssetInventory queries that used to live
        // here each round-trip to the system speech daemon and took seconds —
        // that was the whole reason this window opened slowly. With Apple's
        // engine gone, nothing needs them.
        refreshModels()
        sessions = TranscriptStore.list()
        diskUsage = Self.folderSize(TranscriptStore.sessionsDir)
        refreshLaunchAtLogin()
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
                launchAtLoginNote = "Approve sAiity in System Settings → General → Login Items."
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

    private static func _unused_folderSize(_ url: URL) -> String? {
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

// MARK: - Window

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
        w.title = "sAiity"
        w.center()
        w.isReleasedWhenClosed = false
        w.contentViewController = NSHostingController(rootView: RootView(state: state))
        window = w
        // Deliberate: this is the one window the user explicitly asked for, so
        // unlike the caption bubble it may take focus.
        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
        Task { await state.refresh() }
    }
}

// MARK: - Views

private struct RootView: View {
    @Bindable var state: AppState

    var body: some View {
        TabView {
            CaptionsView(state: state)
                .tabItem { Label("Captions", systemImage: "captions.bubble") }
            ModelsView(state: state)
                .tabItem { Label("Models", systemImage: "shippingbox") }
            LibraryView(state: state)
                .tabItem { Label("Library", systemImage: "text.document") }
        }
        .frame(minWidth: 700, minHeight: 480)
        .task { await state.refresh() }
        // The menu bar writes the same preference while this window is open, so
        // follow it live rather than only on reopen.
        .onReceive(NotificationCenter.default.publisher(for: .saiityTranslateTargetChanged)) { note in
            state.adoptTarget(note.userInfo?["target"] as? String)
            Task { await state.refreshTargetSupport() }
        }
    }
}
