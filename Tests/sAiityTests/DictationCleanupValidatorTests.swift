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
}
