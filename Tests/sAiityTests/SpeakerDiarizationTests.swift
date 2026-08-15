import Foundation
import Testing
import FluidAudio

@testable import sAiity

struct SpeakerDiarizationTests {

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
