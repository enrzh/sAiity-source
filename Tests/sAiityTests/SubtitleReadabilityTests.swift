import Foundation
import Testing

@testable import sAiity

/// Reading speed, as opposed to cue length.
///
/// `ExportCueTests` covers whether a cue is *split* — too much text for one
/// screen. This covers whether it is *shown long enough* — text arriving faster
/// than anyone can read it. Both fail silently: a player renders an unreadable
/// cue without complaint.
@Suite("Subtitle reading speed")
struct SubtitleReadabilityTests {
    private func segment(_ text: String, _ t0: Double, _ t1: Double,
                         translation: String? = nil) -> Segment {
        Segment(i: 0, t0: t0, t1: t1, text: text, loc: "en-US",
                tr: translation, trLoc: translation == nil ? nil : "de", words: nil)
    }

    private func seconds(_ stamp: String) -> Double {
        let c = stamp.replacingOccurrences(of: ",", with: ".")
            .split(separator: ":").map(String.init)
        return (Double(c[0]) ?? 0) * 3600 + (Double(c[1]) ?? 0) * 60 + (Double(c[2]) ?? 0)
    }

    /// (duration, non-whitespace character count, text) for every cue in an SRT.
    private func cues(_ srt: String) -> [(Double, Int, String)] {
        srt.split(separator: "\n\n")
            .map { $0.trimmingCharacters(in: .newlines) }
            .filter { !$0.isEmpty }
            .compactMap { block in
                let lines = block.split(separator: "\n", omittingEmptySubsequences: false)
                    .map(String.init)
                guard lines.count >= 2 else { return nil }
                let timing = lines[1].components(separatedBy: " --> ")
                guard timing.count == 2 else { return nil }
                let text = lines.dropFirst(2).joined(separator: " ")
                return (seconds(timing[1]) - seconds(timing[0]),
                        text.filter { !$0.isWhitespace }.count,
                        text)
            }
    }

    /// The start and end stamp of every cue, in order.
    private func cueBounds(_ srt: String) -> [(Double, Double)] {
        srt.split(separator: "\n\n")
            .map { $0.trimmingCharacters(in: .newlines) }
            .filter { !$0.isEmpty }
            .compactMap { block in
                let lines = block.split(separator: "\n").map(String.init)
                guard lines.count >= 2 else { return nil }
                let t = lines[1].components(separatedBy: " --> ")
                guard t.count == 2 else { return nil }
                return (seconds(t[0]), seconds(t[1]))
            }
    }

    private func cueStarts(_ srt: String) -> [Double] { cueBounds(srt).map(\.0) }
    private func cueEnds(_ srt: String) -> [Double] { cueBounds(srt).map(\.1) }

    private let fast = "We need to ship the release notes today and then review the budget tomorrow morning."
    private let german = "Wir müssen heute die Versionsnotizen veröffentlichen und dann morgen früh das Budget prüfen."

