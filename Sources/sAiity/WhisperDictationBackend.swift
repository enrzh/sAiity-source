import Foundation
import WhisperKit

enum WhisperDictationError: Error, Equatable { case unsupportedLocale(String) }

protocol WhisperModelResource: Sendable {
    func unload() async
}

/// Keeps one loaded native model resident for a short idle window.
///
/// The cache owns the resource and leases it for the duration of each native
/// operation. This prevents the idle task from unloading a model while a
/// decode is still running, while the caller's per-model mutex continues to
/// enforce the single-inference invariant.
actor WhisperModelCache<Key: Hashable & Sendable, Resource: WhisperModelResource> {
    typealias Loader = @Sendable (Key) async throws -> Resource

    private struct Entry {
        let resource: Resource
        var leases: Set<Int> = []
        var evictionToken = UUID()
        var invalidated = false
    }

    /// A single borrow of a resident model.
    ///
    /// The id is what makes releasing correct when the key has been taken over
    /// by a newer load in the meantime: a release carries its own id, so it is
    /// routed to whichever record is actually holding it instead of
    /// decrementing whatever happens to be filed under the key by then.
    private struct Lease {
        let id: Int
        let resource: Resource
    }

    private enum LeaseHome {
        case entry(Key)
        case orphan(Int)
    }

    /// A resource that a load displaced from `entries` while it was still
    /// borrowed.
    ///
    /// `invalidated` is a promise about the *resource* — it will be unloaded
    /// exactly once — not about the key it happened to be filed under. A load
    /// that races an invalidation is entitled to take the key, so the promise
    /// needs somewhere to live that a key can be taken over without losing it.
    /// Before this, the displaced entry was dropped from the map, and whoever
    /// still held it released against the *new* entry instead — so the old
    /// model was never unloaded at all.
    private struct Orphan {
        let resource: Resource
        var leases: Set<Int>
        var invalidated: Bool
    }

    private let idleDuration: Duration
    private let loader: Loader
    private var entries: [Key: Entry] = [:]
    private var evictionTasks: [Key: Task<Void, Never>] = [:]
    private var orphans: [Int: Orphan] = [:]
    private var leaseHome: [Int: LeaseHome] = [:]
    private var nextLeaseID = 0
    private var nextOrphanID = 0

    init(idleDuration: Duration = .seconds(45), loader: @escaping Loader) {
        self.idleDuration = idleDuration
        self.loader = loader
    }

    func withModel<T: Sendable>(for key: Key,
                                operation: @escaping @Sendable (Resource) async throws -> T) async throws -> T {
        let lease = try await acquire(key)
        do {
            let value = try await operation(lease.resource)
            await release(lease)
            return value
        } catch {
            await release(lease)
            throw error
        }
    }

    func invalidate(_ key: Key) async {
        evictionTasks.removeValue(forKey: key)?.cancel()
        guard var entry = entries[key] else { return }
        if !entry.leases.isEmpty {
            entry.invalidated = true
            entries[key] = entry
            return
        }
        entries.removeValue(forKey: key)
        await entry.resource.unload()
    }

    /// `invalidate` without the await, for callers that cannot suspend — a
    /// synchronous file removal, for instance.
    ///
    /// Same guarantee: an entry with active users is flagged so the last
    /// `release` unloads it, and an idle one is unloaded on the cache actor
    /// while the caller carries on. Nothing is left mapped that a new caller
    /// could reach.
    func forget(_ key: Key) {
        evictionTasks.removeValue(forKey: key)?.cancel()
        guard var entry = entries[key] else { return }
        if !entry.leases.isEmpty {
            entry.invalidated = true
            entries[key] = entry
            return
        }
        entries.removeValue(forKey: key)
        let resource = entry.resource
        Task { await resource.unload() }
    }

#if SAIITY_TEST_HOOKS
    /// Every loaded model the cache is still responsible for, including ones
    /// displaced from the key map by a racing load. Counting only `entries`
    /// would report zero while a model was still resident and owed an unload.
    var residentCountForTests: Int { entries.count + orphans.count }
#endif

    private func acquire(_ key: Key) async throws -> Lease {
        if var entry = entries[key], !entry.invalidated {
            let lease = Lease(id: nextLeaseID, resource: entry.resource)
            nextLeaseID += 1
            leaseHome[lease.id] = .entry(key)
            entry.leases.insert(lease.id)
            entries[key] = entry
            scheduleEviction(for: key, token: entry.evictionToken)
            return lease
        }

        let resource = try await loader(key)
        do {
            try Task.checkCancellation()
        } catch {
            await resource.unload()
            throw error
        }

        // A caller can invalidate while the loader is suspended. Reuse the
        // existing resident resource and release the duplicate immediately.
        if var existing = entries[key], !existing.invalidated {
            await resource.unload()
            let lease = Lease(id: nextLeaseID, resource: existing.resource)
            nextLeaseID += 1
            leaseHome[lease.id] = .entry(key)
            existing.leases.insert(lease.id)
            entries[key] = existing
            scheduleEviction(for: key, token: existing.evictionToken)
            return lease
        }

        // The key is ours, but whatever was filed under it may still be
        // borrowed. Settle its debts before dropping it, or the model behind
        // them is never unloaded.
        if let displaced = entries[key] {
            if displaced.leases.isEmpty {
                if displaced.invalidated { await displaced.resource.unload() }
            } else {
                nextOrphanID += 1
                orphans[nextOrphanID] = Orphan(resource: displaced.resource,
                                              leases: displaced.leases,
                                              invalidated: displaced.invalidated)
                for id in displaced.leases { leaseHome[id] = .orphan(nextOrphanID) }
            }
        }

        var entry = Entry(resource: resource)
        let lease = Lease(id: nextLeaseID, resource: resource)
        nextLeaseID += 1
        leaseHome[lease.id] = .entry(key)
        entry.leases.insert(lease.id)
        entries[key] = entry
        scheduleEviction(for: key, token: entry.evictionToken)
        return lease
    }

    private func release(_ lease: Lease) async {
        switch leaseHome.removeValue(forKey: lease.id) {
        case .orphan(let id):
            guard var orphan = orphans[id] else { return }
            orphan.leases.remove(lease.id)
            guard orphan.leases.isEmpty else {
                orphans[id] = orphan
                return
            }
            orphans.removeValue(forKey: id)
            if orphan.invalidated { await orphan.resource.unload() }
        case .entry(let key):
            guard var entry = entries[key] else { return }
            entry.leases.remove(lease.id)
            guard entry.leases.isEmpty else {
                entries[key] = entry
                return
            }
            if entry.invalidated {
                entries.removeValue(forKey: key)
                evictionTasks.removeValue(forKey: key)?.cancel()
                await entry.resource.unload()
                return
            }
            entry.evictionToken = UUID()
            entries[key] = entry
            scheduleEviction(for: key, token: entry.evictionToken)
        case nil:
            return
        }
    }

    private func scheduleEviction(for key: Key, token: UUID) {
        evictionTasks.removeValue(forKey: key)?.cancel()
        let delay = idleDuration
        evictionTasks[key] = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            await self?.evictIfIdle(key, token: token)
        }
    }

    private func evictIfIdle(_ key: Key, token: UUID) async {
        guard let entry = entries[key],
              entry.evictionToken == token,
              entry.leases.isEmpty,
              !entry.invalidated else { return }
        entries.removeValue(forKey: key)
        evictionTasks.removeValue(forKey: key)
        await entry.resource.unload()
    }
}

