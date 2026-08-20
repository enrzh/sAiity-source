import Foundation
import Testing

@testable import sAiity

@MainActor
struct HyMT2TranslationTests {

    @Test("Hy-MT2 remains opt-in while MADLAD stays recommended")
    func engineRecommendationIsUnchanged() {
        #expect(TranslationEngine.recommended.rawValue == "madlad")
        #expect(TranslationEngine.hyMT2.displayName == "Hy-MT2")
        #expect(TranslationEngine.hyMT2 != TranslationEngine.recommended)
    }

    @Test("Hy-MT2 uses conservative first-pass and retry sampling")
    func samplingTemperaturesStayQualityFirst() {
        #expect(HyMT2Translator.generationTemperature == Float(0.1))
        #expect(HyMT2Translator.retryTemperature == Float(0.15))
    }

    @Test("Hy-MT2 exposes the concrete language-card set")
    func supportedLanguagesMatchTheModelCard() async {
        let expected = Set([
            "zh", "en", "fr", "pt", "es", "ja", "tr", "ru", "ar", "ko",
            "th", "it", "de", "vi", "ms", "id", "tl", "hi", "zh-Hant",
            "pl", "cs", "nl", "km", "my", "fa", "gu", "ur", "te", "mr",
            "he", "bn", "ta", "bo", "kk", "mn", "ug", "yue"
        ])
        #expect(await HyMT2LanguageProvider.supportedCanonicalCodes() == expected)
        #expect(HyMT2LanguageProvider.nativeCode(for: "de-DE") == "German")
        #expect(HyMT2LanguageProvider.nativeCode(for: "en-GB") == "English")
        #expect(HyMT2LanguageProvider.nativeCode(for: "zh-Hant") == "Traditional Chinese")
        #expect(HyMT2LanguageProvider.nativeCode(for: "zh-TW") == "Traditional Chinese")
        #expect(HyMT2LanguageProvider.nativeCode(for: "sw") == nil)
    }

    @Test("Hy-MT2 has one fixed Q4 registry asset")
    func registryDescriptorIsComplete() {
        let matching = ModelRegistry.assets().filter { $0.id == AssetID.hyMT2 }
        #expect(matching.count == 1)
        guard let asset = matching.first else { return }

        #expect(asset.advertisedBytes == 1_133_080_448)
        #expect(asset.install != nil)
        if case .remove(let removalURL) = asset.removal {
            let root = ModelRegistry.root.standardizedFileURL.path
            let target = removalURL.standardizedFileURL.path
            #expect(target.hasPrefix(root + "/"))
            #expect(target != root)
        } else {
            Issue.record("Hy-MT2 must have a removable file asset")
        }
        if case .file(let modelURL, let expectedBytes) = asset.storage {
            #expect(expectedBytes == 1_133_080_448)
            #expect(modelURL.lastPathComponent == HyMT2Translator.modelFile)
        } else {
            Issue.record("Hy-MT2 must use single-file GGUF storage")
        }
    }

    @Test("Hy-MT2 prompt uses its Hunyuan user and assistant tokens")
    func promptUsesExplicitHunyuanFraming() {
        let prompt = HyMT2Translator.prompt(targetName: "English", source: "guten morgen")
        #expect(prompt.contains("<｜hy_begin▁of▁sentence｜>"))
        #expect(prompt.contains("<｜hy_User｜>"))
        #expect(prompt.contains("<｜hy_Assistant｜>"))
        #expect(prompt.contains("<｜hy_EOT｜>"))
        #expect(prompt.contains("Translate into English"))
        #expect(prompt.contains("guten morgen"))
    }

    @Test("Hy-MT2 retry prompt interpolates the failed translation request")
    func retryPromptUsesTargetAndSource() {
        let prompt = HyMT2Translator.retryPrompt(targetName: "English", source: "guten morgen")
        #expect(prompt.contains("Translate the source text into English."))
        #expect(prompt.contains("guten morgen"))
        #expect(!prompt.contains("(targetName)"))
        #expect(!prompt.contains("(text)"))
    }

    @Test("Shared validator rejects unsafe translation output")
    func validatorRejectsEmptyAndEchoedOutput() {
        let empty = TranslationOutputValidator.sanitize("", input: "hello", target: "en")
        let echoed = TranslationOutputValidator.sanitize("hello", input: "hello", target: "en")

        guard case .rejected(let emptyWhy, let emptyRetryable) = empty else {
            Issue.record("empty output was accepted")
            return
        }
        #expect(emptyWhy == "empty")
        #expect(!emptyRetryable)

        guard case .rejected(let echoWhy, let echoRetryable) = echoed else {
            Issue.record("echoed input was accepted")
            return
        }
        #expect(echoWhy == "echoed input")
        #expect(echoRetryable)

        guard case .ok(let valid) = TranslationOutputValidator.sanitize(
            "Good morning", input: "guten morgen", target: "en") else {
            Issue.record("valid English translation was rejected")
            return
        }
        #expect(valid == "Good morning")
    }

    @Test("Hy-MT2 loads and translates a real Q4 model",
          .enabled(if: ProcessInfo.processInfo.environment["SAIITY_HYMT2_SMOKE"] == "1"))
    func realModelSmokeTest() async throws {
        let translator = HyMT2Translator()
        do {
            try await translator.prepare(from: "de", to: "en") { _ in }
            let germanToEnglish = await translator.translate(
                "guten morgen", from: "de", to: "en")
            let englishToGerman = await translator.translate(
                "good morning", from: "en", to: "de")
            await translator.stop()

            #expect(germanToEnglish != nil)
            #expect(englishToGerman != nil)
            #expect(germanToEnglish?.caseInsensitiveCompare("guten morgen") != .orderedSame)
            #expect(englishToGerman?.caseInsensitiveCompare("good morning") != .orderedSame)
        } catch {
            await translator.stop()
            throw error
        }
    }
}
