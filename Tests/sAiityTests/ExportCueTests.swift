import Foundation
import Testing

@testable import sAiity

/// Subtitles are read while a video plays, so the only two things that matter
/// are that they appear in order and that each one is short enough to read in
/// the time it claims. Both fail silently: a player renders an unreadable cue
/// without complaint, and out-of-order cues look like the video is skipping.
struct ExportCueTests {

    private func segment(_ text: String, _ t0: Double, _ t1: Double,
                         words: [TimedWord]? = nil,
                         translation: String? = nil) -> Segment {
        Segment(i: 0, t0: t0, t1: t1, text: text, loc: "en-US",
                tr: translation, trLoc: translation == nil ? nil : "de", words: words)
    }

    private func cueBlocks(_ srt: String) -> [[String]] {
        srt.split(separator: "\n\n").map { $0.split(separator: "\n").map(String.init) }
    }

    /// The defect: a final with no per-word timings became exactly one cue,
    /// however long it was. The streaming backends report no word timings at
    /// all, so this was the *normal* shape of a caption transcript — every
    /// export of one was a handful of unreadable 15-second cues.
    @Test("a long final with no word timings is split into readable cues")
    func longFinalWithoutWordTimingsIsSplit() {
        let text = """
        The first sentence runs on a little longer than most, and the second one \
        starts before the first has finished being read. A third sentence here, \
        so the whole final is comfortably over any reading speed.
        """
        let seg = segment(text, 0, 15)
        let cues = Export.cues(from: seg)

        #expect(cues.count > 1, "a 15-second final became \(cues.count) cue(s)")
        for cue in cues {
            #expect(cue.t1 > cue.t0, "zero-length cue: \(cue)")
            #expect(cue.text.count <= 84, "cue of \(cue.text.count) chars: \(cue.text)")
        }
        // Monotonic, contiguous, and covering the whole measured span: the
        // engine did time this segment, and every part of it has to appear.
        for (previous, next) in zip(cues, cues.dropFirst()) {
            #expect(next.t0 >= previous.t0, "cues run backwards")
            #expect(next.t1 >= previous.t1, "cue ends move backwards")
        }
        #expect(cues.first?.t0 == 0)
        #expect(cues.last?.t1 == 15)
        // No text is invented and none is lost: the words survive the split.
        let rejoined = cues.map(\.text).joined(separator: " ")
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init)
        let original = text.split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init)
        #expect(rejoined == original, "splitting changed the words")
    }

    /// Splits have to land where a reader would break, not mid-clause. Sentence
    /// marks are the strongest boundary available without timings.
    @Test("splits prefer sentence and clause ends")
    func splitsPreferNaturalBoundaries() {
        let seg = segment(
            "This first clause is quite long indeed, and this second clause is long too, so the budget runs out right around here. And then a second sentence arrives.",
            0, 9)
        let cues = Export.cues(from: seg)
        #expect(cues.count > 1)
        for cue in cues.dropLast() {
            let last = cue.text.last
            #expect(last == "." || last == "," || last == "?" || last == "!",
                    "cue ends mid-clause: \(cue.text)")
        }
        #expect(cues.last?.text.hasSuffix(".") == true)
    }

    /// The reading-time limit, not the character limit, is what should bind for
    /// a segment that speaks slowly: six words stretched over ten seconds of
    /// screen time is as unreadable as eighty-four words in one.
    @Test("a slow segment is cut for reading time, not only for length")
    func slowSegmentIsCutForReadingTime() {
        let text = "One. Two. Three. Four. Five. Six. Seven. Eight."
        let seg = segment(text, 0, 20)
        let cues = Export.cues(from: seg)
        #expect(cues.count >= 3, "a 20-second span stayed at \(cues.count) cue(s)")
        for cue in cues {
            #expect(cue.t1 - cue.t0 <= 6.5,
                    "cue claims \(cue.t1 - cue.t0)s of screen time: \(cue.text)")
        }
        #expect(cues.last?.t1 == 20)
    }

    /// Nothing to split is nothing to break. A short line must stay one cue, or
    /// every caption in a video flashes in two halves.
    @Test("a short final stays one cue")
    func shortFinalStaysOneCue() {
        let seg = segment("Guten Morgen.", 1.5, 4)
        let cues = Export.cues(from: seg)
        #expect(cues.count == 1)
        #expect(cues[0].t0 == 1.5 && cues[0].t1 == 4)
        #expect(cues[0].text == "Guten Morgen.")
    }

    /// No span to interpolate across, and no text: the degenerate cases must not
    /// become a burst of zero-length cues, which players drop or reject.
    @Test("degenerate segments produce no zero-length cues")
    func degenerateSegmentsAreHandled() {
        #expect(Export.cues(from: segment("", 0, 5)).isEmpty)
        #expect(Export.cues(from: segment("   ", 0, 5)).isEmpty)
        #expect(Export.cues(from: segment("Only one cue here.", 3, 3)).count == 1)
        // A single character has nothing to divide, so it is one cue.
        #expect(Export.cues(from: segment("Hi", 0, 0.2)).count == 1)
    }

    /// Scripts without spaces between words still end their sentences, and a
    /// transcript that is one 200-character cue because it has no spaces is the
    /// same defect in a different script.
    @Test("a script without word spaces is still split")
    func unspacedScriptIsSplit() {
        let text = "第一句话在这里说完了。第二句话稍微长一点，但也应该被分开显示。"
        let cues = Export.cues(from: segment(text, 0, 8))
        #expect(cues.count == 2, "got \(cues.map(\.text))")
        // The split lands after the first sentence mark: a cue that begins with
        // the second sentence would mean the break was ignored.
        #expect(cues[0].text.hasPrefix("第一句话在这里说完了。"))
        #expect(cues[1].t0 >= cues[0].t1)
        #expect(cues.last?.t1 == 8)
        // No spaces are invented, and none are lost: a CJK cue joined with a
        // space is a cue no reader asked for.
        #expect(!cues.contains { $0.text.contains(" ") })
        #expect(cues.map(\.text).joined() == text)
    }

    /// A run with no punctuation at all still cannot become one 400-character
    /// cue. The budget is the backstop, and it is measured in characters
    /// because there is nothing else to measure.
    @Test("an unpunctuated run is cut at the character budget")
    func unpunctuatedRunIsCutAtTheBudget() {
        let text = String(repeating: "alpha bravo charlie delta echo foxtrot ", count: 12)
        let cues = Export.cues(from: segment(text, 0, 30))
        #expect(cues.count > 1)
        for cue in cues {
            #expect(cue.text.count <= 84, "cue of \(cue.text.count) chars")
        }
        #expect(cues.map(\.text).joined(separator: " ") == text.trimmingCharacters(in: .whitespaces))
    }

    /// When the engine did give word timings, they win. The text fallback is
    /// for finals that have none, not a replacement for real ones.
    @Test("word timings are used when the engine provides them")
    func wordTimingsTakePrecedence() {
        let words = (0..<40).map { i in
            TimedWord(start: Double(i) * 0.25, end: Double(i) * 0.25 + 0.2, text: "word\(i) ")
        }
        let seg = segment("word0 word1 word2 ... word39", 0, 10, words: words)
        let cues = Export.cues(from: seg)
        #expect(cues.count > 1)
        // The times come from the words, not from proportional interpolation:
        // the first cue must start at the first word and end at its own end.
        #expect(cues[0].t0 == words[0].start)
        #expect(cues[0].t1 == words[cues[0].text.split(separator: " ").count - 1].end)
    }

    /// A translated segment stays one bilingual cue, because the translation
    /// belongs to the whole sentence and has no per-word timings to split
    /// along. That rule lives in the writers, not in `cues`: the text fallback
    /// splits on the original alone and would otherwise orphan the translation.
    @Test("a translated segment stays one bilingual cue however long it is")
    func translatedSegmentIsNotSplit() {
        let long = String(repeating: "This is one long original sentence. ", count: 4)
        let seg = segment(long, 0, 12, translation: String(repeating: "Dies ist ein langer Satz. ", count: 4))
        // The cue splitter has nothing to do with the translation…
        #expect(Export.cues(from: seg).count > 1)
        // …and the writers do not consult it for a segment that has one.
        let blocks = cueBlocks(Export.srt([seg]))
        #expect(blocks.count == 1, "the bilingual cue was split into \(blocks.count)")
        #expect(blocks[0].count == 4, "bilingual cue was \(blocks[0])")
        #expect(blocks[0][2] == long)
        #expect(blocks[0][3].hasPrefix("Dies ist ein langer Satz."))
        #expect(Export.vtt([seg]).split(separator: "\n\n").count == 2, "VTT header plus one cue")
    }

    /// The file is the deliverable: a split has to survive renumbering, timing
    /// format, and the WebVTT dialect, not just look right in isolation.
    @Test("SRT and WebVTT both carry the split cues")
    func bothSubtitleFormatsCarryTheSplit() {
        let text = "One sentence that goes on rather longer than a subtitle should be, "
            + "and a second one that does the same thing again for good measure."
        let seg = segment(text, 0, 12)
        let srt = Export.srt([seg])
        let vtt = Export.vtt([seg])

        let srtCues = cueBlocks(srt)
        #expect(srtCues.count > 1)
        #expect(srtCues.map { $0[0] } == (1...srtCues.count).map(String.init),
                "cue indices are not consecutive: \(srtCues.map { $0[0] })")
        // Every cue: index, one timing line, non-empty text.
        for cue in srtCues {
            #expect(cue.count == 3, "cue was \(cue)")
            #expect(cue[1].contains(" --> "))
            #expect(!cue[2].isEmpty)
            #expect(cue[1].contains(","), "SRT uses a comma before milliseconds")
        }
        #expect(vtt.hasPrefix("WEBVTT\n\n"))
        // Periods, not commas, in the *timings* — the cue text is allowed its own
        // punctuation, and this text has a comma in it.
        let vttTimings = vtt.split(separator: "\n").filter { $0.contains(" --> ") }
        #expect(vttTimings.count == srtCues.count)
        let vttTiming = try! Regex(#"^\d{2}:\d{2}:\d{2}\.\d{3} --> \d{2}:\d{2}:\d{2}\.\d{3}$"#)
        for timing in vttTimings {
            #expect(timing.firstMatch(of: vttTiming) != nil,
                    "VTT timing is not comma-free: \(timing)")
        }
    }

    /// Start times across the whole file, from a real multi-segment export.
    @Test("interpolated cues keep the file monotonic")
    func interpolatedCuesKeepTheFileMonotonic() {
        let segments = (0..<4).map { i in
            segment("Segment \(i) says one thing, and then it says another, "
                    + "and finishes with a third clause to round it off.",
                    Double(i) * 10, Double(i) * 10 + 9)
        }
        let pattern = #/(\d{2}):(\d{2}):(\d{2})[,.](\d{3}) --> /#
        for file in [Export.srt(segments), Export.vtt(segments)] {
            let starts = file.matches(of: pattern).map {
                (Int($0.1)! * 3600 + Int($0.2)! * 60 + Int($0.3)!) * 1000 + Int($0.4)!
            }
            #expect(starts.count > 4, "the file did not split: \(starts)")
            #expect(starts == starts.sorted(), "cue starts were \(starts)")
        }
    }
}
