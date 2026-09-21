import Foundation
import Testing

@testable import sAiity

@MainActor
struct TranscriptStoreTests {
    @Test("bubble saves a complete transcript as a library session")
    func saveSessionRoundTrip() throws {
        let segments = [
            Segment(i: 0, t0: 0, t1: 1.2, text: "Hallo world", loc: "de",
                    tr: "Hello world", trLoc: "en", words: nil),
            Segment(i: 1, t0: 1.3, t1: 2.4, text: "你好", loc: "zh",
                    tr: "Hello", trLoc: "en", words: nil,
                    speaker: "speaker-1")
        ]
        let session = try TranscriptStore.saveSession(segments, locale: "de-DE",
                                                       translateTo: "en",
                                                       startedAt: Date(timeIntervalSince1970: 1_800_000_000))
        defer { TranscriptStore.delete(session) }

        #expect(session.meta.lineCount == 2)
        #expect(session.meta.locale == "de-DE")
        #expect(session.meta.translateTo == "en")
        #expect(TranscriptStore.segments(of: session).map(\.text) == ["Hallo world", "你好"])
        #expect(TranscriptStore.segments(of: session).map(\.tr) == ["Hello world", "Hello"])
        #expect(TranscriptStore.segments(of: session).map(\.speaker) == [nil, "speaker-1"])
    }
}
