import Testing

@testable import sAiity

@Suite struct CaptionLifecycleTests {
    @Test("clear closes the current display sentence and blocks its translation")
    func clearCurrentSentence() {
        var lifecycle = CaptionDisplayLifecycle()

        lifecycle.clearCurrentSentence()

        #expect(lifecycle.sentenceID == 0)
        #expect(lifecycle.sentenceClosed)
        #expect(lifecycle.isCleared(0))
    }

    @Test("the first update after clear advances to a fresh sentence")
    func nextSentenceAfterClear() {
        var lifecycle = CaptionDisplayLifecycle()
        lifecycle.clearCurrentSentence()

        let advanced = lifecycle.advanceIfNeeded()
        #expect(advanced)
        #expect(lifecycle.sentenceID == 1)
        #expect(!lifecycle.sentenceClosed)
        #expect(!lifecycle.isCleared(1))
        #expect(lifecycle.isCleared(0))
    }

    @Test("clearing twice is idempotent")
    func clearTwice() {
        var lifecycle = CaptionDisplayLifecycle()
        lifecycle.clearCurrentSentence()
        lifecycle.clearCurrentSentence()

        #expect(lifecycle.sentenceID == 0)
        #expect(lifecycle.sentenceClosed)
        #expect(lifecycle.isCleared(0))
        let firstAdvance = lifecycle.advanceIfNeeded()
        let secondAdvance = lifecycle.advanceIfNeeded()
        #expect(firstAdvance)
        #expect(!secondAdvance)
    }

    @Test("ordinary sentence closure advances without marking it cleared")
    func ordinaryClose() {
        var lifecycle = CaptionDisplayLifecycle()
        lifecycle.closeSentence()

        let advanced = lifecycle.advanceIfNeeded()
        #expect(advanced)
        #expect(lifecycle.sentenceID == 1)
        #expect(!lifecycle.isCleared(0))
    }

    @Test("old cleared IDs are retained briefly for late translation suppression")
    func clearedIDsRemainBounded() {
        var lifecycle = CaptionDisplayLifecycle()
        lifecycle.clearCurrentSentence()
        _ = lifecycle.advanceIfNeeded()
        lifecycle.closeSentence()
        _ = lifecycle.advanceIfNeeded()

        #expect(lifecycle.sentenceID == 2)
        #expect(lifecycle.isCleared(0))

        lifecycle.closeSentence()
        _ = lifecycle.advanceIfNeeded()
        #expect(!lifecycle.isCleared(0))
    }
}
