import Foundation
import Testing

@testable import sAiity

@Suite struct DictationCleanupValidatorTests {
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

    @Test("cleanup prompt describes a conservative speech editor")
    func promptContract() {
        let prompt = LocalLLMTranslator.cleanupSystemPrompt.lowercased()
        #expect(prompt.contains("filler"))
        #expect(prompt.contains("self-correction"))
        #expect(prompt.contains("numbers"))
        #expect(prompt.contains("never summarize"))
        #expect(prompt.contains("output only"))
        #expect(prompt.contains("tomorrow, actually friday morning"))
        #expect(LocalLLMTranslator.cleanupUserPrompt("hello").lowercased().contains("<transcript>"))
    }

}