struct WhisperModelCacheKey: Hashable, Sendable {
    let identifier: String
    let folderPath: String
}

actor LoadedWhisperDictationModel: WhisperModelResource {
    private let whisper: WhisperKit

    static func transcription(from results: [Result<[TranscriptionResult], Error>]) throws
        -> (text: String, language: String?) {
        let decoded = try results.flatMap { try $0.get() }
        return (decoded.map(\.text).joined(separator: " "), decoded.first?.language)
    }

    init(identifier: String, folder: URL) async throws {
        let model = try await WhisperKit(model: identifier,
                                         modelRepo: nil,
                                         modelFolder: folder.path,
                                         prewarm: false,
                                         load: false,
                                         download: false)
        do {
            try await model.setupModels(model: identifier,
                                        modelRepo: nil,
                                        modelFolder: folder.path,
                                        download: false)
            try await LocalGeneration.loadModel { try await model.loadModels(prewarmMode: true) }
        } catch {
            await model.unloadModels()
            throw error
        }
        whisper = model
    }

    func transcribe(_ samples: [Float],
                    options: DecodingOptions) async throws -> (text: String, language: String?) {
        try await transcribe([samples], options: options)
    }

    func transcribe(_ samples: [[Float]],
                    options: DecodingOptions) async throws -> (text: String, language: String?) {
        try Task.checkCancellation()
        let decoding = ContinuousClock.now
        let results = await whisper.transcribeWithResults(audioArrays: samples,
                                                          decodeOptions: options,
                                                          callback: nil)
        await LocalGeneration.recordModelTiming("model.recognition", since: decoding, cold: false, calls: 1)
        try Task.checkCancellation()
        return try Self.transcription(from: results)
    }

    func unload() async {
        await whisper.unloadModels()
    }
}

