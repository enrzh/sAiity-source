import Foundation
import Testing

@testable import sAiity

/// Language codes fail silently. A code an engine does not recognise produces no
/// translation and no error message — the caption simply stays untranslated —
/// so these are the assertions that would have caught it.
@MainActor
struct LanguageTests {

    @Test("Chinese resolves to MADLAD's own token, not BCP-47")
    func chineseIsNotPassedThroughRaw() {
        // The bug: the app persisted "zh-Hans", passed it straight to the
        // tokenizer, which has only `<2zh>` and threw `unsupportedLanguage`.
        // A `try?` swallowed the throw, so Chinese never translated and nothing
        // ever said why.
        #expect(MADLADLanguageProvider.nativeCode(for: "zh-Hans") == "zh")
        #expect(MADLADLanguageProvider.nativeCode(for: "zh-Hans") != "zh-Hans")
        #expect(MADLADLanguageProvider.nativeCode(for: "zh-Hant") == "zh_Hant")
        #expect(MADLADLanguageProvider.nativeCode(for: "zh-TW") == "zh_Hant")
    }

    @Test("MADLAD codes never contain a hyphen")
    func nativeCodesUseTheModelsSpelling() {
        // The tokenizer matches a literal `<2xx>`; a hyphen is always a miss.
        for lang in LanguageCatalog.all {
            guard let native = MADLADLanguageProvider.nativeCode(for: lang.code) else { continue }
            #expect(!native.contains("-"), "\(lang.code) → \(native) has a hyphen")
            #expect(MADLADLanguages.tokens.contains(native),
                    "\(lang.code) → \(native) is not a real MADLAD token")
        }
    }

    @Test("The Asian and African languages this was all about are reachable")
    func broadCoverageIsReal() async {
        // The user's actual question: can these models do more than German and
        // English? Named explicitly so a regression is obvious.
        let wanted = ["sw": "Swahili", "yo": "Yoruba", "ha": "Hausa", "am": "Amharic",
                      "zu": "Zulu", "ig": "Igbo", "so": "Somali",
                      "ja": "Japanese", "ko": "Korean", "th": "Thai", "vi": "Vietnamese",
                      "hi": "Hindi", "bn": "Bengali", "ur": "Urdu", "fa": "Persian",
                      "km": "Khmer", "ta": "Tamil", "te": "Telugu"]
        let madlad = await MADLADLanguageProvider.supportedCanonicalCodes()
        for (code, name) in wanted {
            #expect(madlad.contains(code), "MADLAD cannot reach \(name)")
            #expect(MADLADLanguageProvider.nativeCode(for: code) != nil, "\(name) does not resolve")
            #expect(LanguageCatalog.all.contains { $0.code == code },
                    "\(name) is not offered in the picker")
        }
    }

    @Test("Regional spellings fall back instead of failing")
    func regionVariantsResolve() {
        // macOS hands out things like de-DE and pt-BR; MADLAD has the base
        // language only. Refusing those would be as broken as passing them raw.
        #expect(MADLADLanguageProvider.nativeCode(for: "de-DE") == "de")
        #expect(MADLADLanguageProvider.nativeCode(for: "pt-BR") == "pt")
        #expect(MADLADLanguageProvider.nativeCode(for: "en-GB") == "en")
        #expect(MADLADLanguageProvider.nativeCode(for: "es-419") == "es")
        // Deprecated codes that still turn up in real data.
        #expect(MADLADLanguageProvider.nativeCode(for: "iw") == "he")
        #expect(MADLADLanguageProvider.nativeCode(for: "tl") == "fil")
    }

    @Test("same-language translation is skipped across regional spellings")
    func sameLanguageIsRecognized() {
        #expect(TranslationLanguage.isSame("zh", as: "zh-Hans"))
        #expect(TranslationLanguage.isSame("de-DE", as: "de"))
        #expect(TranslationLanguage.isSame("zh_Hant", as: "zh-TW"))
        #expect(!TranslationLanguage.isSame("de", as: "en"))
        #expect(!TranslationLanguage.isSame("auto", as: "en"))
        #expect(!TranslationLanguage.isSame(nil, as: "en"))
    }

    @Test("Every offered language has a name, not just a code")
    func displayNamesResolve() {
        // 450 rows of raw ISO codes is not a picker. Some obscure ISO 639-3
        // codes genuinely have no ICU name; assert the common ones do and that
        // the unnamed remainder stays small enough to be a footnote.
        for code in LanguageCatalog.popular {
            let l = AppLanguage(code: code)
            #expect(!l.hasOnlyCode, "\(code) shows as a bare code")
        }
        let unnamed = LanguageCatalog.all.filter(\.hasOnlyCode).count
        #expect(Double(unnamed) / Double(LanguageCatalog.all.count) < 0.5,
                "\(unnamed) of \(LanguageCatalog.all.count) languages have no name")
    }

    @Test("Qwen is told an English language name, whatever the Mac's language is")
    func qwenPromptNameIsAlwaysEnglish() {
        // The prompt and all its few-shot examples are English. Feeding it
        // "Chinesisch" on a German Mac mixes languages inside one instruction,
        // which is what a small model handles worst.
        #expect(LLMLanguageProvider.nativeCode(for: "zh-Hans")?.contains("Chinese") == true)
        #expect(LLMLanguageProvider.nativeCode(for: "de") == "German")
        #expect(LLMLanguageProvider.nativeCode(for: "sw") == "Swahili")
    }

    @Test("Qwen separates its stronger languages from the experimental long tail")
    func qwenQualityTiersAreExplicit() {
        #expect(LLMLanguageProvider.isStrong("de"))
        #expect(LLMLanguageProvider.isStrong("de-DE"))
        #expect(LLMLanguageProvider.isStrong("zh-Hans"))
        #expect(!LLMLanguageProvider.isStrong("sw"))
    }

    @Test("A language no engine can do is never offered as if it could be")
    func everyOfferedLanguageHasAnEngine() async {
        for lang in LanguageCatalog.all.prefix(60) {
            let engines = await LanguageCatalog.engines(supporting: lang.code)
            #expect(!engines.isEmpty, "\(lang.code) is listed but no engine can translate it")
        }
    }

    @Test("The dictation catalog matches the translation catalog")
    func dictationCatalogMatchesMADLAD() {
        #expect(Set(LanguageCatalog.all.map(\.code)) ==
                Set(MADLADLanguages.canonicalCodes).union(LanguageCatalog.popular))
    }

    @Test("Persisted dictation locales are canonical BCP-47 or auto")
    func persistedDictationLocaleCanonicalization() {
        let defaults = UserDefaults.standard
        let key = "whisperDictationLocale"
        let old = defaults.object(forKey: key)
        defer {
            if let old { defaults.set(old, forKey: key) } else { defaults.removeObject(forKey: key) }
        }

        defaults.set("de_DE", forKey: key)
        #expect(WhisperDictationBackend.locale == "de-DE")
        #expect(defaults.string(forKey: key) == "de-DE")

        defaults.set("zz-ZZ", forKey: key)
        #expect(WhisperDictationBackend.locale == "auto")
        #expect(defaults.string(forKey: key) == "auto")
    }

    @Test("Caption source detection can change per complete sentence")
    func captionSourceDetectionDoesNotUseSessionDominantLanguage() {
        #expect(LanguageDetector.languageCode(
            in: "Das ist ein vollständiger deutscher Untertitelsatz.") == "de")
        #expect(LanguageDetector.languageCode(
            in: "This is a complete English subtitle sentence.") == "en")
        #expect(LanguageDetector.languageCode(in: "Okay.") == nil)
    }
}
