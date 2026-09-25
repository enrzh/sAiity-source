import Foundation
import Testing

@testable import sAiity

@Suite(.serialized) struct DictationVocabularyTests {
    @Test("vocabulary is bounded, normalized, and locally persisted")
    func vocabularyStorage() {
        let old = UserDefaults.standard.object(forKey: "dictationVocabulary")
        defer {
            if let old { UserDefaults.standard.set(old, forKey: "dictationVocabulary") }
            else { UserDefaults.standard.removeObject(forKey: "dictationVocabulary") }
        }

        DictationVocabulary.serialized = " SwiftUI, swiftui; sAiity\n"
        #expect(DictationVocabulary.terms == ["SwiftUI", "sAiity"])
        #expect(DictationVocabulary.serialized == "SwiftUI, sAiity")
    }

    @Test("validator protects a configured technical term")
    func validatorPreservesVocabulary() {
        let old = UserDefaults.standard.object(forKey: "dictationVocabulary")
        defer {
            if let old { UserDefaults.standard.set(old, forKey: "dictationVocabulary") }
            else { UserDefaults.standard.removeObject(forKey: "dictationVocabulary") }
        }

        DictationVocabulary.serialized = "SwiftUI"
        #expect(DictationCleanupValidator.validate(
            "Please use SwiftUI.", preserving: "Please use SwiftUI.") != nil)
        #expect(DictationCleanupValidator.validate(
            "Please use Swift UI.", preserving: "Please use SwiftUI.") == nil)
        #expect(LocalLLMTranslator.cleanupUserPrompt(
            "Please use SwiftUI.").contains("SwiftUI"))
    }

    @Test("caption vocabulary preserves exact spelling without inventing terms")
    func captionSpelling() {
        let old = UserDefaults.standard.object(forKey: "dictationVocabulary")
        defer {
            if let old { UserDefaults.standard.set(old, forKey: "dictationVocabulary") }
            else { UserDefaults.standard.removeObject(forKey: "dictationVocabulary") }
        }

        DictationVocabulary.serialized = "SwiftUI, sAiity"
        #expect(DictationVocabulary.preservingSpelling(in: "I use swiftui with saiity")
            == "I use SwiftUI with sAiity")
        #expect(DictationVocabulary.preservingSpelling(in: "unrelated words")
            == "unrelated words")
    }
}
