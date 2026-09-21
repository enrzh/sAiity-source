import Foundation

/// Keeps manual display clearing separate from recognition state.
///
/// A clear must hide the current row without making the next ASR update wait
/// for punctuation or a speech gap. Cleared IDs stay blocked long enough for a
/// late translation to resolve without repainting the bubble.
struct CaptionDisplayLifecycle: Equatable, Sendable {
    private(set) var sentenceID = 0
    private(set) var sentenceClosed = false
    private(set) var clearedSentenceIDs: Set<Int> = []

    mutating func clearCurrentSentence() {
        clearedSentenceIDs.insert(sentenceID)
        sentenceClosed = true
    }

    mutating func closeSentence() {
        sentenceClosed = true
    }

    @discardableResult
    mutating func advanceIfNeeded() -> Bool {
        guard sentenceClosed else { return false }
        sentenceClosed = false
        sentenceID += 1
        clearedSentenceIDs = clearedSentenceIDs.filter { $0 >= sentenceID - 2 }
        return true
    }

    func isCleared(_ id: Int) -> Bool {
        clearedSentenceIDs.contains(id)
    }
}
