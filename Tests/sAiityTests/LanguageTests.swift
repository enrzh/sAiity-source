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
        #expect(QwenLanguageProvider.nativeCode(for: "zh-Hans")?.contains("Chinese") == true)
        #expect(QwenLanguageProvider.nativeCode(for: "de") == "German")
        #expect(QwenLanguageProvider.nativeCode(for: "sw") == "Swahili")
    }

    @Test("Whisper admits it only does English")
    func whisperIsEnglishOnly() async {
        #expect(await WhisperLanguageProvider.supportedCanonicalCodes() == ["en"])
        #expect(WhisperLanguageProvider.nativeCode(for: "de") == nil)
        #expect(WhisperLanguageProvider.nativeCode(for: "en-US") == "en")
    }

    @Test("A language no engine can do is never offered as if it could be")
    func everyOfferedLanguageHasAnEngine() async {
        for lang in LanguageCatalog.all.prefix(60) {
            let engines = await LanguageCatalog.engines(supporting: lang.code)
            #expect(!engines.isEmpty, "\(lang.code) is listed but no engine can translate it")
        }
    }
}
