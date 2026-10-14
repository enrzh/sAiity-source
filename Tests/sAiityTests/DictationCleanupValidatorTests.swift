import Foundation
import Testing

@testable import sAiity

@Suite struct DictationCleanupValidatorTests {
    @Test("unhandled cleanup languages preserve borrowed English words and formatting phrases")
    func pql4UnhandledLanguagePreservesWords() {
        let cases = [
            ("Well, ripoti hii inaeleza neno new line na maana yake.", "sw"),
            ("یہ لفظ new line عام طور پر استعمال ہوتا ہے۔", "ur"),
            ("এই বাক্যে new paragraph শব্দটির অর্থ ব্যাখ্যা করা হয়েছে।", "bn"),
        ]
        for (text, language) in cases {
            #expect(DictationCleanupValidator.deterministicCleanup(text, sourceLanguage: language) == text)
        }
    }

    @Test("meaningful emphasis and negation repetitions are preserved")
    func pql4MeaningfulRepetitionSurvives() {
        for text in ["This is very very important.", "No no, do not send this.", "Das ist sehr sehr wichtig."] {
            #expect(DictationCleanupValidator.deterministicCleanup(text) == text)
        }
        #expect(DictationCleanupValidator.validate("No, do not send this.",
                                                  preserving: "No no, do not send this.",
                                                  sourceLanguage: "en") == nil)
    }

    @Test("a comma does not erase negation and mixed cleanup retains each meaningful span")
    func pql4WholeSpanMeaning() {
        #expect(DictationCleanupValidator.validate("I said yes, one may enter.",
            preserving: "I said yes, no one may enter.", sourceLanguage: "en") == nil)
        #expect(DictationCleanupValidator.validate("Ich sagte ja, jemand darf eintreten.",
            preserving: "Ich sagte ja, nein niemand darf eintreten.", sourceLanguage: "de") == nil)
        let input = "Bitte öffne die Rechnung. Then delete the backup permanently."
        let metadata = DictationLanguageMetadata(regions: [
            .init(text: "Bitte öffne die Rechnung.", language: "de"),
            .init(text: "Then delete the backup permanently.", language: "en")
        ])
        #expect(DictationCleanupValidator.validate("Bitte öffne die Rechnung. Then.",
            preserving: input, languageMetadata: metadata) == nil)
        #expect(DictationCleanupValidator.validate(input, preserving: input, languageMetadata: metadata) != nil)
    }

    @Test("cleanup permits equivalent localized digits without dropping a repeated numeric fact")
    func pql4NumericFactsSurviveCleanup() {
        #expect(DictationCleanupValidator.validate("أرسل 1.5 لتر إلى الفريق غدا.",
            preserving: "أرسل ١٫٥ لتر إلى الفريق غدا.", sourceLanguage: "ar") != nil)
        #expect(DictationCleanupValidator.validate("أرسل 15 لتر إلى الفريق غدا.",
            preserving: "أرسل ١٫٥ لتر إلى الفريق غدا.", sourceLanguage: "ar") == nil)
        #expect(DictationCleanupValidator.validate("Send 2 copies to the team.",
            preserving: "Send 2 copies to 2 teams.", sourceLanguage: "en") == nil)
        #expect(DictationCleanupValidator.validate("Sende 1234 Liter an das Team.",
            preserving: "Sende 1,234 Liter an das Team.", sourceLanguage: "de") == nil)
        #expect(DictationCleanupValidator.validate("Sende 1.234 Liter an das Team.",
            preserving: "Sende 1,234 Liter an das Team.", sourceLanguage: "de") == nil)
    }

    @Test("clean dictation skips the cleanup model")
    func cleanTextSkipsModel() {
        #expect(!DictationCleanupValidator.needsModelCleanup("Please send the report today."))
        #expect(!DictationCleanupValidator.needsModelCleanup("Um, please please send the report.", sourceLanguage: "en"))
        #expect(DictationCleanupValidator.needsModelCleanup("Send the report, I mean the revised report."))
        #expect(DictationCleanupValidator.needsModelCleanup("Morgen, nein, besser gesagt am Freitag.", sourceLanguage: "de"))
        #expect(!DictationCleanupValidator.needsModelCleanup("你好，send the report.", sourceLanguage: "en"))
        #expect(!DictationCleanupValidator.needsModelCleanup("Envoyez le rapport.", sourceLanguage: "fr"))
        #expect(!DictationCleanupValidator.needsModelCleanup("Envía el informe mañana.", sourceLanguage: "es"))
        #expect(!DictationCleanupValidator.needsModelCleanup("明日レポートを送ってください。", sourceLanguage: "ja"))
    }

    @Test("internal pause dots need contextual cleanup without stripping source punctuation")
    func pauseDotsNeedContext() {
        for text in ["That shouldn't happen when you... are adding items to the card.",
                     "That shouldn't happen when you… are adding items to the card."] {
            let outcome = DictationCleanupValidator.deterministicOutcome(text, sourceLanguage: "en")
            #expect(outcome.needsModel)
            #expect(outcome.baseline == text)
        }
        #expect(!DictationCleanupValidator.needsModelCleanup("I'm not sure...", sourceLanguage: "en"))
        #expect(!DictationCleanupValidator.needsModelCleanup("Wait ellipsis please.", sourceLanguage: "en"))
        #expect(DictationCleanupValidator.needsModelCleanup("I can't... tell.", sourceLanguage: "en"))
    }

    @Test("pause punctuation inside quotes and code never triggers contextual editing")
    func pauseDotsInLiterals() {
        for literal in ["\"Wait... please\"", "“Wait... please”", "'Wait... please'",
                        "‘Wait... please’", "«Wait... please»", "`wait...please`",
                        "```\nwait...please\n```", "「待って…ください」", "'I can't... tell'",
                        "‘I can’t... tell’", "“I mean... please”"] {
            let text = "He wrote \(literal) on the sign."
            #expect(!DictationCleanupValidator.needsModelCleanup(text, sourceLanguage: "en"))
            #expect(DictationCleanupValidator.deterministicCleanup(text, sourceLanguage: "en") == text)
        }
    }

    @Test("pause-only cleanup cannot invent gap words or alter quoted punctuation")
    func pauseDotsOnlyPermitPunctuation() {
        let input = "I need to... send the report. The label is “Wait... please”."
        let cleaned = "I need to send the report. The label is “Wait... please”."
        #expect(DictationCleanupValidator.validate(cleaned, preserving: input, sourceLanguage: "en") == cleaned)
        for changed in [
            "I need to urgently send the report. The label is “Wait... please”.",
            "I need to send the report. The label is “Wait please”.",
            "I need to send the report. The label is “Wait… please”.",
        ] {
            #expect(DictationCleanupValidator.validate(changed, preserving: input, sourceLanguage: "en") == nil)
        }
    }

    @Test("pause-only editing keeps every literal occurrence and its exact Unicode bytes")
    func pauseDotsLiteralIdentity() {
        let input = "I need to... send the report. The label is “Cafe\u{301}... please”."
        let normalized = "I need to send the report. The label is “Café... please”."
        #expect(DictationCleanupValidator.validate(normalized, preserving: input, sourceLanguage: "en") == nil)
        let repeated = "I need to... send the report. The labels are “Wait... please” and “Wait... please”."
        let changed = "I need to send the report. The labels are “Wait please” and “Wait... please”."
        #expect(DictationCleanupValidator.validate(changed, preserving: repeated, sourceLanguage: "en") == nil)
    }

    @Test("literal correction markers cannot permit invented pause words")
    func pauseDotsQuotedRepairIsLiteral() {
        let input = "I need to... send the report. The label is “I mean... please”."
        let changed = "I need to urgently send the report. The label is “I mean... please”."
        #expect(DictationCleanupValidator.validate(changed, preserving: input, sourceLanguage: "en") == nil)
    }

    @Test("cleanup validator applies only the documented plain-text rules")
    func documentedRules() {
        #expect(DictationCleanupValidator.validate(" \n hello \t\n") == "hello")
        #expect(DictationCleanupValidator.validate("\u{0000}\u{0009}") == nil)
        #expect(DictationCleanupValidator.validate("```text\nhello\n```") == nil)
        for prefix in ["Here is", "Here's", "Cleaned transcript:", "Cleaned text:", "The cleaned transcript is:"] {
            #expect(DictationCleanupValidator.validate(prefix + " hello") == nil)
        }
        #expect(DictationCleanupValidator.validate("first\n\nsecond") == nil)
        #expect(DictationCleanupValidator.validate("hello\nworld") == "hello\nworld")
    }

    @Test("cleanup preserves strong tokens from the transcript")
    func strongTokensMustSurvive() {
        let input = "Send the report to team@example.com on 2026-08-31 at https://aiity.de/docs."
        #expect(DictationCleanupValidator.validate(
            "Send the report to team@example.com on 2026-08-31 at https://aiity.de/docs.",
            preserving: input) != nil)
        #expect(DictationCleanupValidator.validate(
            "Send the report to team@example.com on 2026-08-30 at https://aiity.de/docs.",
            preserving: input) == nil)
        #expect(DictationCleanupValidator.validate(
            "Send the report to team@example.com on 2026-08-31.",
            preserving: input) == nil)
    }

    @Test("cleanup rejects a translated result and keeps the spoken language")
    func translatedResultIsRejected() {
        let input = "Please send the revised contract to the legal team before Friday morning."
        let translated = "Bitte senden Sie den überarbeiteten Vertrag vor Freitagmorgen an das Rechtsteam."
        #expect(DictationCleanupValidator.validate(translated,
                                                   preserving: input,
                                                   sourceLanguage: "en-US") == nil)
    }

    @Test("cleanup rejects a translation even when ASR reports the wrong source language")
    func translatedResultDoesNotTrustStaleSourceMetadata() {
        let input = "Please send the revised contract to the legal team before Friday morning."
        let translated = "Bitte senden Sie den überarbeiteten Vertrag vor Freitagmorgen an das Rechtsteam."
        #expect(DictationCleanupValidator.validate(translated,
                                                   preserving: input,
                                                   sourceLanguage: "de-DE") == nil)
    }

    @Test("cleanup rejects a translated short utterance")
    func translatedShortResultIsRejected() {
        #expect(DictationCleanupValidator.validate("Ruf jetzt an.",
                                                   preserving: "Call now.",
                                                   sourceLanguage: "en-US") == nil)
    }

    @Test("cleanup rejects a translation from a language outside the recognizer allow-list")
    func translatedRareLanguageResultIsRejected() {
        let input = "Habari yako rafiki, natumaini uko salama leo."
        let translated = "Hello my friend, I hope you are safe today."
        #expect(DictationCleanupValidator.validate(translated,
                                                   preserving: input,
                                                   sourceLanguage: "sw-TZ") == nil)
    }

    @Test("cleanup accepts conservative filler and self-correction edits")
    func conservativeSpeechEditIsAccepted() {
        let input = "Um, schedule a meeting with Sara, actually Sarah, tomorrow at 3."
        let output = "Schedule a meeting with Sarah tomorrow at 3."
        #expect(DictationCleanupValidator.validate(output, preserving: input) == output)
    }

    @Test("deterministic cleanup removes fillers, repetition, and a self-correction")
    func deterministicSpeechCleanup() {
        let input = "Um, please please call Sara, actually Sarah, uh, today."
        #expect(DictationCleanupValidator.deterministicCleanup(input) ==
            "Please call Sarah today.")
    }

    @Test("deterministic cleanup removes a spoken confirmation repair")
    func deterministicConfirmationRepair() {
        let input = "Go to YouTube, um, then search for MrBeast? Yes, MrBeast is the name."
        #expect(DictationCleanupValidator.deterministicCleanup(input) ==
            "Go to YouTube, then search for MrBeast.")
    }

    @Test("deterministic cleanup turns spoken layout commands into a list")
    func spokenLayoutCommandsBecomeStructure() {
        let input = "Bullet point buy milk comma bullet point call Anna comma bullet point send the invoice."
        #expect(DictationCleanupValidator.deterministicCleanup(input) ==
            "• Buy milk,\n• Call Anna,\n• Send the invoice.")
    }

    @Test("deterministic cleanup understands localized layout commands")
    func localizedLayoutCommandsBecomeStructure() {
        #expect(DictationCleanupValidator.deterministicCleanup(
            "Aufzählungspunkt milch kaufen Aufzählungspunkt Anna anrufen",
            sourceLanguage: "de-DE") ==
            "• Milch kaufen\n• Anna anrufen")
        #expect(DictationCleanupValidator.deterministicCleanup(
            "Viñeta comprar leche viñeta llamar a Ana",
            sourceLanguage: "es-ES") ==
            "• Comprar leche\n• Llamar a Ana")
    }

    @Test("filler phrases are removed only in discourse positions")
    func contextualFillerPhrases() {
        #expect(DictationCleanupValidator.deterministicCleanup(
            "You know, send the report, well, today.") ==
            "Send the report today.")
        #expect(DictationCleanupValidator.deterministicCleanup(
            "You know the answer.") ==
            "You know the answer.")
    }

    @Test("filler detection respects the spoken language")
    func languageAwareFillers() {
        #expect(DictationCleanupValidator.deterministicCleanup(
            "Ähm, also, bitte sende den Bericht.", sourceLanguage: "de-DE") ==
            "Bitte sende den Bericht.")
        #expect(DictationCleanupValidator.deterministicCleanup(
            "Um... Ja", sourceLanguage: "de-DE") == "Ja")
        #expect(DictationCleanupValidator.deterministicCleanup(
            "Wir treffen uns um 8 Uhr.", sourceLanguage: "de-DE") ==
            "Wir treffen uns um 8 Uhr.")
        #expect(DictationCleanupValidator.deterministicCleanup(
            "Um relatório sobre amanhã.", sourceLanguage: "pt-BR") ==
            "Um relatório sobre amanhã.")
        #expect(DictationCleanupValidator.deterministicCleanup(
            "ええと、明日レポートを送ってください。", sourceLanguage: "ja-JP") ==
            "明日レポートを送ってください。")
        #expect(DictationCleanupValidator.deterministicCleanup(
            "Envoyez le rapport demain\\", sourceLanguage: "fr-FR") ==
            "Envoyez le rapport demain")
    }

    @Test("cleanup removes model-added outer quotes")
    func modelAddedQuotesAreRemoved() {
        let input = "Please send the report today."
        #expect(DictationCleanupValidator.validate(
            "\"Please send the report today.\"", preserving: input) == input)
        #expect(DictationCleanupValidator.validate(
            "\"Say \"hello\" to the team.\"", preserving: "Say \"hello\" to the team.") ==
            "Say \"hello\" to the team.")
    }

    @Test("cleanup rejects an implausibly large rewrite")
    func implausibleRewriteFallsBack() {
        let input = "Please send the revised contract to the legal team before Friday morning."
        #expect(DictationCleanupValidator.validate("Done.", preserving: input) == nil)
        #expect(DictationCleanupValidator.validate(
            "Please send the revised contract to the legal team before Friday morning, and then call me to confirm the delivery after you have checked every attachment and copied the project manager.",
            preserving: input) == nil)
    }

    @Test("cleanup rejects the LLM empty-output placeholder")
    func emptyOutputPlaceholderFallsBack() {
        #expect(DictationCleanupValidator.validate("...", preserving: "hello there") == nil)
    }

    @Test("cleanup keeps literal formatting mentions, negation and uncertainty")
    func meaningAndCommandEligibility() {
        #expect(!DictationCleanupValidator.needsModelCleanup("I like Swift and it works well."))
        #expect(!DictationCleanupValidator.needsModelCleanup("Nein, das stimmt nicht.", sourceLanguage: "de"))
        for value in ["We need a new line of products.", "Take a bullet train.", "The period lasted two weeks."] {
            #expect(DictationCleanupValidator.deterministicCleanup(value, sourceLanguage: "en") == value)
        }
        #expect(DictationCleanupValidator.deterministicCleanup("Das ist ein wichtiger Punkt.", sourceLanguage: "de") == "Das ist ein wichtiger Punkt.")
        #expect(DictationCleanupValidator.validate("Please send the report.", preserving: "Please do not send the report.") == nil)
        #expect(DictationCleanupValidator.validate("Send it tomorrow.", preserving: "Maybe send it tomorrow.") == nil)
        #expect(DictationCleanupValidator.validate("Das stimmt.", preserving: "Das stimmt nicht.", sourceLanguage: "de") == nil)
    }

    @Test("cleanup prompt describes a conservative speech editor")
    func promptContract() {
        let prompt = LocalLLMTranslator.cleanupFastSystemPrompt.lowercased()
        #expect(prompt.contains("filler"))
        #expect(prompt.contains("self-correction"))
        #expect(prompt.contains("bullet point"))
        #expect(prompt.contains("new line"))
        #expect(prompt.contains("numbers"))
        #expect(prompt.contains("never summarize"))
        #expect(prompt.contains("output only"))
        #expect(prompt.contains("negation"))
        #expect(prompt.contains("spoken content"))
        #expect(LocalLLMTranslator.cleanupUserPrompt("hello").lowercased().contains("json string"))
    }

    @Test("cleanup prompt carries the source language without making it a translation request")
    func promptCarriesSourceLanguage() {
        let prompt = LocalLLMTranslator.cleanupUserPrompt(
            "hallo, ich brauche hilfe",
            sourceLanguage: "de-DE").lowercased()
        #expect(prompt.contains("de-de"))
        #expect(prompt.contains("same language"))
        #expect(prompt.contains("never translate"))
    }

    @Test("cleanup accepts conservative edits across supported and long-tail scripts")
    func languageMatrixPreservesSpokenLanguage() {
        let cases: [(input: String, output: String, source: String)] = [
            ("Ähm, bitte sende den Bericht morgen.",
             "Bitte sende den Bericht morgen.", "de-DE"),
            ("Euh, envoie le rapport demain.",
             "Envoie le rapport demain.", "fr-FR"),
            ("Um, envía el informe mañana.",
             "Envía el informe mañana.", "es-ES"),
            ("مرحبا، أرسل التقرير غدا.",
             "أرسل التقرير غدا.", "ar-SA"),
            ("ええと、明日レポートを送ってください。",
             "明日レポートを送ってください。", "ja-JP"),
        ]

        for item in cases {
            #expect(DictationCleanupValidator.validate(
                item.output,
                preserving: item.input,
                sourceLanguage: item.source) == item.output)
        }
    }

    @Test("cleanup rejects assistant-style output instead of inserting it")
    func assistantStyleOutputIsRejected() {
        let input = "Please send the revised contract tomorrow."
        #expect(DictationCleanupValidator.validate(
            "Here is the cleaned transcript: Please send the revised contract tomorrow.",
            preserving: input) == nil)
        #expect(DictationCleanupValidator.validate(
            "I cannot help with that request.",
            preserving: input) == nil)
    }

}