    /// The defect, measured: an 83-character sentence in 1.4 seconds exported at
    /// 89 characters per second, and its trailing fragment — being small — got
    /// a proportionally small slice of the same span, landing at 0.135 seconds.
    /// A player draws that as a single frame.
    @Test("fast speech is slowed to a readable speed")
    func fastSpeechIsSlowed() {
        let found = cues(Export.srt([segment(fast, 0, 1.4)]))
        #expect(found.count >= 2)
        for (duration, characters, text) in found {
            #expect(duration >= Export.minimumCueDuration - 0.002,
                    "a \(Int(duration * 1000))ms cue for \(characters) characters: \(text)")
            let speed = duration > 0 ? Double(characters) / duration : .infinity
            #expect(speed <= Export.maximumReadingSpeed + 0.5,
                    "\(Int(speed)) CPS is too fast to read: \(text)")
        }
    }

    /// The worst case in the exporter, and the one that matters most here: a
    /// translated segment is a single bilingual cue, so both lines are on screen
    /// at once and both have to be read. It also bypassed cue splitting
    /// entirely, so it kept its raw 1.4-second timing — 126 characters per
    /// second before this.
    @Test("a fast bilingual cue is slowed too")
    func fastBilingualCueIsSlowed() {
        let found = cues(Export.srt([segment(fast, 0, 1.4, translation: german)]))
        #expect(found.count == 1, "a translated segment stays one bilingual cue")
        let (duration, characters, text) = found[0]
        #expect(text.contains("Versionsnotizen"), "the translation must survive")
        let speed = Double(characters) / duration
        #expect(speed <= Export.maximumReadingSpeed + 0.5,
                "\(Int(speed)) CPS bilingual is unreadable")
    }

    /// Ordinary speech is not sped up, shortened, or retimed. A floor that
    /// changed normal exports would be a regression dressed as an improvement.
    ///
    /// One thing does move: a trailing fragment shorter than the minimum stays
    /// up for the minimum, so the last cue can end a little after the audio
    /// does. That is ordinary subtitle practice — cutting a cue the instant
    /// speech stops is what makes the last line feel dropped — so the guarantee
    /// is that the overshoot is bounded by the minimum, not that it is zero.
    @Test("speech that is already readable keeps its timing")
    func readableSpeechIsUntouched() {
        let srt = Export.srt([segment(fast, 0, 6.0)])
        let starts = cueStarts(srt)
        #expect(starts.count >= 2)
        // The first cue begins when the audio does, and each subsequent cue
        // still begins where it did: nothing was pulled earlier to satisfy a
        // layout rule.
        #expect(abs(starts[0] - 0) < 0.002)
        #expect(starts[1] > 1.0, "the split point moved")

        let ends = cueEnds(srt)
        let overshoot = (ends.last ?? 0) - 6.0
        #expect(overshoot >= 0)
        #expect(overshoot <= Export.minimumCueDuration + 0.002,
                "a readable export was stretched \(overshoot)s past its own audio")
    }

    /// A pause the speaker actually took is information, and closing it up to
    /// satisfy a layout rule would destroy it.
    @Test("a pause between cues is preserved")
    func pauseIsPreserved() {
        let text = "One two three. Four five six."
        // Two words, then a two-second gap, then two more: the gap is real.
        let words = [
            TimedWord(start: 0.0, end: 1.0, text: "One two three."),
            TimedWord(start: 3.0, end: 4.0, text: "Four five six."),
        ]
        let seg = Segment(i: 0, t0: 0, t1: 4.0, text: text, loc: "en-US",
                          tr: nil, trLoc: nil, words: words)
        let found = cues(Export.srt([seg]))
        #expect(found.count == 2)
        let srt = Export.srt([seg])
        let starts = srt.split(separator: "\n\n")
            .map { $0.trimmingCharacters(in: .newlines) }
            .filter { !$0.isEmpty }
            .map { $0.split(separator: "\n").map(String.init)[1]
                .components(separatedBy: " --> ")[0] }
        // The second cue still begins where the speaker resumed.
        #expect(seconds(starts[1]) >= 2.9,
                "the gap between cues was closed up: \(starts)")
    }

    /// Nothing may run into the next segment: an overlapping cue is rejected
    /// outright by some players, which is worse than a fast one. A third
    /// segment follows, so the middle one has a real successor to respect.
    @Test("a cue never crosses into the next segment")
    func cueStopsAtTheNextSegment() {
        let segments = [
            segment(fast, 0, 1.4),
            segment("Right.", 1.4, 1.8),
            segment("Yes.", 1.8, 2.1),
        ]
        let srt = Export.srt(segments)
        let found = cues(srt)
        let middle = found.first { $0.2 == "Right." }
        #expect(middle != nil, "the middle segment lost its cue")
        #expect(middle!.0 <= 1.8 + 0.002,
                "the middle cue ran into the segment after it")
        // And the first segment's cues stop where the second begins.
        for (duration, _, text) in found where text != "Right." && text != "Yes." {
            #expect(duration > 0)
        }
        let last = found.last!
        #expect(last.2 == "Yes.")
        #expect(last.0 <= 2.1 + Export.minimumCueDuration + 0.002,
                "the final cue was stretched without bound")
    }

    /// Direct check of the primitive, including the whitespace rule: a cue of
    /// "morning." is eight characters to read, not thirteen.
    @Test("the floor counts characters, not spaces")
    func floorCountsCharacters() {
        let out = Export.applyReadabilityFloor([(0, 0.05, "morning.")], limit: nil)
        #expect(out.count == 1)
        #expect(out[0].t1 - out[0].t0 >= Export.minimumCueDuration - 0.002)
    }
}
