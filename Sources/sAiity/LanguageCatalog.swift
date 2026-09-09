import Foundation

/// One selectable language, in the app's canonical spelling.
///
/// Canonical form is BCP-47 with hyphens — which is what `translateTo` already
/// persists and what Apple's framework speaks natively, so adopting it needs no
/// migration of anyone's settings.
struct AppLanguage: Identifiable, Hashable, Sendable {
    let code: String
    var id: String { code }

    /// What to show in a list. ICU knows most of these; the ones it does not are
    /// mostly ISO 639-3 codes that only MADLAD offers.
    var displayName: String {
        // Ask for the full identifier first: that is what distinguishes
        // "Chinese (Simplified)" from a bare "Chinese".
        if let full = Locale.current.localizedString(forIdentifier: code), full != code {
            return full
        }
        let parts = code.split(separator: "-").map(String.init)
        if let base = parts.first,
           let name = Locale.current.localizedString(forLanguageCode: base), name != base {
            // Re-attach whatever qualifier ICU dropped, so two variants of one
            // language are still distinguishable in a list of 450.
            let rest = parts.dropFirst().joined(separator: ", ")
            return rest.isEmpty ? name.capitalized : "\(name.capitalized) (\(rest))"
        }
        return code
    }

    /// True when we have nothing better than the raw code to show. Worth
    /// flagging rather than hiding — it tells the user the language is real but
    /// obscure, instead of looking like a bug.
    var hasOnlyCode: Bool { displayName == code }

    func matches(_ query: String) -> Bool {
        guard !query.isEmpty else { return true }
        let q = query.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
        func has(_ s: String) -> Bool {
            s.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil).contains(q)
        }
        return has(code) || has(displayName) || Self.aliases[code].map(has) == true
    }

    /// Names people actually type that ICU will not match.
    private static let aliases: [String: String] = [
        "zh-Hans": "mandarin chinese simplified",
        "zh-Hant": "mandarin chinese traditional",
        "fa": "farsi persian",
        "nb": "norwegian bokmal",
        "fil": "tagalog filipino",
        "he": "hebrew ivrit",
        "my": "burmese myanmar",
        "el": "greek hellenic",
        "nl": "dutch flemish",
    ]
}

/// The union of every language any engine can reach.
enum LanguageCatalog {

    /// Codes worth offering first: what this Mac is set up for, then the
    /// languages a caption track is most often turned into.
    static let popular = ["en", "de", "fr", "es", "it", "pt", "nl", "pl",
                          "ru", "uk", "tr", "ar", "he", "hi", "bn", "ur", "fa",
                          "zh-Hans", "zh-Hant", "ja", "ko", "th", "vi", "id",
                          "sw", "am", "ha", "yo", "ig", "zu", "so"]

    /// Everything selectable, sorted by display name so a 450-entry list reads
    /// alphabetically in the user's own language.
    static let all: [AppLanguage] = {
        var codes = MADLADLanguages.canonicalCodes
        codes.formUnion(popular)
        return codes.map(AppLanguage.init(code:))
            .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
    }()

    static func language(_ code: String) -> AppLanguage { AppLanguage(code: code) }

    /// Capability sets are static model metadata, not runtime work. Keep one
    /// table so every picker and warning reads the same answer without
    /// spawning async tasks or rescanning every engine for every row.
    private static let supportedCodesByEngine: [TranslationEngine: Set<String>] = [
        .madlad: MADLADLanguageProvider.canonicalCodes,
        .hyMT2: HyMT2LanguageProvider.canonicalCodes,
        .qwen: LLMLanguageProvider.canonicalCodes,
    ]

    static func supportedCodes(for engine: TranslationEngine) -> Set<String> {
        supportedCodesByEngine[engine] ?? []
    }

    /// Which engines can translate into this language, in the app's own
    /// recommendation order. Used to offer a way forward instead of greying a
    /// row out and saying nothing.
    static func engines(supporting code: String) async -> [TranslationEngine] {
        TranslationEngine.allCases.filter { supportedCodes(for: $0).contains(code) }
    }
}
