import Foundation
import Testing

@testable import sAiity

@Suite(.serialized) struct DictationVocabularyTests {
    @Test("approved corrections match whole phrases once and preserve punctuation and scripts")
    func explicitCorrections() {
        let old = DictationVocabulary.corrections
        defer { DictationVocabulary.corrections = old }
        DictationVocabulary.corrections = [
            .init(heard: "Ube", replacement: "Other"),
            .init(heard: "Ube Eats", replacement: "Uber Eats"),
            .init(heard: "Uber Eats", replacement: "Something else"),
            .init(heard: "错字", replacement: "正确")
        ]
        #expect(DictationVocabulary.applyingCorrections(in: "Call UBE EATS, not Über or UbeEats.")
                == "Call Uber Eats, not Über or UbeEats.")
        #expect(DictationVocabulary.applyingCorrections(in: "你好，错字。call Ube Eats!")
                == "你好，正确。call Uber Eats!")
        #expect(DictationVocabulary.applyingCorrections(in: "Unrelated wording stays here.")
                == "Unrelated wording stays here.")
    }

    @Test("corrections reject invalid entries, escape regex text and stay bounded")
    func correctionStorageAndBoundaries() {
        let old = DictationVocabulary.corrections
        let oldTerms = DictationVocabulary.terms
        defer { DictationVocabulary.corrections = old; DictationVocabulary.terms = oldTerms }
        DictationVocabulary.terms = ["C++", ".NET"]
        #expect(DictationVocabulary.terms == ["C++", ".NET"])
        DictationVocabulary.corrections = [
            .init(heard: " C++ ", replacement: "C#"),
            .init(heard: "C++", replacement: "Duplicate"),
            .init(heard: "", replacement: "Empty"),
            .init(heard: "same", replacement: "same"),
            .init(heard: "bad\nphrase", replacement: "Bad"),
            .init(heard: String(repeating: "x", count: 65), replacement: "Too long")
        ]
        #expect(DictationVocabulary.corrections == [.init(heard: "C++", replacement: "C#")])
        #expect(DictationVocabulary.applyingCorrections(in: "Use C++ (C++) and C+++; XC++ remains.")
                == "Use C# (C#) and C#+; XC++ remains.")
        DictationVocabulary.corrections = (0..<80).map { .init(heard: "Term \($0)", replacement: "Name \($0)") }
        #expect(DictationVocabulary.corrections.count == 50)
    }

    @Test("dictionary corrections preserve region languages and protect the approved target during cleanup")
    func correctionMetadataAndCleanup() {
        let old = DictationVocabulary.corrections
        defer { DictationVocabulary.corrections = old }
        DictationVocabulary.corrections = [.init(heard: "Ube Eats", replacement: "Uber Eats")]
        let input = DictationTranscriptionResult(regions: [
            .init(text: "Ich denke", language: "de"),
            .init(text: "we should call Ube Eats today.", language: "en")
        ])
        let corrected = DictationVocabulary.applying(to: input)
        #expect(corrected.regions.map(\.language) == input.regions.map(\.language))
        #expect(corrected.languageMetadata.containsMultipleLanguages)
        #expect(corrected.text.contains("Uber Eats"))
        #expect(input.text.contains("Ube Eats"))
        #expect(DictationCleanupValidator.validate("Call Another Company today.",
                                                  preserving: "Call Uber Eats today.") == nil)
    }

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
