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
    init(root: URL = ModelRegistry.root, download: @escaping Download = WhisperDictationBackend.realDownload, prepare: @escaping Prepare = WhisperDictationBackend.realPrepare, transcribe: @escaping Transcription = WhisperDictationBackend.realTranscribe) { self.root = root; self.download = download; self.prepare = prepare; self.transcribeHook = transcribe }
    static let supportedLanguageCodes = Set(LanguageCatalog.all.map(\.code))
    @Defaults(rawKey: "whisperDictationModel") static var model = ModelChoice.base
    static var locale: String {
        get { let stored = UserDefaults.standard.string(forKey: "whisperDictationLocale") ?? "auto"; let value = canonicalLocale(stored); if value != stored { UserDefaults.standard.set(value, forKey: "whisperDictationLocale") }; return value }
        set { UserDefaults.standard.set(canonicalLocale(newValue), forKey: "whisperDictationLocale") }
    }
    private static func canonicalLocale(_ id: String) -> String { guard id != "auto" else { return id }; let c = Locale(identifier: id).identifier(.bcp47), b = c.split(separator: "-").first.map(String.init) ?? c; return supportedLanguageCodes.contains(c) || supportedLanguageCodes.contains(b) ? c : "auto" }
    static func decodingOptions(for locale: Locale) throws -> DecodingOptions { if locale.identifier == "auto" { return DecodingOptions(language: nil, detectLanguage: true) }; let c = locale.identifier(.bcp47), b = c.split(separator: "-").first.map(String.init) ?? c; guard supportedLanguageCodes.contains(c) || supportedLanguageCodes.contains(b) else { throw WhisperDictationError.unsupportedLocale(locale.identifier) }; return DecodingOptions(language: b, detectLanguage: false) }
    static func transcribe(locale: Locale, using body: () throws -> Void) throws { _ = try decodingOptions(for: locale); try body() }
    private static func folder(_ c: ModelChoice, _ root: URL) -> URL { root.appendingPathComponent(c.folderName, isDirectory: true) }
    private static func required(_ c: ModelChoice, _ root: URL) -> Bool { let f = folder(c, root); return ["MelSpectrogram.mlmodelc", "AudioEncoder.mlmodelc", "TextDecoder.mlmodelc"].allSatisfy { FileManager.default.fileExists(atPath: f.appendingPathComponent($0).path) } }
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
                try await self.prepare(c.identifier, folder)
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
    private static func realDownload(_ id: String, _ d: URL, _ p: @escaping @Sendable (Progress) -> Void) async throws -> URL { try await WhisperKit.download(variant: id, downloadBase: d, useBackgroundSession: false, from: "argmaxinc/whisperkit-coreml", token: nil, endpoint: Constants.defaultRemoteEndpoint, progressCallback: p) }
    private static func realPrepare(_ id: String, _ f: URL) async throws { let w = try await WhisperKit(model: id, modelRepo: nil, modelFolder: f.path, prewarm: false, load: false, download: false); try await w.setupModels(model: id, modelRepo: nil, modelFolder: f.path, download: false); try await w.loadModels(prewarmMode: true) }
    private static func realTranscribe(_ id: String, _ f: URL, _ s: [[Float]], _ o: DecodingOptions) async throws -> String { let w = try await WhisperKit(model: id, modelRepo: nil, modelFolder: f.path, prewarm: false, load: false, download: false); try await w.setupModels(model: id, modelRepo: nil, modelFolder: f.path, download: false); try await w.loadModels(prewarmMode: true); return (await w.transcribe(audioArrays: s, decodeOptions: o, callback: nil)).compactMap { $0?.first?.text }.joined(separator: " ") }
}
private actor FIFOAsyncMutex {
    private var locked = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func run<T: Sendable>(_ operation: @Sendable () async throws -> T) async throws -> T {
        await acquire()
        do {
            let result = try await operation()
            release()
            return result
        } catch {
            release()
            throw error
        }
    }

    private func acquire() async {
        if !locked {
            locked = true
            return
        }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    private func release() {
        if let next = waiters.first {
            waiters.removeFirst()
            next.resume()
        } else {
            locked = false
        }
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
