import Foundation
import Translation

/// What an engine can translate into, and what string it wants to be told.
///
/// Deliberately static rather than a method on `Translating`: the picker has to
/// answer "can MADLAD do Swahili?" for an engine the user has not selected and
/// whose 1.86 GB of weights are not on disk. An instance method could not.
protocol TranslationLanguageProvider {
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
        case .apple: return AppleLanguageProvider.self
        case .madlad: return MADLADLanguageProvider.self
        case .qwen: return QwenLanguageProvider.self
        }
    }
}

// MARK: - Apple

enum AppleLanguageProvider: TranslationLanguageProvider {
    /// The framework answer comes over XPC, so cache it.
    private static let cache = Cache()

    private actor Cache {
        var codes: Set<String>?
        func value() async -> Set<String> {
            if let codes { return codes }
            let langs = await LanguageAvailability().supportedLanguages
            // Keep the script: folding zh-Hant into zh loses the distinction
            // Apple itself models, and then Traditional silently becomes
            // Simplified.
            let set = Set(langs.map { l -> String in
                var s = l.languageCode?.identifier ?? l.minimalIdentifier
                if let script = l.script?.identifier { s += "-\(script)" }
                return s
            })
            codes = set
            return set
        }
    }

    static func supportedCanonicalCodes() async -> Set<String> { await cache.value() }

    static func nativeCode(for canonical: String) -> String? { canonical }
}

// MARK: - MADLAD

enum MADLADLanguageProvider: TranslationLanguageProvider {
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

enum QwenLanguageProvider: TranslationLanguageProvider {
    /// An instruct LLM has no hard language list — what varies is quality, not
    /// capability. Offering the full catalogue and being honest about quality
    /// beats inventing a boundary the model does not have.
    static func supportedCanonicalCodes() async -> Set<String> {
        Set(LanguageCatalog.all.map(\.code))
    }

    /// Languages Qwen is documented to handle well. Everything outside this is
    /// still selectable, with a caveat rather than a refusal.
    static let strongTier: Set<String> = [
        "en", "zh-Hans", "zh-Hant", "fr", "es", "pt", "de", "it", "nl", "ru",
        "cs", "pl", "ar", "fa", "he", "tr", "ja", "ko", "vi", "th", "id", "ms",
        "hi", "bn", "ur", "uk", "el", "ro", "hu", "sv", "da", "fi", "no",
    ]

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
