import Testing

@testable import sAiity

@Suite struct TranslationOutputValidatorTests {
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
