import Foundation
import WhisperKit

enum WhisperDictationError: Error, Equatable { case unsupportedLocale(String) }

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
    private let root: URL; private let download: Download; private let prepare: Prepare; private let transcribeHook: Transcription
    private static let mutexes = MutexRegistry()
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
    init(root: URL = ModelRegistry.root, download: @escaping Download = WhisperDictationBackend.realDownload, prepare: @escaping Prepare = WhisperDictationBackend.realPrepare, transcribe: @escaping Transcription = WhisperDictationBackend.realTranscribe) { self.root = root; self.download = download; self.prepare = prepare; self.transcribeHook = transcribe }
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
                try? FileManager.default.removeItem(at: root.appendingPathComponent("\(c.folderName).partial"))
                throw CancellationError()
            } catch {
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
    func removeModel(_ c: ModelChoice, under root: URL? = nil) async throws { let root = root ?? self.root; let mutex = await Self.mutexes.mutex(for: "\(root.path):\(c.identifier)"); try await mutex.run { for u in [Self.folder(c, root), root.appendingPathComponent("\(c.folderName).partial")] { do { try FileManager.default.removeItem(at: u) } catch let e as CocoaError where e.code == .fileNoSuchFile { } } } }
    func transcribe(samples: [[Float]], locale: Locale, model c: ModelChoice = model) async throws -> String { let o = try Self.decodingOptions(for: locale); let mutex = await Self.mutexes.mutex(for: "\(root.path):\(c.identifier)"); return try await mutex.run { try await self.transcribeHook(c.identifier, Self.folder(c, self.root), samples, o) } }
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
        let w = try await WhisperKit(model: id, modelRepo: nil, modelFolder: f.path, prewarm: false, load: false, download: false)
        do {
            try await w.setupModels(model: id, modelRepo: nil, modelFolder: f.path, download: false)
            try await w.loadModels(prewarmMode: true)
        } catch {
            await w.unloadModels()
            throw error
        }
        await w.unloadModels()
    }
    private static let realTranscribe: Transcription = { id, f, s, o in
        let w = try await WhisperKit(model: id, modelRepo: nil, modelFolder: f.path, prewarm: false, load: false, download: false)
        do {
            try await w.setupModels(model: id, modelRepo: nil, modelFolder: f.path, download: false)
            try await w.loadModels(prewarmMode: true)
            let result = (await w.transcribe(audioArrays: s, decodeOptions: o, callback: nil)).compactMap { $0?.first?.text }.joined(separator: " ")
            await w.unloadModels()
            return result
        } catch {
            await w.unloadModels()
            throw error
        }
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
