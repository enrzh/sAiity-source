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
}
