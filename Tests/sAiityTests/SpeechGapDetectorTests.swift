import Foundation
import Testing

@testable import sAiity

/// These replay the A/B measurement that motivated the adaptive detector, with
/// the actual levels from that session: speech-over-bed at ~0.05 RMS, the bed
/// alone at 0.0095 (−40.4 dBFS), true silence at ~1e-8. The fixed −45 dBFS
/// threshold fired on the silence fixture and never on the bed fixture — which
/// on screen was "it only translates when I pause the video".
@Suite("Speech gap detection")
struct SpeechGapDetectorTests {

    /// 20 ms buffers at 48 kHz, matching what SCStream delivers.
    private static let frames = 960
    private static let rate: Float = 48_000
    private static let holdFrames = 36_000   // 750 ms

    /// Feed `ms` of a level; returns true if the detector fired at any point.
    private func feed(_ d: inout SpeechGapDetector, rms: Float, ms: Int) -> Bool {
        var fired = false
        for _ in 0..<(ms / 20) {
            if d.process(rms: rms, frames: Self.frames, sampleRate: Self.rate) {
                fired = true
            }
        }
        return fired
    }

    /// Speech is never one level. Alternate loud and softer 100 ms halves
    /// (~±3.5 dB around the mean), because a constant tone equals its own
    /// floor and would read as one long pause — the first fixture written
    /// here did exactly that and armed nothing, which is itself the reason
    /// the detector's arming semantics are what they are.
    private func speak(_ d: inout SpeechGapDetector, around level: Float, ms: Int) -> Bool {
        var fired = false
        for i in 0..<(ms / 100) {
            let level = i.isMultiple(of: 2) ? level * 1.6 : level * 0.7
            fired = feed(&d, rms: level, ms: 100) || fired
        }
        return fired
    }

    @Test("Fixture A: real silence in the pause still fires, as it always did")
    func silenceStillFires() {
        var d = SpeechGapDetector(holdFrames: Self.holdFrames)
        #expect(!speak(&d, around: 0.05, ms: 2000), "fired during speech")
        #expect(feed(&d, rms: 1e-8, ms: 1000), "a real-silence pause must fire")
    }

