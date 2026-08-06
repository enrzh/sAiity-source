import Foundation
import Testing

@testable import sAiity

/// Transcript order is silent corruption: nothing crashes, the captions on
/// screen look right, and the SRT file is wrong forever.
struct OrderingTests {

    /// The failure mode that existed: each final spawned its own Task whose
    /// duration was dominated by translation, and the store append ran at the
    /// end of it — so a slow translation on line A let line B reach the file
    /// first. The fix chains the writes: every link awaits its predecessor,
    /// then its own translation. This test reproduces the race and asserts the
    /// chain defeats it.
    @Test("Writes land in claim order even when translations finish out of order")
    func writeChainPreservesOrder() async {
        actor Sink {
            var lines: [Int] = []
            func write(_ i: Int) { lines.append(i) }
        }
        let sink = Sink()

        var chain: Task<Void, Never>?
        for i in 0..<20 {
            // Odd lines "translate" slowly — under the old scheme every odd
            // line would land after its even successor.
            let translation = Task {
                try? await Task.sleep(nanoseconds: i.isMultiple(of: 2) ? 1_000_000 : 30_000_000)
                return i
            }
            chain = Task { [previous = chain] in
                await previous?.value
                let v = await translation.value
                await sink.write(v)
            }
        }
        await chain?.value

        let got = await sink.lines
        #expect(got == Array(0..<20), "writes landed as \(got)")
    }

    @Test("SRT cues from ordered segments are monotonic")
    func srtIsMonotonic() {
        let segments = (0..<6).map { i in
            Segment(i: i, t0: Double(i) * 4, t1: Double(i) * 4 + 3.5,
                    text: "Zeile \(i) mit etwas mehr Text, damit die Cue realistisch ist.",
                    loc: "de-DE", tr: "Line \(i) translated.", trLoc: "en", words: nil)
        }
        let srt = Export.srt(segments)

        // Indices renumber from 1 and ascend by 1.
        let indices = srt.split(separator: "\n\n").compactMap {
            $0.split(separator: "\n").first.flatMap { Int($0) }
        }
        #expect(indices == Array(1...indices.count), "indices were \(indices)")

        // Start times never go backwards — the visible symptom of the old bug.
        // Extended delimiters: a bare regex literal cannot contain "  --> ".
        let pattern = #/(\d{2}):(\d{2}):(\d{2}),(\d{3}) --> /#
        let starts = srt.matches(of: pattern).map {
            (Int($0.1)! * 3600 + Int($0.2)! * 60 + Int($0.3)!) * 1000 + Int($0.4)!
        }
        #expect(starts == starts.sorted(), "cue starts were \(starts)")
        #expect(!starts.isEmpty)
    }
}
