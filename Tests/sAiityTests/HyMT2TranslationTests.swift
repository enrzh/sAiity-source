import Foundation
import Testing

@testable import sAiity

@MainActor
struct HyMT2TranslationTests {

    /// Hy-MT2 is a second opinion, not a replacement: it is 1.1 GB against
    /// MADLAD's 1.9 GB but covers 37 languages against 452, so it belongs in the
    /// catalogue and behind the advanced disclosure, never as the default.
    @Test("MADLAD stays the recommended engine, with Hy-MT2 beside it")
    func engineRecommendationIsUnchanged() {
        #expect(TranslationEngine.allCases == [.madlad, .hyMT2])
        #expect(TranslationEngine.recommended.rawValue == "madlad")
        #expect(TranslationEngine.hyMT2.displayName == "Hy-MT2")
        #expect(TranslationEngine.hyMT2 != TranslationEngine.recommended)
        #expect(TranslationEngine.primaryCases == [.madlad])
        #expect(TranslationEngine.advancedCases == [.hyMT2])
        #expect(TranslationEngine.userSelectableCases == [.madlad, .hyMT2])
        #expect(!TranslationEngine.madlad.isAdvanced)
        #expect(TranslationEngine.hyMT2.isAdvanced)
        #expect(TranslationEngine.qwen.isAdvanced)
        // Selectable now, unlike the retired local LLM.
        #expect(TranslationEngine.visibleSelection(.hyMT2) == .hyMT2)
        #expect(TranslationEngine.visibleSelection(.qwen) == nil)
        #expect(TranslationEngine.visibleSelection(.madlad) == .madlad)
        #expect(TranslationEngine.visibleSelection(nil) == nil)
    }

    /// Two engines with very different coverage is a new failure mode: a stored
    /// target outlives an engine swap, so the fallback must not switch to an
    /// engine that cannot translate into it. Cantonese is the one place the two
    /// sets actually differ, and it is why `resolve` takes a target.
    @Test("the fallback refuses a target the other engine cannot reach")
    func fallbackRespectsTheTarget() {
        var fallback = TranslationRuntimeFallback()
        fallback.quarantine(.hyMT2)

        // German is in both sets, so the fallback is fine.
        #expect(LanguageCatalog.supportedCodes(for: .madlad).contains("de"))
        #expect(fallback.resolve(.hyMT2, for: "de") == .madlad)

        // Cantonese is Hy-MT2's alone. Falling back would swap a working
        // translator for one that declines every line, which is the silent
        // failure this all exists to avoid.
        #expect(LanguageCatalog.supportedCodes(for: .hyMT2).contains("yue"))
        #expect(!LanguageCatalog.supportedCodes(for: .madlad).contains("yue"))
        #expect(fallback.resolve(.hyMT2, for: "yue") == nil)

        // No target to check against keeps the old unconditional behaviour.
        #expect(fallback.resolve(.hyMT2) == .madlad)
    }

    @Test("Hy-MT2 covers strictly fewer languages than MADLAD")
    func coverageIsNarrowerThanTheWiderEngine() async {
        let hy = await LanguageCatalog.supportedCodes(for: .hyMT2)
        let madlad = await LanguageCatalog.supportedCodes(for: .madlad)
        #expect(!hy.isEmpty)
        #expect(hy.count < madlad.count, "the point of the second engine is less coverage")
    }

    /// The fallback direction the second engine buys: a broken Hy-MT2 degrades to
    /// MADLAD. A broken MADLAD still has nowhere to go, which is why the failure
    /// budget still needs sustained failure before retiring anything.
    @Test("a retired Hy-MT2 falls back to MADLAD")
    func retirementDegradesInsteadOfEnding() {
        var fallback = TranslationRuntimeFallback()
        #expect(fallback.resolve(.hyMT2) == .hyMT2)
        fallback.quarantine(.hyMT2)
        #expect(fallback.resolve(.hyMT2) == .madlad)
        #expect(fallback.resolve(.madlad) == .madlad)

        // Both gone: translation is over, and it says so rather than pretending.
        fallback.quarantine(.madlad)
        #expect(fallback.resolve(.hyMT2) == nil)
        #expect(fallback.resolve(.madlad) == nil)
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

    @Test("retired Hy-MT2 data has one fixed Q4 cleanup descriptor")
    func retiredRegistryDescriptorIsComplete() {
        let matching = ModelRegistry.retiredAssets().filter { $0.id == AssetID.hyMT2 }
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
            let germanToEnglish = try await translator.translate(
                "guten morgen", from: "de", to: "en")
            let englishToGerman = try await translator.translate(
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
