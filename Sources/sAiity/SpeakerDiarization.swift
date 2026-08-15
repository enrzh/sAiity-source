import FluidAudio
import Foundation

/// A platform-neutral diarization update consumed by sentence assembly.
///
/// `speakerID` is deliberately an opaque local identifier. It is not a person
/// name, and no identity is inferred from a system-audio channel.
struct SpeakerDiarizationEvent: Equatable, Sendable {
    let speakerID: String
    let start: Double
    let end: Double
    let confidence: Float
    let isFinal: Bool
}

/// Converts FluidAudio's timeline values into the small contract used by the
/// caption pipeline. Keeping this boundary here prevents FluidAudio timeline
/// types from leaking into persistence, exports, or the Windows core later.
enum SpeakerDiarizationAdapter {
    static func events(
        finalized: [DiarizerSegment],
        tentative: [DiarizerSegment]
    ) -> [SpeakerDiarizationEvent] {
        let finalEvents = finalized.compactMap { event(from: $0, isFinal: true) }
        let tentativeEvents = tentative.compactMap { event(from: $0, isFinal: false) }

        return (finalEvents + tentativeEvents).sorted {
            if $0.start != $1.start { return $0.start < $1.start }
            if $0.end != $1.end { return $0.end < $1.end }
            return $0.isFinal && !$1.isFinal
        }
    }

    private static func event(
        from segment: DiarizerSegment,
        isFinal: Bool
    ) -> SpeakerDiarizationEvent? {
        let start = Double(segment.startTime)
        let end = Double(segment.endTime)
        guard start.isFinite, end.isFinite, end > start, segment.speakerIndex >= 0 else {
            return nil
        }

        return SpeakerDiarizationEvent(
            speakerID: "speaker-\(segment.speakerIndex)",
            start: start,
            end: end,
            confidence: min(max(segment.activity, 0), 1),
            isFinal: isFinal)
    }
}
