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
        var activeUsers = 0
        var evictionToken = UUID()
        var invalidated = false
    }

    private let idleDuration: Duration
    private let loader: Loader
    private var entries: [Key: Entry] = [:]
    private var evictionTasks: [Key: Task<Void, Never>] = [:]

    init(idleDuration: Duration = .seconds(45), loader: @escaping Loader) {
        self.idleDuration = idleDuration
        self.loader = loader
    }

    func withModel<T: Sendable>(for key: Key,
                                operation: @escaping @Sendable (Resource) async throws -> T) async throws -> T {
        let resource = try await acquire(key)
        do {
            let value = try await operation(resource)
            await release(key)
            return value
        } catch {
            await release(key)
            throw error
        }
    }

    func invalidate(_ key: Key) async {
        evictionTasks.removeValue(forKey: key)?.cancel()
        guard var entry = entries[key] else { return }
        if entry.activeUsers > 0 {
            entry.invalidated = true
            entries[key] = entry
            return
        }
        entries.removeValue(forKey: key)
        await entry.resource.unload()
    }

#if SAIITY_TEST_HOOKS
    var residentCountForTests: Int { entries.count }
#endif

    private func acquire(_ key: Key) async throws -> Resource {
        if var entry = entries[key], !entry.invalidated {
            entry.activeUsers += 1
            entries[key] = entry
            scheduleEviction(for: key, token: entry.evictionToken)
            return entry.resource
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
            existing.activeUsers += 1
            entries[key] = existing
            scheduleEviction(for: key, token: existing.evictionToken)
            return existing.resource
        }

        var entry = Entry(resource: resource)
        entry.activeUsers = 1
        entries[key] = entry
        scheduleEviction(for: key, token: entry.evictionToken)
        return resource
    }

    private func release(_ key: Key) async {
        guard var entry = entries[key] else { return }
        entry.activeUsers = max(0, entry.activeUsers - 1)
        guard entry.activeUsers == 0 else {
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
              entry.activeUsers == 0,
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
            try await model.loadModels(prewarmMode: true)
        } catch {
            await model.unloadModels()
            throw error
        }
        whisper = model
    }

    func transcribe(_ samples: [Float],
                    options: DecodingOptions) async -> (text: String, language: String?) {
        await transcribe([samples], options: options)
    }

    func transcribe(_ samples: [[Float]],
                    options: DecodingOptions) async -> (text: String, language: String?) {
        let results = await whisper.transcribe(audioArrays: samples,
                                               decodeOptions: options,
                                               callback: nil)
        let decoded = results.compactMap { $0 }.flatMap { $0 }
        return (decoded.map(\.text).joined(separator: " "), decoded.first?.language)
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
    static let supportedLanguageCodes = Set(LanguageCatalog.all.map(\.code))
    @Defaults(rawKey: "whisperDictationModel") static var model = ModelChoice.base
    static var isSelected: Bool {
        get { UserDefaults.standard.bool(forKey: "whisperDictationSelected") }
        set { UserDefaults.standard.set(newValue, forKey: "whisperDictationSelected") }
    }
    static var locale: String {
        get { let stored = UserDefaults.standard.string(forKey: "whisperDictationLocale") ?? "auto"; let value = canonicalLocale(stored); if value != stored { UserDefaults.standard.set(value, forKey: "whisperDictationLocale") }; return value }
        set { UserDefaults.standard.set(canonicalLocale(newValue), forKey: "whisperDictationLocale") }
    }
    private static func canonicalLocale(_ id: String) -> String { guard id != "auto" else { return id }; let c = Locale(identifier: id).identifier(.bcp47), b = c.split(separator: "-").first.map(String.init) ?? c; return supportedLanguageCodes.contains(c) || supportedLanguageCodes.contains(b) ? c : "auto" }
    static func decodingOptions(for locale: Locale) throws -> DecodingOptions { if locale.identifier == "auto" { return DecodingOptions(language: nil, detectLanguage: true) }; let c = locale.identifier(.bcp47), b = c.split(separator: "-").first.map(String.init) ?? c; guard supportedLanguageCodes.contains(c) || supportedLanguageCodes.contains(b) else { throw WhisperDictationError.unsupportedLocale(locale.identifier) }; return DecodingOptions(language: b, detectLanguage: false) }
    static func transcribe(locale: Locale, using body: () throws -> Void) throws { _ = try decodingOptions(for: locale); try body() }
    private static func folder(_ c: ModelChoice, _ root: URL) -> URL { root.appendingPathComponent(c.folderName, isDirectory: true) }
    private static func required(_ c: ModelChoice, _ root: URL) -> Bool {
        let f = folder(c, root)
        return ["MelSpectrogram.mlmodelc", "AudioEncoder.mlmodelc", "TextDecoder.mlmodelc"].allSatisfy { name in
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
    static func isReady(_ c: ModelChoice, under root: URL = ModelRegistry.root) -> Bool { required(c, root) && FileManager.default.fileExists(atPath: folder(c, root).appendingPathComponent(c.readinessMarkerName).path) }
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
                await Self.modelCache.invalidate(Self.cacheKey(c, root))
                try? FileManager.default.removeItem(at: root.appendingPathComponent("\(c.folderName).partial"))
                throw CancellationError()
            } catch {
                await Self.modelCache.invalidate(Self.cacheKey(c, root))
                try? FileManager.default.removeItem(at: Self.folder(c, root).appendingPathComponent(c.readinessMarkerName))
                try? FileManager.default.removeItem(at: Self.folder(c, root))
                try? FileManager.default.removeItem(at: root.appendingPathComponent("\(c.folderName).partial"))
                throw error
            }
        }
    }
    private func prepareModelUnlocked(_ c: ModelChoice, _ root: URL, _ progress: @escaping @Sendable (Progress) -> Void) async throws {
        if Self.required(c, root) { return }
        let partial = root.appendingPathComponent("\(c.folderName).partial", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: partial)
        do {
            let downloaded = try await self.download(c.identifier, partial, progress)
            try Task.checkCancellation()
            try? FileManager.default.removeItem(at: Self.folder(c, root))
            try FileManager.default.moveItem(at: downloaded, to: Self.folder(c, root))
            try? FileManager.default.removeItem(at: partial)
        } catch is CancellationError {
            try? FileManager.default.removeItem(at: partial)
            throw CancellationError()
        } catch {
            try? FileManager.default.removeItem(at: partial)
            try? FileManager.default.removeItem(at: Self.folder(c, root))
            throw error
        }
    }
    func removeModel(_ c: ModelChoice, under root: URL? = nil) async throws {
        let root = root ?? self.root
        let mutex = await Self.mutexes.mutex(for: "\(root.path):\(c.identifier)")
        try await mutex.run {
            await Self.modelCache.invalidate(Self.cacheKey(c, root))
            for url in [Self.folder(c, root), root.appendingPathComponent("\(c.folderName).partial")] {
                do {
                    try FileManager.default.removeItem(at: url)
                } catch let error as CocoaError where error.code == .fileNoSuchFile {
                    continue
                }
            }
        }
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
                                                                     language: decoded.language))
                    }
                }
                return DictationTranscriptionResult(regions: transcripts)
            }

            return try await Self.modelCache.withModel(for: Self.cacheKey(c, self.root)) { loaded in
                var transcripts: [DictationRegionTranscript] = []
                for region in regions {
                    try Task.checkCancellation()
                    let audio = Array(samples[region.audioRange])
                    guard !audio.isEmpty else { continue }
                    let decoded = await loaded.transcribe(audio, options: options)
                    let text = decoded.text.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !text.isEmpty {
                        transcripts.append(DictationRegionTranscript(text: text,
                                                                     language: decoded.language))
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
            let result = await loaded.transcribe(s, options: o)
            return result.text
        }
    }

    private static func cacheKey(_ c: ModelChoice, _ root: URL) -> WhisperModelCacheKey {
        WhisperModelCacheKey(identifier: c.identifier, folderPath: folder(c, root).path)
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
