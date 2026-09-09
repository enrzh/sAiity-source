import Testing

@testable import sAiity

struct CaptionHistoryTests {
    @Test("A late translation updates its own retained row")
    func translationUsesSentenceID() {
        var history = CaptionHistory(capacity: 3)
        history.upsertOriginal("first", sentenceID: 1)
        history.upsertOriginal("second", sentenceID: 2)
        history.upsertTranslation("premiere", forSentenceID: 1, stale: true)

        #expect(history.entries[0].translation == "premiere")
        #expect(history.entries[0].translationIsStale)
        #expect(history.entries[1].translation == nil)
    }

    @Test("History is bounded and keeps the newest rows")
    func boundedHistory() {
        var history = CaptionHistory(capacity: 2)
        history.upsertOriginal("one", sentenceID: 1)
        history.upsertOriginal("two", sentenceID: 2)
        history.upsertOriginal("three", sentenceID: 3)

        #expect(history.entries.map(\.sentenceID) == [2, 3])
    }

    @Test("Replacing history respects the configured capacity")
    func replaceIsBounded() {
        var history = CaptionHistory(capacity: 2)
        history.replace(with: [
            CaptionHistoryEntry(sentenceID: 1, original: "one"),
            CaptionHistoryEntry(sentenceID: 2, original: "two"),
            CaptionHistoryEntry(sentenceID: 3, original: "three"),
        ])
        #expect(history.entries.map(\.sentenceID) == [2, 3])
    }
}
