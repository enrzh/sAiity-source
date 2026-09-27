import Foundation
import NaturalLanguage
import Testing

@testable import sAiity

@Suite struct LanguageRecognizerPoolTests {
    /// A borrowed recognizer still holds the previous caller's `processString`
    /// state. If any of it leaked, a classify could report the *previous*
    /// string's language — a caption labelled in the wrong language, or a
    /// cleanup that picks the wrong filler table. Each result here is compared
    /// against a recognizer built for that one string, so a leak shows up as a
    /// mismatch.
    @Test("a reused recognizer gives the same answer as a fresh one")
    func reuseMatchesFresh() {
        let pool = LanguageRecognizerPool()
        let texts = [
            "we should ship this today",
            "wir müssen das heute ausliefern",
            "nous devons livrer ceci aujourd'hui",
            "the quick brown fox jumps over",
            "wollten wir das Budget verdoppeln",
            "",
            "12345",
            "我们今天要交付这个",
        ]
        for text in texts {
            let pooled = pool.classify(text)
            let fresh = NLLanguageRecognizer()
            fresh.processString(text)
            let expected = fresh.dominantLanguage.map {
                ($0, fresh.languageHypotheses(withMaximum: 1)[$0] ?? 0)
            }
            #expect(pooled?.language == expected?.0, "language differed for \(text)")
            #expect(abs((pooled?.probability ?? 0) - (expected?.1 ?? 0)) < 0.0001,
                    "probability differed for \(text)")
        }
    }

    /// Every classification takes a recognizer out of the pool and puts it back.
    /// If that handoff is not exclusive, two callers share one recognizer and
    /// overwrite each other's hypotheses.
    @Test("concurrent classifies do not share a recognizer")
    func concurrentUse() async {
        let pool = LanguageRecognizerPool()
        let texts = [
            "we should ship this today",
            "wir müssen das heute ausliefern",
            "nous devons livrer ceci aujourd'hui",
            "debemos entregar esto hoy",
        ]
        let expected = texts.map { text -> NLLanguage? in
            let fresh = NLLanguageRecognizer()
            fresh.processString(text)
            return fresh.dominantLanguage
        }

        await withTaskGroup(of: [NLLanguage?].self) { group in
            for _ in 0..<40 {
                group.addTask {
                    texts.map { pool.classify($0)?.language }
                }
            }
            for await result in group {
                #expect(result == expected)
            }
        }
    }

    /// The pool is capped so a burst of parallel work does not turn it into a
    /// retention leak of recognizers nothing will ask for again.
    @Test("the pool is bounded")
    func poolIsBounded() async {
        let pool = LanguageRecognizerPool()
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<64 {
                group.addTask {
                    _ = pool.classify("a longer sentence to classify \(UUID().uuidString)")
                }
            }
        }
        #expect(pool.availableCountForTests <= 4)
    }
}
