import Foundation

/// Decides when a pause in speech has happened, from a stream of per-buffer
/// RMS values.
///
/// The first version was a fixed threshold: quiet meant RMS below −45 dBFS.
/// That works for a bare voice and fails for exactly the material people
/// caption: anything with a soundtrack. Measured with a synthetic A/B — the
/// same speech with real silence in the pauses fired reliably, and over a
/// continuous −34 dBFS music bed the mix never dropped below −40 dBFS, so
/// against a −45 threshold no pause ever fired. Sentences then never closed on
/// a pause, and for Japanese nothing else closes them either: the recogniser
/// usually emits no punctuation, and the 220-character cap is minutes of
/// speech in a script that dense. The visible symptom was "it only translates
/// when I pause the video" — pausing produces digital silence, which is the
/// one thing a fixed threshold still catches.
///
/// So quiet is relative now. The detector keeps a running estimate of the
/// material's own noise floor — a minimum-follower over the RMS stream — and a
/// buffer counts as quiet when it sits within `headroom` of that floor. During
/// speech the mix rides well above the floor; in a pause it falls back to the
/// bed, which IS the floor, and that is the drop this measures. The absolute
/// −45 dBFS test is kept as the lower bound of the same comparison, so on
/// material with true silence the behaviour is exactly what it was: this can
/// only fire in more cases than the fixed threshold, never fewer.
///
/// The floor is the minimum RMS over a short rolling window, not a running
/// minimum with upward drift. The drift version was tried first and failed in
/// the acoustic replay after passing every unit fixture: a session starts with
/// digital silence — captions on, video not yet playing — so the floor learned
/// literal zero, and a multiplicative rise can never leave zero. The adaptive
/// term was dead for the whole session. A windowed minimum has no permanent
/// state at all: the pre-roll silence simply ages out, and so does a quiet
/// stretch between videos. Two buckets of `bucketSeconds` each approximate the
/// window without keeping a deque, so the floor reflects the quietest moment
/// of roughly the last `bucketSeconds`–`2×bucketSeconds`.
///
/// The threshold is deliberately NOT capped for loud material. A cap was tried,
/// to keep loud speech's own dips from reading as pauses — and the unit tests
/// caught what it actually did: speech mixed quieter than the cap could never
/// rise above the capped threshold, so the detector never armed and never fired
/// at all, on exactly the quiet mixes that need it. The runaway it guarded
/// against is already bounded twice over: the floor only rises at
/// `floorRiseDBPerSecond` and re-anchors at every real pause, and a false fire
/// needs a full hold's worth of audio within `headroom` of the quietest level
/// the material reaches — which, during actual speech, is a pause in all but
/// name. A fire with nothing pending is a no-op downstream.
struct SpeechGapDetector {

    /// Frames of quiet that make a pause. Set from `SpeechGap.holdMs`.
    var holdFrames: Int

    /// The old fixed threshold, kept as the lower bound: ≈ −45 dBFS.
    static let absoluteThreshold: Float = 0.0056
    /// How far above the learned floor still counts as quiet: ×1.78 ≈ +5 dB.
    /// Speech over a bed typically rides 10 dB or more above it; the pause is
    /// the bed alone.
    static let headroom: Float = 1.78
    /// Half the rolling window the floor is measured over. Also the bound on
    /// warm-up: material the window has not yet aged out — the pre-roll
    /// silence, the previous video — stops influencing the floor after at most
    /// two bucket lengths.
    static let bucketSeconds: Float = 6

    private var currentBucketMin: Float = .greatestFiniteMagnitude
    private var previousBucketMin: Float = .greatestFiniteMagnitude
    private var framesInBucket = 0

    /// The learned noise floor, in linear RMS: the quietest buffer in the
    /// rolling window. Unlearned until the first buffer arrives.
    var noiseFloor: Float { min(currentBucketMin, previousBucketMin) }
    private var quietFrames = 0
    /// Fires once per pause: re-arms only after speech resumes, so a long
    /// silence does not flush repeatedly.
    private var armed = false

    /// What "quiet" currently means, for the comparison and the diagnostics.
    var currentThreshold: Float {
        // ∞ × headroom stays ∞ before the first buffer, but `process` learns
        // the floor before comparing, so the unlearned value is never consulted.
        max(Self.absoluteThreshold, noiseFloor * Self.headroom)
    }

    /// Forget the material. Called on session start and on a settings change —
    /// the next stream may be entirely different content.
    mutating func reset() {
        currentBucketMin = .greatestFiniteMagnitude
        previousBucketMin = .greatestFiniteMagnitude
        framesInBucket = 0
        quietFrames = 0
        armed = false
    }

    /// Feed one buffer. Returns true when a pause has just completed.
    mutating func process(rms: Float, frames: Int, sampleRate: Float) -> Bool {
        currentBucketMin = min(currentBucketMin, rms)
        framesInBucket += frames
        if framesInBucket >= Int(Self.bucketSeconds * sampleRate) {
            previousBucketMin = currentBucketMin
            currentBucketMin = rms
            framesInBucket = 0
        }

        if rms < currentThreshold {
            quietFrames += frames
            if armed, quietFrames >= holdFrames {
                armed = false
                return true
            }
        } else {
            quietFrames = 0
            armed = true
        }
        return false
    }
}