struct WhisperDictationBackend {
    enum ModelChoice: String, CaseIterable, Equatable, Sendable {
        case base, small
        var identifier: String { "openai_whisper-\(rawValue)" }
        var description: String { rawValue }
        var folderName: String { "whisper-\(identifier)" }
        var readinessMarkerName: String { ".saiity-ready" }
        /// The same two words the dictation picker shows, from the catalog.
        var displayName: String {
            switch self {
            case .base: String(localized: "Base")
            case .small: String(localized: "Small")
            }
        }
        /// Approximate download size, for the Models page. The measured figure
        /// replaces it the moment the bytes are on disk; this only ever
        /// previews the cost of pressing Download.
        var advertisedBytes: Int64 {
            switch self {
            case .base: 145 * 1_048_576
            case .small: 466 * 1_048_576
            }
        }
    }
    typealias Download = @Sendable (String, URL, @escaping @Sendable (Progress) -> Void) async throws -> URL
    typealias Prepare = @Sendable (String, URL) async throws -> Void
    typealias Transcription = @Sendable (String, URL, [[Float]], DecodingOptions) async throws -> String
    typealias SegmentTranscription = @Sendable (String, URL, [Float], DecodingOptions) async throws -> DictationRegionTranscript
    private let root: URL; private let download: Download; private let prepare: Prepare; private let transcribeHook: Transcription; private let segmentTranscribeHook: SegmentTranscription?
    private static let mutexes = MutexRegistry()
    private static let modelCache = WhisperModelCache<WhisperModelCacheKey, LoadedWhisperDictationModel>(idleDuration: .seconds(300)) { key in
        try await LoadedWhisperDictationModel(identifier: key.identifier,
                                              folder: URL(fileURLWithPath: key.folderPath))
    }
#if SAIITY_TEST_HOOKS
    static var testAfterEnqueue: (@Sendable () async -> Void)? {
        get { FIFOAsyncMutex.testAfterEnqueue }
        set { FIFOAsyncMutex.testAfterEnqueue = newValue }
    }
    static var testAfterAcquire: (@Sendable () async -> Void)? {
        get { FIFOAsyncMutex.testAfterAcquire }
        set { FIFOAsyncMutex.testAfterAcquire = newValue }
    }
#endif
    init(root: URL = ModelRegistry.root,
         download: @escaping Download = WhisperDictationBackend.realDownload,
         prepare: @escaping Prepare = WhisperDictationBackend.realPrepare,
         transcribe: @escaping Transcription = WhisperDictationBackend.realTranscribe,
         segmentTranscribe: SegmentTranscription? = nil) {
        self.root = root
        self.download = download
        self.prepare = prepare
        self.transcribeHook = transcribe
        self.segmentTranscribeHook = segmentTranscribe
    }
    /// Recognition tokens from the pinned WhisperKit vocabulary, not translation targets.
    static let supportedLanguageCodes = Constants.languageCodes
    @Defaults(rawKey: "whisperDictationModel") static var model = ModelChoice.base
    static var isSelected: Bool {
        get { UserDefaults.standard.bool(forKey: "whisperDictationSelected") }
        set { UserDefaults.standard.set(newValue, forKey: "whisperDictationSelected") }
    }
    static var locale: String {
        get { let stored = UserDefaults.standard.string(forKey: "whisperDictationLocale") ?? "auto"; let value = canonicalLocale(stored); if value != stored { UserDefaults.standard.set(value, forKey: "whisperDictationLocale") }; return value }
        set { UserDefaults.standard.set(canonicalLocale(newValue), forKey: "whisperDictationLocale") }
    }
    /// Preserve ICU's regional/script aliases while returning a model-native token.
    static func sourceLanguageCode(for identifier: String) -> String? {
        let canonical = Locale(identifier: identifier).identifier(.bcp47)
        let base = canonical.split(separator: "-").first.map(String.init) ?? canonical
        let native = ["fil": "tl", "nb": "no", "jv": "jw"][base] ?? base
        return supportedLanguageCodes.contains(native) ? native : nil
    }

