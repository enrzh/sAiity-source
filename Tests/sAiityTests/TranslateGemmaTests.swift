import Foundation
import Testing
@testable import sAiity

@Suite struct TranslateGemmaTests {
    @Test("TranslateGemma language codes retain declared Chinese and regional output variants")
    func declaredLanguages() {
        #expect(TranslateGemmaTranslator.nativeCode(for: "en-US") == "en-US")
        #expect(TranslateGemmaTranslator.nativeCode(for: "de-DE") == "de-DE")
        #expect(TranslateGemmaTranslator.nativeCode(for: "ja") == "ja-JP")
        #expect(TranslateGemmaTranslator.nativeCode(for: "zh-Hans") == "zh-CN")
        #expect(TranslateGemmaTranslator.nativeCode(for: "zh-Hant") == "zh-TW")
        #expect(TranslateGemmaTranslator.nativeCode(for: "pt-BR") == "pt-BR")
        #expect(TranslateGemmaTranslator.nativeCode(for: "fr-CA") == "fr-CA")
        for code in ["auto", "und", "unknown", "yue", "de-Latn-US", "nonsense"] {
            #expect(TranslateGemmaTranslator.nativeCode(for: code) == nil)
        }
    }

    @Test("specialized official source-target prompt keeps Unicode, paragraph and request content exact")
    func specializedTranslationPrompt() throws {
        let text = "Don't omit invoice 42.\n\ncafe\u{301} 字幕 <tag>"
        let prompt = try #require(TranslateGemmaTranslator.prompt(text, source: "en", target: "de"))
        #expect(prompt.hasPrefix("You are a professional English (en) to German (de-DE) translator."))
        #expect(prompt.hasSuffix("Please translate the following English text into German:\n\n\n" + text))
        #expect(prompt.contains("Produce only the German translation, without any additional explanations or commentary."))
        #expect(TranslateGemmaTranslator.prompt(text, source: "auto", target: "de") == nil)
        #expect(TranslateGemmaTranslator.prompt(text, source: "en", target: "auto") == nil)
    }
}
