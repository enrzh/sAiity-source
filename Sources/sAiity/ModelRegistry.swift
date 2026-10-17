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
    /// A directory we own, plus the sibling directory an interrupted transfer of
    /// the same bytes is staged into.
    ///
    /// Its own case rather than an extra parameter on `directory`, because the
    /// staging bytes are the asset's: they are measured with it, deleted with
    /// it, and the row that offers to resume is describing them. WhisperKit
    /// stages per-file with resume data, so the half-downloaded directory is
    /// worth hundreds of megabytes of already-paid-for transfer.
    case stagedDirectory(final: URL, staging: URL, markers: [String])
    /// A single file. `expectedBytes` nil means the size is genuinely unknown
    /// (a pasted URL whose server sent no Content-Length); completeness then
    /// rests on the downloader's staging, which only ever creates the
    /// destination file once a transfer finished. Comparing against zero
    /// instead would make any one-byte fragment read as complete.
    case file(URL, expectedBytes: Int64?)

    /// The directory an unfinished transfer lives in, if this asset has one.
    ///
    /// Deletion has to take it with the asset: a Delete that unlinked only the
    /// installed directory would free a few megabytes of a 466 MB model, leave
    /// the rest on disk, and leave the Resume row offering to continue a
    /// transfer whose files are gone.
    var staging: URL? {
        switch self {
        case .directory, .file: nil
        case .stagedDirectory(_, let staging, _): staging
        }
    }
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
    case captionSpeakers
    case whenRecognitionEngine(ASREngine)
    /// One latency tier of the Nemotron model. Only the selected tier counts as
    /// in use — the other is just bytes that can be deleted freely.
    case whenNemotronTier(chunkMs: Int)
    /// One of the two Whisper models the dictation recognizer can load. Not
    /// caption recognition — that Whisper was cut — so this names the dictation
    /// preference and nothing else.
    case whenDictationWhisper(WhisperDictationBackend.ModelChoice)
    case whenTranslator(TranslationEngine)
    case whenQwenVariant(file: String)
    case whenCleanupModel(file: String)

    /// True when this tier is the one dictation would load, independent of the
    /// caption tier. The two are separate preferences now; a tier that only one
    /// of them names is still bytes a running dictation session is mapped to.
    ///
    /// Every clause is load-bearing. A *chosen* dictation engine is required,
    /// because `dictationEffective` answers with the recommended fallback when
    /// nothing is chosen and would badge a tier "in use" for a path that has
    /// never run; the streaming recognizer is required because a user on
    /// Whisper is not about to load Nemotron at all.
    static func isDictationTier(chunkMs: Int) -> Bool {
        ASREngine.dictationSelected == .nemotron
            && DictationRecognizer.selected == .streaming
            && NemotronEngine.dictationSelectedChunkMs == chunkMs
    }

    var isAdvanced: Bool {
        switch self {
        case .captionSpeakers: return false
        case .whenTranslator(let engine): return engine.isAdvanced
        case .whenQwenVariant: return true
        case .whenCleanupModel: return false
        case .never, .whenRecognitionEngine, .whenNemotronTier, .whenDictationWhisper: return false
        }
    }

    /// True when this asset is the one currently selected to do its job.
    var isSelected: Bool {
        switch self {
        case .captionSpeakers: return CaptionSpeakerTracker.enabled
        case .never:
            return false
        case .whenRecognitionEngine(let e):
            return ASREngine.selected == e
                || (DictationRecognizer.selected == .streaming && ASREngine.dictationSelected == e)
        case .whenNemotronTier(let ms):
            // Either surface's choice counts. Two independent preferences now
            // name a tier, and "in use" has to mean both of them: advertising
            // the fast tier as free to delete while the dictation profile is on
            // Fast is how a user deletes the model out from under themselves.
            return (ASREngine.selected == .nemotron && NemotronEngine.selectedChunkMs == ms)
                || Self.isDictationTier(chunkMs: ms)
        case .whenDictationWhisper(let choice):
            // `DictationRecognizer.selected`, not the `whisperDictationSelected`
            // flag the setter also writes. That flag is a side effect of the
            // picker and outlives a change of recognizer, so reading it badges a
            // model "in use" for a path the app is no longer on — and the two
            // disagree exactly on the fresh install, where nothing is selected.
            return DictationRecognizer.selected == .whisper
                && WhisperDictationBackend.model == choice
        case .whenTranslator(let t):
            return TranslationEngine.selected == t || TranslationEngine.dictationSelected == t
        case .whenQwenVariant(let f):
            // `selected?.file == f`, never `selected!` and never `?? ""` — with
            // nothing chosen this has to be false, not "matches the empty name".
            return TranslationEngine.selected == .qwen && LocalModel.cleanupSelected?.file == f
        case .whenCleanupModel(let f):
            return LocalModel.cleanupSelected?.file == f
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
    /// Run by `ModelRegistry.remove` before it unlinks anything, for an asset
    /// whose runtime can be resident in memory.
    ///
    /// Synchronous because removal is: Settings calls it from a button handler,
    /// and making it `async` to await an unload would have rippled through every
    /// call site. What it still has to guarantee is that no *later* caller can
    /// reach a model whose bytes are on their way out — unlinking a file a
    /// resident CoreML model still has mapped frees nothing, and would leave the
    /// app holding hundreds of megabytes of a model the user just deleted.
    var unload: (@Sendable () -> Void)? = nil
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
    /// Incomplete files belonging to retired engines. They stay out of the
    /// product catalogue, but the cleanup action must still be able to reach
    /// them without making the user remove every current model.
    let retiredPartialBytes: Int64
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
        // Translation is MADLAD-only in the product. Keep the local GGUF
        // catalogue for dictation cleanup, but do not expose retired Hy-MT2 or
        // Qwen translation downloads in the Models page.
        //
        // The Whisper models are here because the dictation recognizer really
        // does load them, and until now nothing in the registry admitted it:
        // they were measured as "other files" — the stray-bytes bucket the
        // Models page describes as leftovers — while the only controls for them
        // lived on the Dictation page. One registry means one honest number, one
        // Download that goes through the same coordinator as everything else,
        // and one Delete.
        ASREngine.allCases.flatMap(\.assetDescriptors)
            + WhisperDictationBackend.ModelChoice.allCases.flatMap(\.assetDescriptors)
            + TranslationEngine.userSelectableCases.flatMap(\.assetDescriptors)
            + TranslationEngine.qwen.assetDescriptors
            + [CaptionSpeakerTracker.asset]
    }

    /// Descriptors for weights that an older build could have downloaded. They
    /// are deliberately not part of `assets()` and never appear as selectable
    /// rows; this list exists only so an interrupted transfer can be cleaned
    /// without deleting the user's current models.
    static func retiredAssets() -> [ModelAsset] {
        ASREngine.parakeetEou.assetDescriptors + TranslationEngine.hyMT2.assetDescriptors
    }

    static func retiredPartialAssets() -> [ModelAsset] {
        retiredAssets().filter { status(of: $0).isPartial }
    }

    static func retiredPartialBytes() -> Int64 {
        retiredPartialAssets().reduce(Int64(0)) { $0 + status(of: $1).bytesOnDisk }
    }

    /// Fast readiness check for failure bookkeeping. It deliberately avoids
    /// measuring the model tree or the entire models root.
    static func isInstalled(_ asset: ModelAsset) -> Bool {
        if asset.id == AssetID.nemotron(chunkMs: 1120) {
            return NemotronEngine.isDownloaded(chunkMs: 1120)
        }
        if asset.id == AssetID.nemotron(chunkMs: NemotronEngine.chunkMs) {
            return NemotronEngine.isDownloaded(chunkMs: NemotronEngine.chunkMs)
        }
        switch asset.storage {
        case .directory(let dir, let markers), .stagedDirectory(let dir, _, let markers):
            // Only the FINAL directory decides completeness. A staging tree can
            // hold every byte of a model and still be three files short of
            // being one, and reporting that as installed is how the app loads
            // models that are not there.
            return markers.allSatisfy {
                FileManager.default.fileExists(atPath: dir.appendingPathComponent($0).path)
            }
        case .file(let url, let expected):
            let bytes = Int64((try? FileManager.default.attributesOfItem(
                atPath: url.path)[.size] as? Int) ?? 0)
            guard bytes > 0 else { return false }
            guard let expected else { return true }
            return bytes == expected
        }
    }

    static func status(of asset: ModelAsset) -> AssetStatus {
        switch asset.storage {
        case .directory(let dir, _):
            let bytes = byteSize(of: dir)
            let complete = isInstalled(asset)
            return AssetStatus(asset: asset, isInstalled: complete,
                               isPartial: !complete && bytes > 0, bytesOnDisk: bytes)

        case .stagedDirectory(let dir, let staging, _):
            // Installed bytes plus the transfer still in flight. Reporting only
            // the final directory is what made an interrupted Whisper fetch read
            // as "no model, no progress" while most of a 466 MB download sat
            // beside it — and, with nothing marked partial, no Resume control.
            let bytes = byteSize(of: dir) + byteSize(of: staging)
            let complete = isInstalled(asset)
            return AssetStatus(asset: asset, isInstalled: complete,
                               isPartial: !complete && bytes > 0, bytesOnDisk: bytes)

        case .file(let url, _):
            let fm = FileManager.default
            let bytes = Int64((try? fm.attributesOfItem(
                atPath: url.path)[.size] as? Int) ?? 0)
            let complete = isInstalled(asset)
            // Resume state counts. FileDownloader now keeps `<file>.part` and
            // its validator across a cancel or a quit, deliberately — but a
            // row that says "not downloaded" while gigabytes sit beside it is
            // the same dishonesty this page was built to end. Reported as a
            // partial, which is exactly what it is, and what gives the row
            // its Resume/Remove controls.
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
        let retiredPartials = retiredPartialAssets().map(status(of:))
        let owned = byteSize(of: root)
        let known = statuses.reduce(Int64(0)) { $0 + $1.bytesOnDisk }
            + retiredPartials.reduce(Int64(0)) { $0 + $1.bytesOnDisk }
        let retiredBytes = retiredPartials.reduce(Int64(0)) { $0 + $1.bytesOnDisk }
        return ModelInventory(assets: statuses,
                              ownedBytes: owned,
                              strayBytes: max(0, owned - known),
                              retiredPartialBytes: retiredBytes)
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
        // First, and for the reason on `ModelAsset.unload`: unlinking a file a
        // resident CoreML model still has mapped frees nothing, and leaves the
        // app holding hundreds of megabytes of a model the user just deleted.
        asset.unload?()
        // Whatever damage was recorded belonged to the files now leaving.
        LoadHealth.clear(asset.id)
        // Resume state goes with the asset it belongs to. Deleting a model
        // and leaving a multi-gigabyte `.part` behind — invisible to every
        // per-asset control, swept by nothing since sweepPartials now
        // deliberately preserves validator-backed partials — is a leak the
        // user has no way to find.
        try? FileManager.default.removeItem(at: url.appendingPathExtension("part"))
        try? FileManager.default.removeItem(at: url.appendingPathExtension("part.etag"))
        // The same argument for a directory asset, whose staging directory is a
        // sibling rather than an extension of its path.
        if let staging = asset.storage.staging {
            try? FileManager.default.removeItem(at: staging)
        }
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
