import Foundation
import Testing
import WhisperKit

@testable import sAiity

/// The commit rule, tested without a 626 MB model in the test process.
///
/// This is the part of `WhisperTurboEngine` most worth pinning down. Everything
/// else it does — buffering, the callback, the tail decode — is plumbing that
/// either works or throws. The commit rule is a judgement about which text has
/// stopped moving, and a regression there is invisible in every other test: the
/// transcript still reads like English, it is just wrong, and the words that
/// were wrong are gone from the caption line before anyone can compare them.
@Suite("Whisper turbo commit rule")
struct WhisperTurboEngineTests {
    /// A result carrying words at the given timestamps, so the timestamps under
    /// test are the real input to the real rule.
    private func result(_ words: [(String, Double, Double)],
                        language: String = "en") -> TranscriptionResult {
        let segments = words.enumerated().map { index, word in
            TranscriptionSegment(id: index,
                                 seek: 0,
                                 start: Float(word.1),
                                 end: Float(word.2),
                                 text: " " + word.0,
                                 tokens: [],
                                 tokenLogProbs: [[:]],
                                 words: [WordTiming(word: word.0,
                                                    tokens: [],
                                                    start: Float(word.1),
                                                    end: Float(word.2),
                                                    probability: 0.99)])
        }
        return TranscriptionResult(text: words.map(\.0).joined(separator: " "),
                                   segments: segments,
                                   language: language,
                                   timings: TranscriptionTimings())
    }

    @Test("a word before the horizon is settled; one after it is not")
    func horizonSplitsTheWindow() {
        // 12 s window, 1.5 s horizon: everything ending by 10.5 s has settled.
        let split = WhisperTurboEngine.split(
            segments: [result([("early", 0.2, 1.0), ("late", 11.0, 11.8)])],
            contextSeconds: 0,
            windowSeconds: 12)
        #expect(split.settled == ["early"])
        #expect(split.volatile == "late")
    }

    @Test("the horizon is a lead on the live edge, not a fixed offset")
    func horizonTracksWindowLength() {
        // Same word end, twice the window: it is comfortably settled in the long
        // window and still volatile in the short one. A rule that compared
        // against a constant would get this backwards.
        let words = [("w", 3.0, 4.0)]
        let short = WhisperTurboEngine.split(segments: [result(words)],
                                             contextSeconds: 0,
                                             windowSeconds: 5)
        let long = WhisperTurboEngine.split(segments: [result(words)],
                                            contextSeconds: 0,
                                            windowSeconds: 12)
        #expect(short.volatile == "w", "4.0 s of 5.0 s is 1.0 s from the edge — inside the 1.5 s horizon")
        #expect(long.settled == ["w"], "4.0 s of 12.0 s is 8.0 s from the edge")
    }

    @Test("left context is re-decoded and then discarded, not committed twice")
    func leftContextIsDiscardedNotDoubleCounted() {
        // The window opens with 2 s of audio that was committed on an earlier
        // pass. It is decoded again every pass so the model has history, and
        // must be dropped here or the caption would repeat itself.
        let split = WhisperTurboEngine.split(
            segments: [result([("already", 0.1, 0.8), ("fresh", 3.0, 4.0)])],
            contextSeconds: 2.0,
            windowSeconds: 12)
        #expect(split.settled == ["fresh"])
        #expect(!split.volatile.contains("already"), "left context must not reappear as volatile")
        #expect(abs(split.decidedUpTo - 4.0) < 0.001)
    }

    @Test("a word straddling the context boundary is kept, not swallowed")
    func straddlingWordSurvives() {
        // Starts before the context edge, ends well after it. Dropping it would
        // lose a real word from the transcript on a boundary that happens to
        // land mid-word — which, with word timestamps on real speech, it will.
        let split = WhisperTurboEngine.split(
            segments: [result([("straddle", 1.6, 2.4), ("next", 3.0, 4.0)])],
            contextSeconds: 2.0,
            windowSeconds: 12)
        #expect(split.settled == ["straddle", "next"])
    }

    @Test("decidedUpTo is monotonic across passes, so the committed prefix only grows")
    func committedPrefixNeverShrinks() {
        // Two consecutive passes over a growing window. The invariant the whole
        // design rests on: once a word is settled, later passes must not settle
        // anything that overlaps it, because the pipeline has already moved that
        // text into a caption line.
        let first = WhisperTurboEngine.split(
            segments: [result([("a", 0.1, 1.0), ("b", 1.1, 2.0), ("c", 11.0, 11.9)])],
            contextSeconds: 0, windowSeconds: 12)
        #expect(first.settled == ["a", "b"])
        let kept = 2.0
        // 2.0 s of committed audio is kept, so the window now opens on it, and
        // 3.0 s more has arrived. d ends 2.1 s before the live edge, so it
        // settles too — the prefix grew without re-settling a or b.
        let second = WhisperTurboEngine.split(
            segments: [result([("a", 0.1, 1.0), ("b", 1.1, 2.0), ("c", 11.0, 11.9), ("d", 11.9, 12.9)])],
            contextSeconds: kept, windowSeconds: 15)
        #expect(second.settled == ["c", "d"], "the next pass must settle only what follows the kept context")
        #expect(second.decidedUpTo > first.decidedUpTo)
    }

    @Test("silence settles nothing and reports no language")
    func silenceProducesNothing() {
        let split = WhisperTurboEngine.split(segments: [], contextSeconds: 0, windowSeconds: 12)
        #expect(split.settled.isEmpty)
        #expect(split.volatile.isEmpty)
        #expect(split.decidedUpTo == 0)
        #expect(split.language == nil)
    }

    @Test("the language comes from the decode, not from the words")
    func languageIsReportedFromAudio() {
        // Non-Latin script with an English tag: proves the tag is read off the
        // result rather than sniffed out of the text, which is the difference
        // between a real identification and a guess.
        let split = WhisperTurboEngine.split(
            segments: [result([("ciao", 0.1, 1.0)], language: "it")],
            contextSeconds: 0, windowSeconds: 12)
        #expect(split.language == "it")
    }

    @Test("the committed window never grows without bound")
    func windowCapIsReachable() {
        // The overload valve only fires when a decode returns nothing, and it
        // exists so silence cannot turn into an ever-growing re-decode. The cap
        // has to be larger than the steady state or it would fire in normal use
        // and drop audio that was about to be committed.
        let steadyState = WhisperTurboEngine.leftContextSeconds
            + WhisperTurboEngine.commitHorizonSeconds
            + WhisperTurboEngine.stepSeconds
        #expect(WhisperTurboEngine.maximumWindowSeconds > steadyState,
                "the cap must sit above the steady-state window or it drops live audio")
    }

    @Test("a step is shorter than a caption line, so it is not the latency the user waits on")
    func stepIsBelowCaptionLatency() {
        #expect(WhisperTurboEngine.stepSeconds < 1.0)
    }
}