    private static func canonicalLocale(_ id: String) -> String {
        guard id != "auto" else { return id }
        return sourceLanguageCode(for: id) != nil ? Locale(identifier: id).identifier(.bcp47) : "auto"
    }

    static func decodingOptions(for locale: Locale) throws -> DecodingOptions {
        if locale.identifier == "auto" { return DecodingOptions(language: nil, detectLanguage: true) }
        guard let code = sourceLanguageCode(for: locale.identifier) else {
            throw WhisperDictationError.unsupportedLocale(locale.identifier)
        }
        return DecodingOptions(language: code, detectLanguage: false)
    }
    static func transcribe(locale: Locale, using body: () throws -> Void) throws { _ = try decodingOptions(for: locale); try body() }
    private static func folder(_ c: ModelChoice, _ root: URL) -> URL { root.appendingPathComponent(c.folderName, isDirectory: true) }
    private static func required(_ c: ModelChoice, _ root: URL) -> Bool {
        let f = folder(c, root)
        return ModelChoice.requiredBundles.allSatisfy { name in
            let url = f.appendingPathComponent(name)
            guard let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]),
                  values.isDirectory == true, values.isSymbolicLink != true else { return false }
            guard let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]) else { return false }
            return enumerator.contains { item in
                guard let itemURL = item as? URL,
                      let values = try? itemURL.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]) else { return false }
                return values.isRegularFile == true && values.isSymbolicLink != true && (values.fileSize ?? 0) > 0
            }
        }
    }
    static func modelFolder(for c: ModelChoice, under root: URL = ModelRegistry.root) -> URL { folder(c, root) }

    /// Where an interrupted transfer of this model's bytes lives.
    ///
    /// A sibling of the model directory with its own extension, so it can never
    /// be confused for an install: the registry measures it as staging, and
    /// `prepareModelUnlocked` hands it to the downloader as the cache root.
    static func stagingDirectory(for c: ModelChoice, under root: URL = ModelRegistry.root) -> URL {
        root.appendingPathComponent("\(c.folderName).partial", isDirectory: true)
    }

    /// The bytes are complete on disk, whether or not they have ever been
    /// loaded. Deliberately weaker than `isReady`, which also requires the
    /// marker written after a successful load: the Models page's Download
    /// fetches without loading — a 466 MB load is not what a Download button is
    /// for — so requiring the marker there would report a finished download as
    /// partial and offer Resume against bytes that are already complete.
    static func isDownloaded(_ c: ModelChoice, under root: URL = ModelRegistry.root) -> Bool {
        required(c, root)
    }

    static func isReady(_ c: ModelChoice, under root: URL = ModelRegistry.root) -> Bool {
        let modelFolder = folder(c, root)
        // The marker is the cheap, authoritative readiness signal. Checking it
        // first avoids enumerating three CoreML directories on every render
        // when the model has not been downloaded yet.
        guard FileManager.default.fileExists(atPath: modelFolder.appendingPathComponent(c.readinessMarkerName).path) else {
            return false
        }
        return required(c, root)
    }
    func prepareModel(_ c: ModelChoice, under root: URL? = nil, progress: @escaping @Sendable (Progress) -> Void = { _ in }) async throws { let root = root ?? self.root; let mutex = await Self.mutexes.mutex(for: "\(root.path):\(c.identifier)"); return try await mutex.run { try await self.prepareModelUnlocked(c, root, progress) } }
    func prepareModelForUse(_ c: ModelChoice, under root: URL? = nil, progress: @escaping @Sendable (Progress) -> Void = { _ in }) async throws {
        let root = root ?? self.root
        let mutex = await Self.mutexes.mutex(for: "\(root.path):\(c.identifier)")
        try await mutex.run {
            do {
                try await self.prepareModelUnlocked(c, root, progress)
                let folder = Self.folder(c, root)
                try Task.checkCancellation()
                try await self.prepare(c.identifier, folder)
                try Task.checkCancellation()
                try Data().write(to: folder.appendingPathComponent(c.readinessMarkerName), options: .atomic)
            } catch is CancellationError {
                // Only the loaded runtime goes. The model files and the
                // staging directory both stay: a cancelled preparation is the
                // user changing their mind, not evidence that the bytes on disk
                // are bad, and the staging directory is what makes the next
                // attempt cheap.
                await Self.modelCache.invalidate(Self.cacheKey(c, root))
                throw CancellationError()
            } catch {
                // A model that does not load is presumed damaged, so its files
                // go and the next attempt fetches them again — and does so
                // cheaply, because the staging directory survived. The
                // readiness marker goes with them: leaving it behind would let
                // `isReady` answer from a marker for bytes that are no longer
                // there.
                await Self.modelCache.invalidate(Self.cacheKey(c, root))
                try? FileManager.default.removeItem(at: Self.folder(c, root).appendingPathComponent(c.readinessMarkerName))
                try? FileManager.default.removeItem(at: Self.folder(c, root))
                throw error
            }
        }
    }
    private func prepareModelUnlocked(_ c: ModelChoice, _ root: URL, _ progress: @escaping @Sendable (Progress) -> Void) async throws {
        // `isDownloaded`, not `isReady`: the readiness marker is only written
        // after a successful load, and a model that was downloaded and never
        // loaded is not a model worth fetching again.
        if Self.isDownloaded(c, under: root) { return }
        let staging = Self.stagingDirectory(for: c, under: root)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        // The staging directory is deliberately left alone by every exit path
        // here. It is the resume state: WhisperKit's Hub downloader writes each
        // file to `<file>.incomplete` and moves it into place on completion, so
        // a directory that already holds half a model is the cheapest possible
        // starting point for the next attempt. Deleting it made every cancelled
        // 466 MB fetch cost another 466 MB, and made the Models page's "Resume
        // continues where it stopped" a lie — the only thing it resumed was the
        // empty directory.
        let downloaded = try await self.download(c.identifier, staging, progress)
        try Task.checkCancellation()
        try Self.install(downloaded, c, root)
    }

    /// Move a finished download into place without ever leaving the model
    /// missing.
    ///
    /// The previous version deleted the model directory and *then* moved the
    /// new one in. Anything that failed in between — a full disk, a permission
    /// change, a cancellation delivered at the move — left the user with no
    /// model at all, having paid for the transfer. Instead the old directory is
    /// renamed out of the way first and renamed back if the new one cannot go
    /// in, so the worst case is "nothing changed".
    private static func install(_ downloaded: URL, _ c: ModelChoice, _ root: URL) throws {
        let fm = FileManager.default
        let final = folder(c, root)
        let superseded = root.appendingPathComponent("\(c.folderName).superseded", isDirectory: true)
        try? fm.removeItem(at: superseded)
        let hadPrevious = fm.fileExists(atPath: final.path)
        if hadPrevious { try fm.moveItem(at: final, to: superseded) }
        do {
            try fm.moveItem(at: downloaded, to: final)
        } catch {
            if hadPrevious { try? fm.moveItem(at: superseded, to: final) }
            throw error
        }
        // The staging directory only outlives a successful install when the
        // downloader put the model somewhere else under it (its Hub cache
        // bookkeeping lives in `.cache`). Reclaim it either way.
        try? fm.removeItem(at: stagingDirectory(for: c, under: root))
        try? fm.removeItem(at: superseded)
    }
    func removeModel(_ c: ModelChoice, under root: URL? = nil) async throws {
        let root = root ?? self.root
        let mutex = await Self.mutexes.mutex(for: "\(root.path):\(c.identifier)")
        try await mutex.run {
            await Self.modelCache.invalidate(Self.cacheKey(c, root))
            // Damage recorded against these bytes described these bytes.
            // Left behind, it would badge a model the user has just deleted —
            // or one they re-fetched from the dictation page, which does not go
            // through the registry's clear-on-success — as damaged forever.
            LoadHealth.clear(AssetID.whisper(c))
            for url in [Self.folder(c, root),
                        Self.stagingDirectory(for: c, under: root),
                        root.appendingPathComponent("\(c.folderName).superseded", isDirectory: true)] {
                do {
                    try FileManager.default.removeItem(at: url)
                } catch let error as CocoaError where error.code == .fileNoSuchFile {
                    continue
                }
            }
        }
    }

    /// Drop a loaded model without waiting for the unload.
    ///
    /// `ModelRegistry.remove` is synchronous — it has to be, because Settings
    /// calls it from a button handler — and unloading CoreML models is not.
    /// Awaiting here would mean leaving bytes mapped under a file the caller
    /// has just deleted, so this forgets the entry and releases the resource on
    /// the cache actor instead. A dictation already holding a lease keeps its
    /// own reference and finishes; nothing new can pick the entry up.
    static func forgetLoadedModel(_ c: ModelChoice, under root: URL = ModelRegistry.root) {
        Task { await modelCache.forget(cacheKey(c, root)) }
    }
    func transcribe(samples: [[Float]], locale: Locale, model c: ModelChoice = model) async throws -> String { let o = try Self.decodingOptions(for: locale); let mutex = await Self.mutexes.mutex(for: "\(root.path):\(c.identifier)"); return try await mutex.run { try await self.transcribeHook(c.identifier, Self.folder(c, self.root), samples, o) } }

    /// Authoritative Auto-mode transcription for one press-to-talk recording.
    /// WhisperKit is loaded once for the whole call; only the decoder state is
    /// reused between sequential region decodes.
    func transcribeDictation(samples: [Float],
                             regions: [DictationSpeechRegion],
                             locale: Locale,
                             model c: ModelChoice = model) async throws -> DictationTranscriptionResult {
        let options = try Self.decodingOptions(for: locale)
        guard !samples.isEmpty, !regions.isEmpty else {
            return DictationTranscriptionResult(regions: [])
        }
        let mutex = await Self.mutexes.mutex(for: "\(root.path):\(c.identifier)")
        return try await mutex.run {
            if let segmentTranscribeHook {
                var transcripts: [DictationRegionTranscript] = []
                var previousTranscriptEnd = 0
                for region in regions {
                    try Task.checkCancellation()
                    let audio = Array(samples[region.audioRange])
                    guard !audio.isEmpty else { continue }
                    let decoded = try await segmentTranscribeHook(c.identifier,
                                                                  Self.folder(c, self.root),
                                                                  audio,
                                                                  options)
                    let text = decoded.text.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !text.isEmpty {
                        transcripts.append(DictationRegionTranscript(text: text,
                                                                     language: decoded.language,
                                                                     overlapsPreviousAudio: previousTranscriptEnd > region.audioRange.lowerBound))
                        previousTranscriptEnd = region.audioRange.upperBound
                    }
                }
                return DictationTranscriptionResult(regions: transcripts)
            }

            return try await Self.modelCache.withModel(for: Self.cacheKey(c, self.root)) { loaded in
                var transcripts: [DictationRegionTranscript] = []
                var previousTranscriptEnd = 0
                for region in regions {
                    try Task.checkCancellation()
                    let audio = Array(samples[region.audioRange])
                    guard !audio.isEmpty else { continue }
                    let decoded = try await loaded.transcribe(audio, options: options)
                    let text = decoded.text.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !text.isEmpty {
                        transcripts.append(DictationRegionTranscript(text: text,
                                                                     language: decoded.language,
                                                                     overlapsPreviousAudio: previousTranscriptEnd > region.audioRange.lowerBound))
                        previousTranscriptEnd = region.audioRange.upperBound
                    }
                }
                return DictationTranscriptionResult(regions: transcripts)
            }
        }
    }
    private static let realDownload: Download = { id, d, p in
        try await WhisperKit.download(variant: id,
                                      downloadBase: d,
                                      useBackgroundSession: false,
                                      from: "argmaxinc/whisperkit-coreml",
                                      token: nil,
                                      endpoint: Constants.defaultRemoteEndpoint,
                                      progressCallback: p)
    }
    private static let realPrepare: Prepare = { id, f in
        let key = WhisperModelCacheKey(identifier: id, folderPath: f.path)
        try await Self.modelCache.withModel(for: key) { _ in () }
    }
    private static let realTranscribe: Transcription = { id, f, s, o in
        let key = WhisperModelCacheKey(identifier: id, folderPath: f.path)
        return try await Self.modelCache.withModel(for: key) { loaded in
            let result = try await loaded.transcribe(s, options: o)
            return result.text
        }
    }

    private static func cacheKey(_ c: ModelChoice, _ root: URL) -> WhisperModelCacheKey {
        WhisperModelCacheKey(identifier: c.identifier, folderPath: folder(c, root).path)
    }
}

