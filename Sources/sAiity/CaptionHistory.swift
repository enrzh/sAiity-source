import Foundation

/// One subtitle row retained by the overlay. The sentence id lets a late
/// translation update its original row instead of whichever row is newest.
struct CaptionHistoryEntry: Equatable, Sendable {
    let sentenceID: Int
    var original: String
    var translation: String?
    var translationIsStale = false
}

/// Bounded in-memory history for the live bubble. The transcript remains the
/// durable record; this cap only prevents a long session from growing the
/// overlay's view tree without limit.
struct CaptionHistory: Equatable, Sendable {
    static let defaultCapacity = 50

    let capacity: Int
    private(set) var entries: [CaptionHistoryEntry] = []

    init(capacity: Int = Self.defaultCapacity) {
        self.capacity = max(1, capacity)
    }

    mutating func upsertOriginal(_ text: String, sentenceID: Int) {
        guard !text.isEmpty else { return }
        if let index = entries.firstIndex(where: { $0.sentenceID == sentenceID }) {
            entries[index].original = text
            entries[index].translationIsStale = false
        } else {
            entries.append(CaptionHistoryEntry(sentenceID: sentenceID, original: text))
            trim()
        }
    }

    mutating func upsertTranslation(_ text: String, forSentenceID sentenceID: Int,
                                    stale: Bool) {
        guard let index = entries.firstIndex(where: { $0.sentenceID == sentenceID }) else {
            return
        }
        entries[index].translation = text.isEmpty ? nil : text
        entries[index].translationIsStale = stale && !text.isEmpty
    }

    mutating func markTranslationStale(forSentenceID sentenceID: Int) {
        guard let index = entries.firstIndex(where: { $0.sentenceID == sentenceID }),
              entries[index].translation != nil else { return }
        entries[index].translationIsStale = true
    }

    mutating func replace(with newEntries: [CaptionHistoryEntry]) {
        entries = Array(newEntries.suffix(capacity))
    }

    mutating func clear() {
        entries.removeAll(keepingCapacity: true)
    }

    private mutating func trim() {
        guard entries.count > capacity else { return }
        entries.removeFirst(entries.count - capacity)
    }
}
