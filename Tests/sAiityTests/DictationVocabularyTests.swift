import Foundation
import Testing

@testable import sAiity

// All dictionary-mutating tests belong here: serialization is suite-local,
// and a locked setter cannot isolate another test's entire arrange/assert flow.
@Suite(.serialized) struct DictationVocabularyTests {
    @Test("readers use one correction generation while settings replaces the cache")
    func concurrentCacheReplacement() {
        let old = DictationVocabulary.corrections
        defer { DictationVocabulary.corrections = old }
        let short: [DictationVocabulary.Correction] = [.init(heard: "raceAlpha", replacement: "short")]
        let long: [DictationVocabulary.Correction] = [
            .init(heard: "raceAlpha", replacement: "longA"),
            .init(heard: "raceBeta", replacement: "longB"),
            .init(heard: "raceGamma", replacement: "longC")
        ]
        DictationVocabulary.corrections = short
        let lock = NSLock()
        var unexpected: [String] = []
        DispatchQueue.concurrentPerform(iterations: 400) { index in
            if index % 3 == 0 { DictationVocabulary.corrections = index % 2 == 0 ? short : long }
            let output = DictationVocabulary.preservingSpelling(in: "raceAlpha raceBeta raceGamma")
            if !["short raceBeta raceGamma", "longA longB longC"].contains(output) {
                lock.withLock { unexpected.append(output) }
            }
        }
        #expect(unexpected.isEmpty)
        let saved = UserDefaults.standard.data(forKey: "dictationCorrections")!
        #expect((try? JSONDecoder().decode([DictationVocabulary.Correction].self, from: saved))
                == DictationVocabulary.corrections)
    }

    @MainActor
    @Test("approved corrections reach cleanup and translation while original ASR remains recoverable")
    func dictionaryBeforeProcessing() async {
        let old = DictationVocabulary.corrections
        defer { DictationVocabulary.corrections = old }
        DictationVocabulary.corrections = [.init(heard: "Ube Eats", replacement: "Uber Eats")]
        let backend = DictationControllerTests.FakeBackend(log: DictationControllerTests.EventLog())
        backend.authoritativeResult = "Please call Ube Eats."
        let inserter = DictationControllerTests.FakeInserter()
        var snapshot: DictationResultSnapshot?
        var cleanupInput = ""
        var translationInput = ""
        let controller = DictationController(makeBackend: { backend },
            capture: DictationControllerTests.FakeCapture(log: DictationControllerTests.EventLog()),
            inserter: inserter, captionsActive: { false },
            translationConfiguration: { .init(enabled: true, target: "de") },
            translate: { text, _, _ in translationInput = text; return "Bitte ruf Uber Eats an." },
            cleanupConfiguration: { .init(enabled: true) },
            cleanup: { text, _ in cleanupInput = text; return text },
            onResult: { snapshot = $0 })
        controller.press()
        await controller.waitForWorkForTests()
        controller.release()
        await controller.waitForWorkForTests()
        #expect(cleanupInput == "Please call Uber Eats.")
        #expect(translationInput == cleanupInput)
        #expect(snapshot?.originalForRecovery == "Please call Ube Eats.")
        #expect(snapshot?.outputText == "Bitte ruf Uber Eats an.")
        #expect(inserter.inserted == ["Bitte ruf Uber Eats an."])
    }

    @MainActor
    @Test("cross-chunk dictionary corrections are applied once and survive timed subtitle export")
    func correctedSentenceExport() throws {
        let old = DictationVocabulary.corrections
        defer { DictationVocabulary.corrections = old }
        DictationVocabulary.corrections = [
            .init(heard: "Ube Eats", replacement: "Uber Eats"),
            .init(heard: "Uber Eats", replacement: "Another company")
        ]
        let app = AppDelegate()
        app.openSentenceForTests(["Please call Ube", "Eats today."], words: [
            .init(start: 0, end: 0.5, text: "Please call Ube "),
            .init(start: 0.5, end: 1, text: "Eats today.")
        ])
        #expect(AppDelegate.joinClauses(app.pendingSentenceForTests) == "Please call Uber Eats today.")
        app.closeSentenceForTests()
        let saved = try #require(app.sessionLinesForTests.first)
        #expect(saved.text == "Please call Uber Eats today.")
        #expect(saved.words == nil)
        #expect(Export.srt([saved]).contains("Uber Eats"))
        #expect(!Export.srt([saved]).contains("Another company"))
    }

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
        let oldTerms = DictationVocabulary.terms
        let old = UserDefaults.standard.object(forKey: "dictationVocabulary")
        defer {
            DictationVocabulary.terms = oldTerms
            if let old { UserDefaults.standard.set(old, forKey: "dictationVocabulary") }
            else { UserDefaults.standard.removeObject(forKey: "dictationVocabulary") }
        }

        DictationVocabulary.serialized = " SwiftUI, swiftui; sAiity\n"
        #expect(DictationVocabulary.terms == ["SwiftUI", "sAiity"])
        #expect(DictationVocabulary.serialized == "SwiftUI, sAiity")
    }

    @Test("validator protects a configured technical term")
    func validatorPreservesVocabulary() {
        let oldTerms = DictationVocabulary.terms
        let old = UserDefaults.standard.object(forKey: "dictationVocabulary")
        defer {
            DictationVocabulary.terms = oldTerms
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
        let oldTerms = DictationVocabulary.terms
        let old = UserDefaults.standard.object(forKey: "dictationVocabulary")
        defer {
            DictationVocabulary.terms = oldTerms
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
