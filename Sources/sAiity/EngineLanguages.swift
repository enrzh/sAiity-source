import Foundation

/// What an engine can translate into, and what string it wants to be told.
///
/// Deliberately static rather than a method on `Translating`: the picker has to
/// answer "can MADLAD do Swahili?" for an engine the user has not selected and
/// whose 1.86 GB of weights are not on disk. An instance method could not.
protocol TranslationLanguageProvider {
    /// Immutable capability metadata used by language pickers and warnings.
    static var canonicalCodes: Set<String> { get }

    /// Canonical BCP-47 codes this engine accepts.
    static func supportedCanonicalCodes() async -> Set<String>

    /// Canonical code → the exact string this engine's API wants. Nil when the
    /// engine cannot do it. Pure and synchronous, so it is trivially testable —
    /// which matters, because getting it wrong produces silence rather than an
    /// error.
    static func nativeCode(for canonical: String) -> String?
}

extension TranslationEngine {
    var languages: any TranslationLanguageProvider.Type {
        switch self {
        case .madlad: return MADLADLanguageProvider.self
        case .hyMT2: return HyMT2LanguageProvider.self
        case .qwen: return LLMLanguageProvider.self
        }
    }
}

// MARK: - MADLAD

enum MADLADLanguageProvider: TranslationLanguageProvider {
    static let canonicalCodes = MADLADLanguages.canonicalCodes

    static func supportedCanonicalCodes() async -> Set<String> { MADLADLanguages.canonicalCodes }

    /// Resolution ladder, most specific first. MADLAD demands an exact vocab
    /// token — `languageTokenId(for:)` throws `unsupportedLanguage` on anything
    /// else — so guessing is not an option, but neither is refusing every
    /// regional spelling macOS might hand us.
    static func nativeCode(for canonical: String) -> String? {
        if let alias = MADLADLanguages.aliases[canonical] { return alias }

        let underscored = canonical.replacingOccurrences(of: "-", with: "_")
        if MADLADLanguages.tokens.contains(underscored) { return underscored }

        // Drop the region but keep the script: de-DE → de, sr-Cyrl-RS → sr_Cyrl.
        var parts = underscored.split(separator: "_").map(String.init)
        while parts.count > 1 {
            parts.removeLast()
            let candidate = parts.joined(separator: "_")
            if let alias = MADLADLanguages.aliases[candidate.replacingOccurrences(of: "_", with: "-")] {
                return alias
            }
            if MADLADLanguages.tokens.contains(candidate) { return candidate }
        }
        return nil
    }
}

// MARK: - Qwen

enum LLMLanguageProvider: TranslationLanguageProvider {
    static let canonicalCodes: Set<String> = Set(LanguageCatalog.all.map(\.code))

    /// An instruct LLM has no hard language list, so the full catalogue remains
    /// reachable in Advanced. The picker separates the languages we are
    /// comfortable recommending from the long tail instead of treating them
    /// as equally reliable.
    static func supportedCanonicalCodes() async -> Set<String> {
        canonicalCodes
    }

    /// Languages Qwen is documented to handle well. Everything outside this is
    /// still selectable, with a caveat rather than a refusal.
    static let strongTier: Set<String> = [
        "en", "zh-Hans", "zh-Hant", "fr", "es", "pt", "de", "it", "nl", "ru",
        "cs", "pl", "ar", "fa", "he", "tr", "ja", "ko", "vi", "th", "id", "ms",
        "hi", "bn", "ur", "uk", "el", "ro", "hu", "sv", "da", "fi", "no",
    ]

    static func isStrong(_ canonical: String) -> Bool {
        let normalized = canonical.replacingOccurrences(of: "_", with: "-")
        if strongTier.contains(normalized) { return true }
        guard let base = normalized.split(separator: "-").first.map(String.init) else {
            return false
        }
        return strongTier.contains(base)
    }

    /// Qwen is told a language NAME, not a code — the prompt is what consumes
    /// it. Always in English: the prompt and its examples are English, and
    /// `Locale.current` would otherwise produce "Chinesisch" on a German Mac,
    /// mixing languages inside a single instruction.
    static func nativeCode(for canonical: String) -> String? {
        let en = Locale(identifier: "en_US")
        if let full = en.localizedString(forIdentifier: canonical), full != canonical {
            return full
        }
        if let base = canonical.split(separator: "-").first.map(String.init),
           let name = en.localizedString(forLanguageCode: base), name != base {
            return name
        }
        return nil
    }
}

// MARK: - Hy-MT2

/// The language variants named by Tencent's Hy-MT2 model card.
///
/// Hy-MT2 wants English language names in its user turn, not BCP-47 codes. The
/// map is intentionally finite: falling back to MADLAD's much larger language
/// catalogue would make the picker promise translations this model was not
/// trained or tested for.
enum HyMT2LanguageProvider: TranslationLanguageProvider {
    static let names: [String: String] = [
        "zh": "Chinese",
        "en": "English",
        "fr": "French",
        "pt": "Portuguese",
        "es": "Spanish",
        "ja": "Japanese",
        "tr": "Turkish",
        "ru": "Russian",
        "ar": "Arabic",
        "ko": "Korean",
        "th": "Thai",
        "it": "Italian",
        "de": "German",
        "vi": "Vietnamese",
        "ms": "Malay",
        "id": "Indonesian",
        "tl": "Filipino",
        "hi": "Hindi",
        "zh-Hant": "Traditional Chinese",
        "pl": "Polish",
        "cs": "Czech",
        "nl": "Dutch",
        "km": "Khmer",
        "my": "Burmese",
        "fa": "Persian",
        "gu": "Gujarati",
        "ur": "Urdu",
        "te": "Telugu",
        "mr": "Marathi",
        "he": "Hebrew",
        "bn": "Bengali",
        "ta": "Tamil",
        "bo": "Tibetan",
        "kk": "Kazakh",
        "mn": "Mongolian",
        "ug": "Uyghur",
        "yue": "Cantonese",
    ]

    static let canonicalCodes = Set(names.keys)

    static func supportedCanonicalCodes() async -> Set<String> {
        canonicalCodes
    }

    static func nativeCode(for canonical: String) -> String? {
        let normalized = canonical.replacingOccurrences(of: "_", with: "-")
        if let exact = names[normalized] { return exact }

        let parts = normalized.split(separator: "-").map(String.init)
        guard let base = parts.first else { return nil }

        // Traditional Chinese is the only script-specific entry. Regional
        // Chinese identifiers should retain that distinction in the prompt.
        if base == "zh", parts.dropFirst().contains(where: { $0.caseInsensitiveCompare("Hant") == .orderedSame }) {
            return names["zh-Hant"]
        }
        if base == "zh", parts.dropFirst().contains(where: { ["TW", "HK", "MO"].contains($0.uppercased()) }) {
            return names["zh-Hant"]
        }
        return names[base]
    }
}
