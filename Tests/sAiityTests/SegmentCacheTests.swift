import Foundation
import Testing

@testable import sAiity

@Suite struct SegmentCacheTests {
    private static func segments(_ count: Int, characters: Int = 16) -> [Segment] {
        let text = String(repeating: "a", count: characters)
        return (0..<count).map { index in
            Segment(i: index, t0: 0, t1: 1, text: text, loc: "en", tr: nil,
                    trLoc: nil, words: nil)
        }
    }

    private static let stamp = SegmentCache.Stamp(modified: Date(timeIntervalSince1970: 0), size: 1)

    /// What one ten-segment entry weighs against the budget: ten texts of 16
    /// UTF-8 bytes, plus the per-segment overhead `cost` adds.
    private static let entryCost = 10 * (16 + 64)

    @Test("a stored session is served back until its stamp changes")
    func servesUntilTheStampChanges() {
        let cache = SegmentCache(maxBytes: 1 << 20)
        cache.store(Self.segments(2), for: "a", stamp: Self.stamp)
        #expect(cache.value(for: "a", stamp: Self.stamp)?.count == 2)

        // A re-translation rewrites the file, so the stamp moves and the entry
        // has to be re-read rather than served stale.
        let rewritten = SegmentCache.Stamp(modified: Date(timeIntervalSince1970: 1), size: 2)
        #expect(cache.value(for: "a", stamp: rewritten) == nil)
    }

    /// The whole reason the cache is bounded by bytes. A count cap that flushed
    /// at the ceiling scored a provable 0% hit rate on a search sweep, because
    /// the sweep evicts as it goes and arrives at the end with nothing.
    @Test("the byte budget evicts oldest first rather than flushing")
    func evictsOldestFirst() {
        // Room for three entries. Six inserts therefore evict the three oldest
        // one at a time, and the three newest must survive — a cap that flushed
        // the whole map at the ceiling would leave nothing.
        let cache = SegmentCache(maxBytes: 3 * Self.entryCost)

        for index in 0..<6 {
            cache.store(Self.segments(10), for: "\(index)", stamp: Self.stamp)
        }

        for index in 0..<3 {
            #expect(cache.value(for: "\(index)", stamp: Self.stamp) == nil,
                    "entry \(index) should have been evicted")
        }
        for index in 3..<6 {
            #expect(cache.value(for: "\(index)", stamp: Self.stamp)?.count == 10,
                    "entry \(index) should have survived")
        }
    }

    /// Re-storing a path replaces its entry rather than adding a second copy.
    /// The byte total has to account for the replacement, or the budget drifts
    /// upwards and the cache grows without bound.
    @Test("re-storing a path does not double-count it")
    func reStoreDoesNotDoubleCount() {
        // Room for exactly two entries.
        let cache = SegmentCache(maxBytes: 2 * Self.entryCost)
        cache.store(Self.segments(10), for: "a", stamp: Self.stamp)

        // Rewrites of the same path must not eat the budget. A re-translation
        // rewrites the file and this is the path that lands here.
        for _ in 0..<5 {
            cache.store(Self.segments(10), for: "a", stamp: Self.stamp)
        }
        #expect(cache.value(for: "a", stamp: Self.stamp)?.count == 10)

        // And there is still room for one more, which a drifting counter would
        // not allow.
        cache.store(Self.segments(10), for: "b", stamp: Self.stamp)
        #expect(cache.value(for: "a", stamp: Self.stamp)?.count == 10)
        #expect(cache.value(for: "b", stamp: Self.stamp)?.count == 10)
    }

    @Test("invalidating one session leaves the rest of the cache alone")
    func invalidateOnePath() {
        let cache = SegmentCache(maxBytes: 1 << 20)
        cache.store(Self.segments(2), for: "a", stamp: Self.stamp)
        cache.store(Self.segments(2), for: "b", stamp: Self.stamp)

        cache.invalidate(path: "a")
        #expect(cache.value(for: "a", stamp: Self.stamp) == nil)
        #expect(cache.value(for: "b", stamp: Self.stamp)?.count == 2)
    }

    @Test("invalidating everything empties the cache")
    func invalidateAll() {
        let cache = SegmentCache(maxBytes: 1 << 20)
        cache.store(Self.segments(2), for: "a", stamp: Self.stamp)
        cache.store(Self.segments(2), for: "b", stamp: Self.stamp)

        cache.invalidate()
        #expect(cache.value(for: "a", stamp: Self.stamp) == nil)
        #expect(cache.value(for: "b", stamp: Self.stamp) == nil)
    }
}
