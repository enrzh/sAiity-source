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

/// The small, deterministic bridge between diarizer time ranges and caption
/// time ranges. It deliberately knows nothing about FluidAudio or the UI.
struct SpeakerCaptionAttributor: Sendable {
    private(set) var events: [SpeakerDiarizationEvent] = []
    private var lastAssignedSpeakerID: String?

    /// A diarizer can briefly assign a neighboring frame to another speaker.
    /// Do not redraw a caption row for a switch that has less than one short
    /// speech beat of support while the current speaker still overlaps it.
    private static let minimumStableSwitchDuration = 0.35

    mutating func ingest(_ incoming: [SpeakerDiarizationEvent]) {
        guard !incoming.isEmpty else { return }
        for event in incoming {
            // Timeline updates can repeat a segment while a tentative window
            // advances. Replacing exact duplicates keeps the lookup bounded
            // without making the attribution state clever.
            if let index = events.firstIndex(where: {
                $0.speakerID == event.speakerID
                    && abs($0.start - event.start) < 0.001
                    && abs($0.end - event.end) < 0.001
            }) {
                if event.isFinal || !events[index].isFinal { events[index] = event }
            } else {
                events.append(event)
            }
        }
        events.sort {
            if $0.start != $1.start { return $0.start < $1.start }
            if $0.end != $1.end { return $0.end < $1.end }
            return $0.isFinal && !$1.isFinal
        }

        // A long meeting should not make every future overlap lookup scan the
        // complete session. Finalized caption ranges are monotonic, so keeping
        // a modest tail is enough for late diarizer results.
        if let newest = events.map(\.end).max(), newest > 120 {
            events.removeAll { $0.end < newest - 120 }
        }
    }

    mutating func speakerID(for start: Double, end: Double,
                            minimumOverlap: Double = 0.08,
                            minimumConfidence: Float = 0.15) -> String? {
        guard start.isFinite, end.isFinite, end > start else { return nil }
        let candidates = events.filter { $0.confidence >= minimumConfidence }
        let finalized = candidates.filter(\.isFinal)
        let pool = finalized.isEmpty ? candidates : finalized
        var scoreBySpeaker: [String: Double] = [:]
        for event in pool {
            let overlap = min(end, event.end) - max(start, event.start)
            guard overlap >= minimumOverlap else { continue }
            scoreBySpeaker[event.speakerID, default: 0] += overlap * Double(event.confidence)
        }
        guard let winner = scoreBySpeaker.max(by: {
            if abs($0.value - $1.value) > 0.001 { return $0.value < $1.value }
            return $0.key > $1.key
        })?.key else { return nil }

        if let previous = lastAssignedSpeakerID,
           previous != winner,
           let previousOverlap = scoreBySpeaker[previous],
           previousOverlap >= minimumOverlap {
            let winnerOverlap = scoreBySpeaker[winner] ?? 0
            if end - start < Self.minimumStableSwitchDuration
                || winnerOverlap < Self.minimumStableSwitchDuration {
                return previous
            }
        }
        lastAssignedSpeakerID = winner
        return winner
    }
}

enum SpeakerLabel {
    static func displayName(for speakerID: String) -> String {
        guard let suffix = speakerID.split(separator: "-").last,
              let index = Int(suffix) else { return speakerID }
        return String(localized: "Speaker \(index + 1)")
    }
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
