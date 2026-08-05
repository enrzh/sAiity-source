import AppKit
import Foundation

/// Progress from a download.
///
/// `fraction == nil` means genuinely indeterminate — some of these APIs report
/// no percentage at all. Say so rather than inventing one.
struct DownloadProgress: Sendable {
    var fraction: Double?
    var note: String
    var completed: Int64?
    var total: Int64?

    init(fraction: Double? = nil, note: String = "", completed: Int64? = nil, total: Int64? = nil) {
        self.fraction = fraction
        self.note = note
        self.completed = completed
        self.total = total
    }
}

typealias ProgressSink = @Sendable (DownloadProgress) -> Void

/// A place in System Settings that can do something the app is not allowed to.
enum SystemRoute: Sendable {
    case storage
    case languageAndRegion

    var url: URL? {
        switch self {
        case .storage:
            return URL(string: "x-apple.systempreferences:com.apple.settings.Storage")
        case .languageAndRegion:
            return URL(string: "x-apple.systempreferences:com.apple.Localization-Settings.extension")
        }
    }

    var label: String {
        switch self {
        case .storage: return "Open Storage Settings"
        case .languageAndRegion: return "Open Language & Region"
        }
    }

    func open() {
        if let url { NSWorkspace.shared.open(url) }
    }
}

/// How an asset's bytes are laid out, and how "finished" is told from "started".
enum AssetStorage: Sendable {
    /// A directory we own. `markers` are paths relative to it that must ALL be
    /// present for the download to count as complete. Anything less is a
    /// partial download — which is a third state, not a synonym for missing.
    case directory(URL, markers: [String])
    /// A single file whose finished size we know.
    case file(URL, expectedBytes: Int64)
    /// Measurable but not ours: Apple's speech assets on the sealed volume.
    case systemPath(String)
    /// Not measurable at all: Apple's translation pairs expose no path.
    case opaque
}

/// What removing an asset actually means.
///
/// A closed enum rather than a `canDelete: Bool`, because two of these assets
/// genuinely cannot be removed by any app — the Speech and Translation
/// frameworks expose no uninstall API. Modelling that as a Bool is how the UI
/// ended up with a Delete button wired to a guard that could never pass.
enum AssetRemoval: Sendable {
    case remove(URL)
    case systemOnly(reason: String, route: SystemRoute)
}

/// When deleting would pull the rug out from under a running session.
enum AssetUse: Sendable {
    case never
    case whenRecognitionEngine(ASREngine)
    case whenTranslator(TranslationEngine)
    case whenQwenVariant(file: String)

    /// True when this asset is the one currently selected to do its job.
    var isSelected: Bool {
        switch self {
        case .never:
            return false
        case .whenRecognitionEngine(let e):
            return ASREngine.current == e
        case .whenTranslator(let t):
            return TranslationEngine.current == t
        case .whenQwenVariant(let f):
            return TranslationEngine.current == .qwen && QwenModel.selected.file == f
        }
    }
}

/// One downloadable thing, described once so every surface agrees about it.
struct ModelAsset: Identifiable, Sendable {
    enum Family: Int, Sendable, Comparable {
        case recognition, translation, system
        static func < (a: Family, b: Family) -> Bool { a.rawValue < b.rawValue }
    }

    let id: String
    let family: Family
    let title: String
    let detail: String
    /// The weights' own terms, and where they come from.
    ///
    /// These are downloaded at first use, not shipped inside the app, so this is
    /// about telling the user what they are fetching rather than a
    /// redistribution obligation. It still has to be right: the UI previously
    /// said "Apache-2.0" for translation engines and said nothing at all for the
    /// recognition engines, which are NVIDIA models under NVIDIA's own terms.
    let licence: String?
    /// What we tell the user before downloading. Nil when genuinely unknown.
    let advertisedBytes: Int64?
    let storage: AssetStorage
    let removal: AssetRemoval
    let use: AssetUse
    /// Nil for assets only macOS can install (Apple speech locales and
    /// translation pairs are requested through their own framework flows).
    let install: (@Sendable (@escaping ProgressSink) async throws -> Void)?
}

/// An asset plus what is actually on disk right now.
struct AssetStatus: Identifiable, Sendable {
    let asset: ModelAsset
    let isInstalled: Bool
    /// Bytes are present but at least one completion marker is missing. The
    /// state that used to be reported as either a confident "ready" (and then
    /// failed to load) or a confident "missing" (and then re-downloaded).
    let isPartial: Bool
    let bytesOnDisk: Int64

    var id: String { asset.id }

    /// Measured once installed, advertised before that.
    var sizeText: String {
        if bytesOnDisk > 0 { return ModelRegistry.format(bytesOnDisk) }
        if let b = asset.advertisedBytes { return ModelRegistry.format(b) }
        return "—"
    }
}

/// The one place that knows about every model on disk.
///
/// Before this there were six assets and five bookkeeping patterns: two engines
/// deleted themselves inline from a SwiftUI button, one had no UI at all, and
/// the nominal registry only ever covered recognition engines.
enum ModelRegistry {

