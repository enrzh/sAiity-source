import Foundation
import WhisperKit

enum WhisperDictationError: Error, Equatable {
    case unsupportedLocale(String)
}

struct WhisperDictationBackend {
    enum ModelChoice: String, CaseIterable, Equatable, Sendable {
        case base
        case small

        var identifier: String {
            switch self {
            case .base: return "openai_whisper-base"
            case .small: return "openai_whisper-small"
            }
        }

        var description: String {
            switch self {
            case .base: return "base"
            case .small: return "small"
            }
        }

        var folderName: String { "whisper-\(identifier)" }
        var readinessMarkerName: String { ".saiity-ready" }
    }

    static let supportedLanguageCodes = Set(LanguageCatalog.all.map(\.code))

    @Defaults(rawKey: "whisperDictationModel") static var model = ModelChoice.base
    static var locale: String {
        get {
            let stored = UserDefaults.standard.string(forKey: "whisperDictationLocale") ?? "auto"
            let canonical = canonicalLocale(stored)
            if stored != canonical { UserDefaults.standard.set(canonical, forKey: "whisperDictationLocale") }
            return canonical
        }
        set {
            UserDefaults.standard.set(canonicalLocale(newValue), forKey: "whisperDictationLocale")
        }
    }

    private static func canonicalLocale(_ identifier: String) -> String {
        guard identifier != "auto" else { return "auto" }
        let canonical = Locale(identifier: identifier).identifier(.bcp47)
        let base = canonical.split(separator: "-").first.map(String.init) ?? canonical
        return supportedLanguageCodes.contains(canonical) || supportedLanguageCodes.contains(base)
            ? canonical : "auto"
    }

    static func decodingOptions(for locale: Locale) throws -> DecodingOptions {
        if locale.identifier == "auto" {
            return DecodingOptions(language: nil, detectLanguage: true)
        }

        let canonical = locale.identifier(.bcp47)
        let base = canonical.split(separator: "-").first.map(String.init) ?? canonical
        guard supportedLanguageCodes.contains(canonical) || supportedLanguageCodes.contains(base) else {
            throw WhisperDictationError.unsupportedLocale(locale.identifier)
        }
        return DecodingOptions(language: base, detectLanguage: false)
    }

    static func transcribe(locale: Locale, using transcription: () throws -> Void) throws {
        _ = try decodingOptions(for: locale)
        try transcription()
    }

    @MainActor private static var preparations: [String: Task<URL, Error>] = [:]

    @MainActor
    static func modelFolder(for choice: ModelChoice, under root: URL = ModelRegistry.root) -> URL {
        root.appendingPathComponent(choice.folderName, isDirectory: true)
    }

    @MainActor
    static func isReady(_ choice: ModelChoice, under root: URL = ModelRegistry.root) -> Bool {
        let folder = modelFolder(for: choice, under: root)
        let required = ["MelSpectrogram.mlmodelc", "AudioEncoder.mlmodelc", "TextDecoder.mlmodelc"]
        return required.allSatisfy { FileManager.default.fileExists(atPath: folder.appendingPathComponent($0).path) }
            && FileManager.default.fileExists(atPath: folder.appendingPathComponent(choice.readinessMarkerName).path)
    }

    @MainActor
    static func prepareModel(_ choice: ModelChoice, under root: URL = ModelRegistry.root,
                             progress: @escaping @Sendable (Progress) -> Void = { _ in }) async throws {
        if isReady(choice, under: root) { return }
        let key = modelFolder(for: choice, under: root).path
        if let existing = preparations[key] {
            _ = try await existing.value
            return
        }
        let task = Task<URL, Error> {
            try Task.checkCancellation()
            let fm = FileManager.default
            try fm.createDirectory(at: root, withIntermediateDirectories: true)
            let final = modelFolder(for: choice, under: root)
            let partialRoot = root.appendingPathComponent("\(choice.folderName).partial", isDirectory: true)
            try? fm.removeItem(at: final)
            try fm.createDirectory(at: partialRoot, withIntermediateDirectories: true)
            let downloaded = try await WhisperKit.download(variant: choice.identifier,
                downloadBase: partialRoot, useBackgroundSession: false,
                from: "argmaxinc/whisperkit-coreml", token: nil,
                endpoint: Constants.defaultRemoteEndpoint, progressCallback: progress)
            try Task.checkCancellation()
            try? fm.removeItem(at: final)
            try fm.moveItem(at: downloaded, to: final)
            let whisper = try await WhisperKit(model: choice.identifier, modelRepo: nil,
                modelFolder: final.path, prewarm: false, load: false, download: false)
            try await whisper.setupModels(model: choice.identifier, modelRepo: nil,
                modelFolder: final.path, download: false)
            try await whisper.loadModels(prewarmMode: true)
            let marker = final.appendingPathComponent(choice.readinessMarkerName)
            try Data().write(to: marker, options: .atomic)
            try? fm.removeItem(at: partialRoot)
            return final
        }
        preparations[key] = task
        defer { preparations[key] = nil }
        do { _ = try await task.value }
        catch {
            try? FileManager.default.removeItem(at: root.appendingPathComponent("\(choice.folderName).partial"))
            throw error
        }
    }

    @MainActor
    static func removeModel(_ choice: ModelChoice, under root: URL = ModelRegistry.root) throws {
        try FileManager.default.removeItem(at: modelFolder(for: choice, under: root))
    }

    static func transcribe(samples: [[Float]], locale: Locale,
                           model choice: ModelChoice = model) async throws -> String {
        let options = try decodingOptions(for: locale)
        let folder = ModelRegistry.root.appendingPathComponent(choice.folderName, isDirectory: true)
        let whisper = try await WhisperKit(model: choice.identifier, modelRepo: nil,
            modelFolder: folder.path, prewarm: false, load: false, download: false)
        try await whisper.setupModels(model: choice.identifier, modelRepo: nil,
            modelFolder: folder.path, download: false)
        try await whisper.loadModels(prewarmMode: true)
        let results = await whisper.transcribe(audioArrays: samples, decodeOptions: options, callback: nil)
        return results.compactMap { $0?.first?.text }.joined(separator: " ")
    }
}
