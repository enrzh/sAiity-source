import Testing

@testable import sAiity

@Suite struct TranslationOutputValidatorTests {
    @Test("an identifier must be a complete source token rather than part of another word")
    func pql4IdentifierBoundary() {
        for (output, input) in [("DAS", "The dashboard."), ("BITTE", "The bitter flower.")] {
            guard case .rejected = TranslationOutputValidator.sanitize(output, input: input, target: "en") else {
                Issue.record("substring mistaken for preserved identifier: \(output)"); continue
            }
        }
        for (output, input) in [("API", "Use API here."), ("OpenAI", "OpenAIの結果を確認します。"),
                                ("MÜLLER", "Bitte MÜLLER anrufen.")] {
            guard case .ok = TranslationOutputValidator.sanitize(output, input: input, target: "en") else {
                Issue.record("a preserved identifier or name was rejected"); continue
            }
        }
    }

    @Test("explicit Chinese script requests convert model output without editing the source")
    func pql4RequestedOutputScript() {
        let simplified = "我们今天需要检查这张发票并讨论会议安排。"
        let traditional = "我們今天需要檢查這張發票並討論會議安排。"
        for (raw, expected, target) in [(simplified, traditional, "zh-Hant"),
                                        (traditional, simplified, "zh-Hans")] {
            guard case .ok(let output) = TranslationOutputValidator.sanitize(raw,
                input: "We need to check this invoice and discuss the meeting arrangements today.", target: target) else {
                Issue.record("script conversion rejected"); continue
            }
            #expect(output == expected)
            #expect(TranslationLanguage.satisfiesOutputVariant(in: output, target: target))
        }
    }

    @Test("numeric guards retain Unicode signs grouping and multiplicity")
    func pql4NumericEdges() {
        for (source, output) in [
            ("−1,5", "-1.5"), ("१.५", "1.5"), ("２５００", "2,500"),
            ("2\u{202F}500", "2,500"), ("1,000 and 1.0", "1 and 1000")
        ] {
            #expect(TranslationOutputValidator.preservesNumericFacts(source, in: output))
        }
        for (source, output) in [
            ("−1,5", "1.5"), ("2 and 2", "2"), ("12", "12 and 13"),
            ("2026-08-31", "2026-08-30"), ("2026-10-09", "2026-09-10")
        ] {
            #expect(!TranslationOutputValidator.preservesNumericFacts(source, in: output))
        }
    }

    @Test("short grammatical output and capitalized words do not become identifiers")
    func pql4ShortForeignGrammar() {
        for (output, input) in [("待って", "Wait!"), ("BITTE", "Please"), ("DAS", "the")] {
            guard case .rejected(_, let retryable) = TranslationOutputValidator.sanitize(output, input: input, target: "en") else {
                Issue.record("short untranslated grammar accepted: \(output)"); continue
            }
            #expect(retryable)
        }
    }

    @Test("currency markers stay attached to their numeric facts")
    func pql4CurrencyFacts() {
        for (input, output) in [("$5", "€5"), ("$5 and €10", "$10 and €5"),
                                ("USD 5", "EUR 5")] {
            guard case .rejected = TranslationOutputValidator.sanitize(output, input: input, target: "en") else {
                Issue.record("currency changed without rejection"); continue
            }
        }
        guard case .ok = TranslationOutputValidator.sanitize("5$", input: "$5", target: "en") else {
            Issue.record("unchanged currency and amount rejected"); return
        }
    }

    @Test("clearly untranslated grammatical spans cannot hide behind the dominant output language")
    func pql4UntranslatedGrammarIsRejected() {
        let cases = [
            ("Please 確認してください before continuing with the meeting.", "会議を続ける前に確認してください。", "en"),
            ("Bitte أرسل التقرير غدا vor dem nächsten Treffen.", "Please send the report tomorrow before the next meeting.", "de"),
        ]
        for (output, input, target) in cases {
            guard case .rejected(_, let retryable) = TranslationOutputValidator.sanitize(output, input: input, target: target) else {
                Issue.record("incomplete translation accepted")
                continue
            }
            #expect(retryable)
        }
    }

    @Test("legitimate Japanese scripts and ambiguous names are allowed in output")
    func pql4ValidScriptsAndNames() {
        let cases = [
            ("明日の会議は東京で行います。", "Tomorrow's meeting will be held in Tokyo.", "ja"),
            ("会议", "meeting", "zh-Hans"),
            ("The meeting takes place in 東京 tomorrow.", "明日の会議は東京で行います。", "en"),
            ("Swift APIの結果を確認してください。", "Please check the Swift API result.", "ja"),
        ]
        for (output, input, target) in cases {
            guard case .ok = TranslationOutputValidator.sanitize(output, input: input, target: target) else {
                Issue.record("valid scripts or name rejected")
                continue
            }
        }
    }

    @Test("localized numerals preserve decimal values and every numeric fact")
    func pql4NumeralsPreserveFacts() {
        for (output, input, target) in [
            ("Send 1.5 liters to the team tomorrow.", "أرسل ١٫٥ لتر إلى الفريق غدا.", "en"),
            ("أرسل ٢٬٥٠٠ عنصر إلى الفريق غدا.", "Send 2,500 items to the team tomorrow.", "ar"),
        ] {
            guard case .ok = TranslationOutputValidator.sanitize(output, input: input, target: target) else {
                Issue.record("equivalent localized numeric value rejected")
                continue
            }
        }
        for (output, input) in [
            ("Send 15 liters to the team tomorrow.", "Sende 1,5 Liter an das Team morgen."),
            ("Send 2 copies to the team.", "Sende 2 Kopien an 2 Teams."),
        ] {
            guard case .rejected = TranslationOutputValidator.sanitize(output, input: input, target: "en") else {
                Issue.record("changed or omitted numeric fact accepted")
                continue
            }
        }
    }

    @Test("translation accepts unchanged identifiers and genuinely shared short phrases")
    func validEchoes() {
        for (source, target) in [("OpenAI", "de"), ("API", "fr"), ("Müller", "en"), ("No.", "es"), ("OK", "ja")] {
            guard case .ok = TranslationOutputValidator.sanitize(source, input: source, target: target) else {
                Issue.record("valid unchanged content rejected"); continue
            }
        }
        guard case .rejected = TranslationOutputValidator.sanitize("Hello world", input: "Hello world", target: "de") else {
            Issue.record("untranslated sentence accepted"); return
        }
        guard case .rejected = TranslationOutputValidator.sanitize("Hello", input: "Hello", target: "de") else {
            Issue.record("ordinary greeting accepted as a name"); return
        }
    }

    @Test("translation preserves formatting and numeric values across locale separators")
    func formattingAndNumbers() {
        guard case .ok(let text) = TranslationOutputValidator.sanitize("• 1.000 Einträge\n• 25 Benutzer", input: "• 1,000 entries\n• 25 users", target: "de") else {
            Issue.record("valid formatting rejected"); return
        }
        #expect(text.contains("\n"))
        guard case .rejected = TranslationOutputValidator.sanitize("Send 21 items.", input: "Sende 12 Artikel.", target: "en") else {
            Issue.record("changed number accepted"); return
        }
    }
}
