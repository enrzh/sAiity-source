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
    typealias Hook = @Sendable (String, URL) async throws -> Void
    typealias Transcription = @Sendable (String, URL, [[Float]], DecodingOptions) async throws -> String
    private let download: Download; private let setup: Hook; private let load: Hook; private let transcribeHook: Transcription
    private static let gate = OperationGate()
    init(download: @escaping Download = WhisperDictationBackend.realDownload, setup: @escaping Hook = WhisperDictationBackend.realSetup, load: @escaping Hook = WhisperDictationBackend.realLoad, transcribe: @escaping Transcription = WhisperDictationBackend.realTranscribe) { self.download = download; self.setup = setup; self.load = load; self.transcribeHook = transcribe }
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
    func prepareModel(_ c: ModelChoice, under root: URL, progress: @escaping @Sendable (Progress) -> Void = { _ in }) async throws { try await Self.gate.run(c.identifier) { if Self.required(c, root) { return }; let partial = root.appendingPathComponent("\(c.folderName).partial", isDirectory: true); try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true); try? FileManager.default.removeItem(at: partial); do { let d = try await self.download(c.identifier, partial, progress); try Task.checkCancellation(); try? FileManager.default.removeItem(at: Self.folder(c, root)); try FileManager.default.moveItem(at: d, to: Self.folder(c, root)); try? FileManager.default.removeItem(at: partial) } catch { try? FileManager.default.removeItem(at: partial); try? FileManager.default.removeItem(at: Self.folder(c, root)); throw error } } }
    func prepareModelForUse(_ c: ModelChoice, under root: URL, progress: @escaping @Sendable (Progress) -> Void = { _ in }) async throws { try await Self.gate.run(c.identifier) { try await self.prepareModelUnlocked(c, root, progress); let f = Self.folder(c, root); do { try await self.setup(c.identifier, f); try await self.load(c.identifier, f); try Data().write(to: f.appendingPathComponent(c.readinessMarkerName), options: .atomic) } catch { try? FileManager.default.removeItem(at: f.appendingPathComponent(c.readinessMarkerName)); throw error } } }
    private func prepareModelUnlocked(_ c: ModelChoice, _ root: URL, _ p: @escaping @Sendable (Progress) -> Void) async throws { if !Self.required(c, root) { let partial = root.appendingPathComponent("\(c.folderName).partial", isDirectory: true); try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true); let d = try await download(c.identifier, partial, p); try FileManager.default.moveItem(at: d, to: Self.folder(c, root)) } }
    func removeModel(_ c: ModelChoice, under root: URL) async throws { try await Self.gate.run(c.identifier) { for u in [Self.folder(c, root), root.appendingPathComponent("\(c.folderName).partial")] { try? FileManager.default.removeItem(at: u) } } }
    func transcribe(samples: [[Float]], locale: Locale, model c: ModelChoice = model) async throws -> String { let o = try Self.decodingOptions(for: locale); return try await Self.gate.run(c.identifier) { try await self.transcribeHook(c.identifier, Self.folder(c, ModelRegistry.root), samples, o) } }
    private static func realDownload(_ id: String, _ d: URL, _ p: @escaping @Sendable (Progress) -> Void) async throws -> URL { try await WhisperKit.download(variant: id, downloadBase: d, useBackgroundSession: false, from: "argmaxinc/whisperkit-coreml", token: nil, endpoint: Constants.defaultRemoteEndpoint, progressCallback: p) }
    private static func realSetup(_ id: String, _ f: URL) async throws { let w = try await WhisperKit(model: id, modelRepo: nil, modelFolder: f.path, prewarm: false, load: false, download: false); try await w.setupModels(model: id, modelRepo: nil, modelFolder: f.path, download: false) }
    private static func realLoad(_ id: String, _ f: URL) async throws { let w = try await WhisperKit(model: id, modelRepo: nil, modelFolder: f.path, prewarm: false, load: false, download: false); try await w.loadModels(prewarmMode: true) }
    private static func realTranscribe(_ id: String, _ f: URL, _ s: [[Float]], _ o: DecodingOptions) async throws -> String { let w = try await WhisperKit(model: id, modelRepo: nil, modelFolder: f.path, prewarm: false, load: false, download: false); try await w.setupModels(model: id, modelRepo: nil, modelFolder: f.path, download: false); try await w.loadModels(prewarmMode: true); return (await w.transcribe(audioArrays: s, decodeOptions: o, callback: nil)).compactMap { $0?.first?.text }.joined(separator: " ") }
}
private actor OperationGate { var tasks: [String: Task<Any, Error>] = [:]; func run<T>(_ id: String, _ op: @escaping @Sendable () async throws -> T) async throws -> T { if let t = tasks[id] { return try await t.value as! T }; let t = Task<Any, Error> { try await op() }; tasks[id] = t; defer { tasks[id] = nil }; return try await t.value as! T } }
