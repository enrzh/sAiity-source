import Foundation

/// When a pause in speech ends a sentence — and whether it does at all.
///
/// The caption pipeline treats a gap as the end of a thought, because most of
/// what the multilingual recogniser emits carries no punctuation to end it
/// with. That makes this threshold the thing that decides where sentences
/// break, and therefore what the translator is handed: a fragment translates
/// into confident nonsense, and a sentence split in three is translated three
/// times without its own context.
///
/// It was a constant. It is a setting because the right value depends on the
/// speaker, and the failure mode in each direction is different and visible:
/// too short splits sentences at commas, too long delays every translation and
/// eventually lets the length cap cut a sentence mid-word instead.
enum SpeechGap {

    /// Off means sentences close on the length cap and on real punctuation
    /// only. Worth having: a lecture with long deliberate pauses is not the
    /// same material as a film, and for some sources the pause is noise.
    @Defaults("speechGapEnabled") static var enabled = true

    /// Milliseconds of quiet that count as the end of a sentence.
    ///
    /// 750 is the measured default and the one to come back to. Clause pauses
    /// in ordinary speech run 200–500 ms and the pause at the end of a sentence
    /// is longer, so at 450 ms this fired on the pause a speaker leaves at a
    /// comma — "Untertitel für alles, was der Mac abspielt, direkt auf dem
    /// Gerät." became three captions, each translated without the other two.
    @Defaults("speechGapHoldMs") static var holdMs = defaultHoldMs

    static let defaultHoldMs = 750
    /// Below 300 ms this fires inside ordinary speech; above 2 s a finished
    /// sentence waits long enough that the length cap usually closes it first,
    /// which is the thing the pause detection exists to avoid.
    static let range = 300...2000

    /// Frames of quiet at `rate` that make up the threshold.
    static func holdFrames(at rate: Double) -> Int {
        Int(Double(holdMs) / 1000 * rate)
    }
}

extension Notification.Name {
    /// Posted when either value changes, so a running capture picks it up
    /// without waiting for the next session.
    static let saiitySpeechGapChanged = Notification.Name("saiitySpeechGapChanged")
}