extension WhisperDictationBackend.ModelChoice {
    /// The three CoreML bundles a WhisperKit model is made of. One list, so the
    /// registry's completion markers and the engine's own completeness check
    /// cannot disagree about what a model is.
    static let requiredBundles = [
        "MelSpectrogram.mlmodelc", "AudioEncoder.mlmodelc", "TextDecoder.mlmodelc",
    ]

    /// This model's row in the model registry.
    ///
    /// `recommended: false` deliberately. Whisper is the *dictation*
    /// recognizer's alternative, not a better caption engine — the caption
    /// Whisper was cut, and the Models page sorts recommended rows to the top of
    /// each group, so claiming it would put a 466 MB dictation model above the
    /// balanced Nemotron tier that is the right first download for captions.
    var assetDescriptors: [ModelAsset] {
        [ModelAsset(
            id: AssetID.whisper(self),
            family: .recognition,
            // Composed from two existing catalog keys rather than one new one:
            // the catalogue is maintained by hand, and a key added here would
            // arrive untranslated in four languages. The interpolated form is
            // also how it has to be written — `String(localized:)` takes no
            // arguments after the key, so the placeholders have to be inside it
            // for the extractor to find the "%@ · %@" entry.
            title: String(localized: "\(String(localized: "Whisper model")) · \(displayName)"),
            detail: String(localized: "Whisper dictation"),
            recommended: false,
            licence: "MIT · huggingface.co/argmaxinc/whisperkit-coreml",
            advertisedBytes: advertisedBytes,
            storage: .stagedDirectory(final: WhisperDictationBackend.modelFolder(for: self),
                                      staging: WhisperDictationBackend.stagingDirectory(for: self),
                                      markers: Self.requiredBundles),
            removal: .remove(WhisperDictationBackend.modelFolder(for: self)),
            use: .whenDictationWhisper(self),
            // Through the backend, not around it: `prepareModel` holds the same
            // per-model mutex the dictation path uses, so a Download here
            // cannot end up writing into the staging directory beside a
            // preparation the app is already running. It fetches without
            // loading, like every other Download button — the dictation page is
            // where the model is warmed.
            install: { sink in
                try await WhisperDictationBackend().prepareModel(self) { progress in
                    sink(DownloadProgress(
                        fraction: progress.fractionCompleted,
                        note: String(localized: "Downloading \(displayName)…")))
                }
            },
            unload: { WhisperDictationBackend.forgetLoadedModel(self) })]
    }
}
private actor FIFOAsyncMutex {
#if SAIITY_TEST_HOOKS
    nonisolated(unsafe) static var testAfterEnqueue: (@Sendable () async -> Void)?
    nonisolated(unsafe) static var testAfterAcquire: (@Sendable () async -> Void)?
#endif
    private var locked = false
    private var waiters: [UUID: CheckedContinuation<Void, Error>] = [:]
    private var order: [UUID] = []

    // Same-key nested run is intentionally unsupported; no production path needs reentrancy.
    func run<T: Sendable>(_ operation: @Sendable () async throws -> T) async throws -> T {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await acquire(id: id)
        } onCancel: {
            Task { await self.cancel(id: id) }
        }
        defer { release() }
#if SAIITY_TEST_HOOKS
        await Self.testAfterAcquire?()
#endif
        try Task.checkCancellation()
        return try await operation()
    }

    private func acquire(id: UUID) async throws {
        try Task.checkCancellation()
        if !locked {
            locked = true
            return
        }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            if Task.isCancelled {
                continuation.resume(throwing: CancellationError())
                return
            }
            waiters[id] = continuation
            order.append(id)
#if SAIITY_TEST_HOOKS
            Task { await Self.testAfterEnqueue?() }
#endif
        }
    }

    private func cancel(id: UUID) {
        guard let waiter = waiters.removeValue(forKey: id) else { return }
        order.removeAll { $0 == id }
        waiter.resume(throwing: CancellationError())
    }

    private func release() {
        while let id = order.first {
            order.removeFirst()
            if let next = waiters.removeValue(forKey: id) {
                next.resume()
                return
            }
        }
        locked = false
    }
}

private actor MutexRegistry {
    private var mutexes: [String: FIFOAsyncMutex] = [:]

    func mutex(for key: String) -> FIFOAsyncMutex {
        if let mutex = mutexes[key] { return mutex }
        let mutex = FIFOAsyncMutex()
        mutexes[key] = mutex
        return mutex
    }
}
