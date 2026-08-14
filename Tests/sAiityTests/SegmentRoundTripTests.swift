import Foundation
import Testing

@testable import sAiity

/// Re-translating a saved transcript decodes every line, changes two fields,
/// and writes the whole thing back. Everything the app never looks at on that
/// path — the per-word timings the SRT splitter needs, the turn break, the
/// clock — rides along through a decode → re-encode it did not ask for. If any
/// of it failed to survive, the damage would be silent: the file still parses,
/// the captions still read fine, and only an SRT export weeks later would be
/// visibly worse.
///
/// The live check of re-translation ran against a transcript with no `words`,
/// so that field in particular was never exercised. This covers it.
struct SegmentRoundTripTests {

    @Test("A fully populated segment survives decode → re-encode unchanged")
    func fullSegmentRoundTrips() throws {
        let original = Segment(
            i: 7,
            t0: 12.25,
            t1: 15.5,
            text: "Guten Morgen, schön dass Sie da sind.",
            loc: "de-DE",
            tr: "Good morning, nice to have you here.",
            trLoc: "en",
            words: [TimedWord(start: 12.25, end: 12.6, text: "Guten"),
                    TimedWord(start: 12.6, end: 13.1, text: " Morgen,")],
            turn: true)

        // Exactly what Retranslator.write does: encode the decoded value.
        let line = try JSONEncoder().encode(original)
        let back = try JSONDecoder().decode(Segment.self, from: line)

        #expect(back.i == original.i)
        #expect(back.t0 == original.t0)
        #expect(back.t1 == original.t1)
        #expect(back.text == original.text)
        #expect(back.loc == original.loc)
        #expect(back.tr == original.tr)
        #expect(back.trLoc == original.trLoc)
        #expect(back.turn == true, "the turn break must not be dropped")
        #expect(back.words?.count == 2, "per-word timings must survive")
        #expect(back.words?.first?.text == "Guten")
        #expect(back.words?.first?.start == 12.25)
        #expect(back.words?.last?.end == 13.1)

        // And a second pass is stable — a rewrite of a rewrite must not drift.
        let again = try JSONDecoder().decode(Segment.self,
                                             from: try JSONEncoder().encode(back))
        #expect(again.words?.count == 2)
        #expect(again.turn == true)
    }

    /// The absent-optional case: a line recorded without translation or word
    /// timings must not gain empty ones, because `trLoc` present without `tr`
    /// is exactly the "claims a translation that never happened" state the
    /// transcript format forbids.
    @Test("Absent optionals stay absent through a rewrite")
    func absentOptionalsStayAbsent() throws {
        let bare = Segment(i: 0, t0: 0, t1: 1, text: "Hallo.", loc: "de-DE",
                           tr: nil, trLoc: nil, words: nil, turn: nil)
        let data = try JSONEncoder().encode(bare)
        let json = String(decoding: data, as: UTF8.self)
        #expect(!json.contains("\"tr\""), "nil translation must not be written")
        #expect(!json.contains("trLoc"))
        #expect(!json.contains("words"))
        #expect(!json.contains("turn"))

        let back = try JSONDecoder().decode(Segment.self, from: data)
        #expect(back.tr == nil && back.trLoc == nil)
        #expect(back.words == nil && back.turn == nil)
    }
}
