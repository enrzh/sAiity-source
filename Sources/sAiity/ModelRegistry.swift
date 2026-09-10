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

/// How an asset's bytes are laid out, and how "finished" is told from "started".
enum AssetStorage: Sendable {
    /// A directory we own. `markers` are paths relative to it that must ALL be
    /// present for the download to count as complete. Anything less is a
    /// partial download — which is a third state, not a synonym for missing.
    case directory(URL, markers: [String])
    /// A single file. `expectedBytes` nil means the size is genuinely unknown
    /// (a pasted URL whose server sent no Content-Length); completeness then
    /// rests on the downloader's staging, which only ever creates the
    /// destination file once a transfer finished. Comparing against zero
    /// instead would make any one-byte fragment read as complete.
    case file(URL, expectedBytes: Int64?)
}

/// What removing an asset actually means.
///
/// A closed enum rather than a `canDelete: Bool`, because two of these assets
/// genuinely cannot be removed by any app — the Speech and Translation
/// frameworks expose no uninstall API. Modelling that as a Bool is how the UI
/// ended up with a Delete button wired to a guard that could never pass.
enum AssetRemoval: Sendable {
    case remove(URL)
}

/// When deleting would pull the rug out from under a running session.
enum AssetUse: Sendable {
    case never
    case whenRecognitionEngine(ASREngine)
    /// One latency tier of the Nemotron model. Only the selected tier counts as
    /// in use — the other is just bytes that can be deleted freely.
    case whenNemotronTier(chunkMs: Int)
    case whenTranslator(TranslationEngine)
    case whenQwenVariant(file: String)
    case whenCleanupModel(file: String)

    var isAdvanced: Bool {
        switch self {
        case .whenTranslator(let engine): return engine.isAdvanced
        case .whenQwenVariant: return true
        case .whenCleanupModel: return false
        case .never, .whenRecognitionEngine, .whenNemotronTier: return false
        }
    }

    /// True when this asset is the one currently selected to do its job.
    var isSelected: Bool {
        switch self {
        case .never:
            return false
        case .whenRecognitionEngine(let e):
            return ASREngine.selected == e
        case .whenNemotronTier(let ms):
            return ASREngine.selected == .nemotron && NemotronEngine.selectedChunkMs == ms
        case .whenTranslator(let t):
            return TranslationEngine.selected == t
        case .whenQwenVariant(let f):
            // `selected?.file == f`, never `selected!` and never `?? ""` — with
            // nothing chosen this has to be false, not "matches the empty name".
            return TranslationEngine.selected == .qwen && LocalModel.selected?.file == f
        case .whenCleanupModel(let f):
            return LocalModel.selected?.file == f
        }
    }
}

/// One downloadable thing, described once so every surface agrees about it.
struct ModelAsset: Identifiable, Sendable {
    enum Family: Int, Sendable, Comparable {
        case recognition, translation, cleanup
        static func < (a: Family, b: Family) -> Bool { a.rawValue < b.rawValue }
    }

    let id: String
    let family: Family
    let title: String
    let detail: String
    /// Worth downloading first, of the options in this family.
    ///
    /// The Models page is the only surface that lists everything together with
    /// its price and a Download button — it is where "which of these do I
    /// want?" is actually decided, and it had nothing to say. No default value:
    /// a new descriptor has to answer.
    let recommended: Bool
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

    var isAdvanced: Bool { use.isAdvanced }
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

/// One coherent filesystem read used by the model settings page. Keeping the
/// totals beside the per-asset statuses prevents three independent directory
/// scans from disagreeing during a download.
struct ModelInventory: Sendable {
    let assets: [AssetStatus]
    let ownedBytes: Int64
    let strayBytes: Int64
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

    /// Returns the capacity macOS considers safe for an important write. The
    /// model root may not exist yet on a fresh install, so ask its parent
    /// volume through the root URL rather than requiring the directory first.
    static func availableDiskBytes(at url: URL = root) -> Int64? {
        let keys: Set<URLResourceKey> = [
            .volumeAvailableCapacityForImportantUsageKey,
            .volumeAvailableCapacityKey,
        ]
        guard let values = try? url.resourceValues(forKeys: keys) else { return nil }
        return values.volumeAvailableCapacityForImportantUsage
            ?? values.volumeAvailableCapacity.map(Int64.init)
    }

    // MARK: - The catalogue

    static func assets() -> [ModelAsset] {
        ASREngine.allCases.flatMap(\.assetDescriptors)
            + TranslationEngine.allCases.flatMap(\.assetDescriptors)
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
            let fm = FileManager.default
            let bytes = Int64((try? fm.attributesOfItem(
                atPath: url.path)[.size] as? Int) ?? 0)
            // A GGUF that is short is a truncated download, not a model. With
            // no expected size, presence is the signal — see the case comment.
            let complete: Bool
            if let expected {
                complete = bytes > 0 && Double(bytes) >= Double(expected) * 0.98
            } else {
                complete = bytes > 0
            }
            // Resume state counts. FileDownloader now keeps `<file>.part` and
            // its validator across a cancel or a quit, deliberately — but a
            // row that says "not downloaded" while gigabytes sit beside it is
            // the same dishonesty this page was built to end. Reported as a
            // partial, which is exactly what it is, and what gives the row
            // its Remove button.
            let partBytes = Int64((try? fm.attributesOfItem(
                atPath: url.appendingPathExtension("part").path)[.size] as? Int) ?? 0)
            if !complete, partBytes > 0 {
                return AssetStatus(asset: asset, isInstalled: false,
                                   isPartial: true, bytesOnDisk: bytes + partBytes)
            }
            return AssetStatus(asset: asset, isInstalled: complete,
                               isPartial: !complete && bytes > 0, bytesOnDisk: bytes)

        }
    }

    static func snapshot() -> [AssetStatus] {
        inventorySnapshot().assets
    }

    static func inventorySnapshot() -> ModelInventory {
        let statuses = assets().map(status(of:))
        let owned = byteSize(of: root)
        let known = statuses.reduce(Int64(0)) { $0 + $1.bytesOnDisk }
        return ModelInventory(assets: statuses,
                              ownedBytes: owned,
                              strayBytes: max(0, owned - known))
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
        inventorySnapshot().strayBytes
    }

    // MARK: - Removing

    @discardableResult
    static func remove(_ asset: ModelAsset) -> Bool {
        guard case .remove(let url) = asset.removal else { return false }
        // Whatever damage was recorded belonged to the files now leaving.
        LoadHealth.clear(asset.id)
        // Resume state goes with the asset it belongs to. Deleting a model
        // and leaving a multi-gigabyte `.part` behind — invisible to every
        // per-asset control, swept by nothing since sweepPartials now
        // deliberately preserves validator-backed partials — is a leak the
        // user has no way to find.
        try? FileManager.default.removeItem(at: url.appendingPathExtension("part"))
        try? FileManager.default.removeItem(at: url.appendingPathExtension("part.etag"))
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

}