    /// The root every downloaded model lives under. Note that transcripts live
    /// in a SIBLING directory, which is what makes `removeAllOwned()` safe.
    static var root: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("de.aiity.saiity/Models", isDirectory: true)
    }

    // MARK: - Measuring

    static func byteSize(of url: URL) -> Int64 {
        guard let e = FileManager.default.enumerator(at: url,
                                                     includingPropertiesForKeys: [.fileSizeKey]) else {
            return 0
        }
        var total: Int64 = 0
        for case let f as URL in e {
            total += Int64((try? f.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
        return total
    }

    static func format(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    // MARK: - The catalogue

    static func assets() -> [ModelAsset] {
        ASREngine.allCases.map(\.assetDescriptor)
            + TranslationEngine.allCases.flatMap(\.assetDescriptors)
            + [appleSpeechAsset]
    }

    static func status(of asset: ModelAsset) -> AssetStatus {
        switch asset.storage {
        case .directory(let dir, let markers):
            let bytes = byteSize(of: dir)
            let complete = markers.allSatisfy {
                FileManager.default.fileExists(atPath: dir.appendingPathComponent($0).path)
            }
            return AssetStatus(asset: asset, isInstalled: complete,
                               isPartial: !complete && bytes > 0, bytesOnDisk: bytes)

        case .file(let url, let expected):
            let bytes = byteSize(of: url.deletingLastPathComponent()) > 0
                ? Int64((try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0)
                : 0
            // A GGUF that is short is a truncated download, not a model.
            let complete = bytes > 0 && Double(bytes) >= Double(expected) * 0.98
            return AssetStatus(asset: asset, isInstalled: complete,
                               isPartial: !complete && bytes > 0, bytesOnDisk: bytes)

        case .systemPath(let path):
            let bytes = byteSize(of: URL(fileURLWithPath: path))
            return AssetStatus(asset: asset, isInstalled: bytes > 0,
                               isPartial: false, bytesOnDisk: bytes)

        case .opaque:
            return AssetStatus(asset: asset, isInstalled: false, isPartial: false, bytesOnDisk: 0)
        }
    }

    static func snapshot() -> [AssetStatus] {
        assets().map(status(of:))
    }

    // MARK: - Totals

    /// Everything the app itself put on disk. Excludes Apple's assets, which we
    /// can measure but do not own.
    static func ownedTotalBytes() -> Int64 {
        byteSize(of: root)
    }

    /// Bytes under our root belonging to no known asset — an abandoned download,
    /// a stale HuggingFace cache, a directory orphaned by a repo rename. Worth
    /// showing separately rather than folding into some model's row and
    /// overstating it.
    static func strayBytes() -> Int64 {
        let known = snapshot().reduce(Int64(0)) { sum, s in
            if case .systemPath = s.asset.storage { return sum }
            if case .opaque = s.asset.storage { return sum }
            return sum + s.bytesOnDisk
        }
        return max(0, ownedTotalBytes() - known)
    }

    // MARK: - Removing

    @discardableResult
    static func remove(_ asset: ModelAsset) -> Bool {
        guard case .remove(let url) = asset.removal else { return false }
        do {
            try FileManager.default.removeItem(at: url)
            return true
        } catch {
            let e = error as NSError
            // Already gone is a success, not a failure.
            if e.domain == NSCocoaErrorDomain && e.code == NSFileNoSuchFileError { return true }
            NSLog("sAiity remove failed for \(asset.id): \(error.localizedDescription)")
            return false
        }
    }

    /// Wipe every model the app downloaded. Returns the bytes freed.
    ///
    /// Removing the whole root in one operation is what makes this leave no
    /// orphans — and it is only safe because transcripts are a sibling of this
    /// directory, never inside it. The precondition is there because a
    /// one-component slip upwards would delete every saved transcript.
    @discardableResult
    static func removeAllOwned() throws -> Int64 {
        let dir = root
        precondition(dir.lastPathComponent == "Models"
                     && dir.deletingLastPathComponent().lastPathComponent == "de.aiity.saiity",
                     "refusing to remove \(dir.path) — not the models root")
        let freed = byteSize(of: dir)
        if FileManager.default.fileExists(atPath: dir.path) {
            try FileManager.default.removeItem(at: dir)
        }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return freed
    }

    // MARK: - Apple's speech assets

    /// Measurable, never removable. `AssetInventory` exposes reserve, release
    /// and status — and no uninstall anywhere in the Speech framework. `release`
    /// frees one of the five allocation slots; it reclaims no disk.
    static let appleSpeechAsset = ModelAsset(
        id: "system.appleSpeech",
        family: .system,
        title: "Apple speech models",
        detail: "Installed and removed by macOS, roughly 350 MB per language. "
              + "No app can delete these — only System Settings can.",
        licence: "Apple system framework",
                advertisedBytes: nil,
        storage: .systemPath(
            "/System/Library/AssetsV2/com_apple_MobileAsset_UAF_Speech_AutomaticSpeechRecognition/purpose_auto"),
        removal: .systemOnly(
            reason: "The Speech framework has no uninstall API. macOS owns these files.",
            route: .storage),
        use: .never,
        install: nil)
}
