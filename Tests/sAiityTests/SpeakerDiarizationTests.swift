import Foundation
import Testing
import FluidAudio

@testable import sAiity

struct SpeakerDiarizationTests {

    @Test("caption attribution chooses the speaker with the greatest weighted overlap")
    func attributesByOverlap() {
        var attributor = SpeakerCaptionAttributor()
        attributor.ingest([
            SpeakerDiarizationEvent(speakerID: "speaker-0", start: 0, end: 1,
                                    confidence: 0.8, isFinal: true),
            SpeakerDiarizationEvent(speakerID: "speaker-1", start: 0.8, end: 2,
                                    confidence: 0.9, isFinal: true)
        ])

        #expect(attributor.speakerID(for: 0.75, end: 1.2) == "speaker-1")
        #expect(attributor.speakerID(for: 2, end: 3) == nil)
    }

    @Test("brief speaker glitches do not redraw the current speaker")
    func shortSwitchesUseHysteresis() {
        var attributor = SpeakerCaptionAttributor()
        attributor.ingest([
            SpeakerDiarizationEvent(speakerID: "speaker-0", start: 0, end: 2,
                                    confidence: 0.8, isFinal: true),
            SpeakerDiarizationEvent(speakerID: "speaker-1", start: 1.8, end: 2.05,
                                    confidence: 0.9, isFinal: true),
            SpeakerDiarizationEvent(speakerID: "speaker-1", start: 2.05, end: 3.2,
                                    confidence: 0.9, isFinal: true)
        ])

        #expect(attributor.speakerID(for: 0.4, end: 1.2) == "speaker-0")
        #expect(attributor.speakerID(for: 1.8, end: 2.05) == "speaker-0")
        #expect(attributor.speakerID(for: 2.05, end: 3.2) == "speaker-1")
    }

    @Test("final diarization wins over a conflicting tentative update")
    func finalizedEventsAreStable() {
        var attributor = SpeakerCaptionAttributor()
        attributor.ingest([
            SpeakerDiarizationEvent(speakerID: "speaker-1", start: 1, end: 2,
                                    confidence: 0.9, isFinal: true),
            SpeakerDiarizationEvent(speakerID: "speaker-0", start: 1, end: 2,
                                    confidence: 1, isFinal: false)
        ])

        #expect(attributor.speakerID(for: 1.1, end: 1.8) == "speaker-1")
    }

    @Test("speaker labels stay opaque and deterministic")
    func labelsDoNotClaimIdentity() {
        #expect(SpeakerLabel.displayName(for: "speaker-0") == "Speaker 1")
        #expect(SpeakerLabel.displayName(for: "speaker-3") == "Speaker 4")
        #expect(SpeakerLabel.displayName(for: "unknown") == "unknown")
    }

    @Test("FluidAudio timeline segments map to stable local speaker events")
    func mapsFinalAndTentativeSegments() {
        let finalized = DiarizerSegment(
            speakerIndex: 1,
            startTime: 1.2,
            endTime: 2.4,
            finalized: true,
            frameDurationSeconds: 0.1,
            activity: 0.86)
        let tentative = DiarizerSegment(
            speakerIndex: 0,
            startTime: 0.4,
            endTime: 1.1,
            finalized: false,
            frameDurationSeconds: 0.1,
            activity: 0.42)

        let events = SpeakerDiarizationAdapter.events(
            finalized: [finalized], tentative: [tentative])

        #expect(events.map(\.speakerID) == ["speaker-0", "speaker-1"])
        #expect(events.map(\.isFinal) == [false, true])
        #expect(abs(events[0].start - 0.4) < 0.001)
        #expect(abs(events[1].start - 1.2) < 0.001)
        #expect(abs(events[0].end - 1.1) < 0.001)
        #expect(abs(events[1].end - 2.4) < 0.001)
        #expect(events.map(\.confidence) == [0.42, 0.86])
    }

    @Test("invalid or empty diarizer segments are not exposed to the caption pipeline")
    func dropsInvalidSegments() {
        let invalid = DiarizerSegment(
            speakerIndex: 0,
            startTime: 2,
            endTime: 2,
            finalized: true,
            frameDurationSeconds: 0.1)

        #expect(SpeakerDiarizationAdapter.events(finalized: [invalid], tentative: []).isEmpty)
    }
}