    @Test("Fixture B: a pause under a continuous music bed fires now")
    func bedPauseFires() {
        var d = SpeechGapDetector(holdFrames: Self.holdFrames)
        #expect(!speak(&d, around: 0.05, ms: 2000), "fired during speech over the bed")
        // The bed alone: −40.4 dBFS, well above the old −45 absolute threshold.
        // This is the case the fixed threshold could never fire on.
        #expect(0.0095 > SpeechGapDetector.absoluteThreshold,
                "fixture invalid: bed level must sit above the absolute threshold")
        #expect(feed(&d, rms: 0.0095, ms: 1000), "a bed-only pause must fire")
    }

    @Test("A pause shorter than the hold does not fire")
    func shortPauseDoesNotFire() {
        var d = SpeechGapDetector(holdFrames: Self.holdFrames)
        _ = speak(&d, around: 0.05, ms: 2000)
        #expect(!feed(&d, rms: 0.0095, ms: 400), "400 ms is a breath, not a full stop")
        // And speech resuming resets the accumulation entirely.
        _ = speak(&d, around: 0.05, ms: 200)
        #expect(!feed(&d, rms: 0.0095, ms: 400))
    }

    @Test("Fires once per pause, and re-arms only after speech resumes")
    func firesOncePerPause() {
        var d = SpeechGapDetector(holdFrames: Self.holdFrames)
        _ = speak(&d, around: 0.05, ms: 2000)
        #expect(feed(&d, rms: 0.0095, ms: 1000))
        // A long silence must not flush repeatedly.
        #expect(!feed(&d, rms: 0.0095, ms: 5000), "re-fired without speech in between")
        _ = speak(&d, around: 0.05, ms: 600)
        #expect(feed(&d, rms: 0.0095, ms: 1000), "did not re-arm after speech resumed")
    }

    @Test("Gap events carry the absolute capture sample watermark")
    func gapCarriesSampleRange() {
        var d = SpeechGapDetector(holdFrames: Self.holdFrames)
        _ = speak(&d, around: 0.05, ms: 2000)

        var event: SpeechActivityEvent?
        for _ in 0..<50 {
            event = d.processEvent(rms: 0.0095,
                                   frames: Self.frames,
                                   sampleRate: Self.rate)
            if case .gap = event { break }
        }

        guard let event else {
            Issue.record("expected a gap event")
            return
        }
        guard case .gap(let range) = event else {
            Issue.record("expected a gap event")
            return
        }
        #expect(range.lowerBound < range.upperBound)
        #expect(range.upperBound == d.observedSampleCount)
    }

    @Test("Ordinary speech dynamics do not fire mid-sentence")
    func speechDynamicsDoNotFire() {
        var d = SpeechGapDetector(holdFrames: Self.holdFrames)
        // Alternating loud and softer syllables over a bed, 100 ms each: the
        // soft halves sit above bed × headroom, and no quiet stretch reaches
        // the hold. Ten seconds of it must not produce a single gap.
        var fired = false
        for _ in 0..<50 {
            fired = feed(&d, rms: 0.10, ms: 100) || fired
            fired = feed(&d, rms: 0.04, ms: 100) || fired
        }
        #expect(!fired, "split running speech")
    }

    @Test("The floor is forgotten on reset")
    func resetForgetsTheFloor() {
        var d = SpeechGapDetector(holdFrames: Self.holdFrames)
        _ = feed(&d, rms: 1e-8, ms: 1000)   // learn a near-zero floor
        d.reset()
        // After reset, a bed-level stream is the new material's floor, not
        // "loud compared to the silence of the last video".
        _ = feed(&d, rms: 0.0095, ms: 100)
        #expect(d.noiseFloor <= 0.0095)
        #expect(!feed(&d, rms: 0.0095, ms: 1000),
                "fired without ever hearing speech (never armed)")
    }

    @Test("A loud mix behaves the same: the pause is relative, not absolute")
    func loudBedPauseFires() {
        var d = SpeechGapDetector(holdFrames: Self.holdFrames)
        // Loud speech (~−12 dBFS) over a loud bed (−20 dBFS). A capped version
        // of this detector refused to fire here by design — and the same cap
        // silently disarmed quiet mixes entirely, which is why there is no cap.
        _ = speak(&d, around: 0.25, ms: 2000)
        #expect(feed(&d, rms: 0.1, ms: 1000), "a pause in a loud mix must fire too")
    }

    @Test("Quiet material ages out of the floor's window")
    func floorForgetsQuietMaterial() {
        var d = SpeechGapDetector(holdFrames: Self.holdFrames)
        _ = feed(&d, rms: 0.001, ms: 1000)      // a very quiet stretch
        let before = d.noiseFloor
        // Two full bucket lengths of louder material later, the quiet stretch
        // must be gone from the window entirely.
        _ = feed(&d, rms: 0.05, ms: Int(SpeechGapDetector.bucketSeconds * 2 * 1000) + 1000)
        #expect(d.noiseFloor > before * 2,
                "the floor still remembers material outside its window")
    }

    /// The field failure the drift-based floor shipped with, reproduced: the
    /// session starts before the video, so the floor learns digital zero — and
    /// a multiplicative rise can never leave zero, which killed the adaptive
    /// term for the whole session. Every unit fixture passed; the acoustic
    /// replay caught it. This is that replay as a fixture: pre-roll silence,
    /// then the video starts, then a pause under the bed must still fire.
    @Test("Pre-roll silence before the video does not pin the floor at zero")
    func preRollSilenceDoesNotPinTheFloor() {
        var d = SpeechGapDetector(holdFrames: Self.holdFrames)
        // Captions running, nothing playing yet. (This fires one gap when
        // speech first arms and silence follows — irrelevant here.)
        _ = feed(&d, rms: 0.0, ms: 15_000)
        // The video: speech over the bed, long enough for the pre-roll to age
        // out of the floor's window.
        _ = speak(&d, around: 0.05, ms: Int(SpeechGapDetector.bucketSeconds * 2 * 1000) + 2000)
        // A pause in speech — the bed keeps playing. This is the moment that
        // never fired in the field.
        #expect(feed(&d, rms: 0.0095, ms: 1000),
                "a bed-only pause after pre-roll silence must fire")
        #expect(d.currentThreshold > SpeechGapDetector.absoluteThreshold,
                "the adaptive term is dead — the floor is still pinned")
    }
}
