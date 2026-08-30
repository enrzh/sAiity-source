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
    }

    static let supportedLanguageCodes = Set(LanguageCatalog.all.map(\.code))

    @Defaults(rawKey: "whisperDictationModel") static var model = ModelChoice.base
    @Defaults("whisperDictationLocale") static var locale = "auto"

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
}
