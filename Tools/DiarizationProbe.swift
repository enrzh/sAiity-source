import FluidAudio
import Foundation

/// API/model probe for the first 2.0 speaker-label gate.
///
/// Type-check this file against the resolved FluidAudio build before changing
/// the app's transcript model. Running it downloads the LS-EEND model, so the
/// probe is intentionally opt-in and does not run during the normal test suite.
@main
struct DiarizationProbe {
    static func main() async throws {
        let variant = LSEENDVariant.dihard3
        let step = LSEENDStepSize.step100ms
        let fixture = CommandLine.arguments.dropFirst().first.map { URL(fileURLWithPath: $0) }
        let loadStart = ContinuousClock.now
        let diarizer = try await LSEENDDiarizer(variant: variant, stepSize: step)
        let loadTime = ContinuousClock.now - loadStart
        let inferenceStart = ContinuousClock.now
        let timeline: DiarizerTimeline
        if let fixture {
            timeline = try diarizer.processComplete(audioFileURL: fixture)
        } else {
            let silence = [Float](repeating: 0, count: 16_000 * 3)
            timeline = try diarizer.processComplete(silence, sourceSampleRate: 16_000)
        }
        let inferenceTime = ContinuousClock.now - inferenceStart

        print("model=\(variant.name(forStep: step))")
        print("fixture=\(fixture?.path ?? "generated-silence")")
        print("modelLoad=\(loadTime)")
        print("inference=\(inferenceTime)")
        print("speakers=\(timeline.speakers.count)")
        for speaker in timeline.speakers.values {
            for segment in speaker.finalizedSegments {
                print("speaker=\(speaker.index) start=\(segment.startTime) end=\(segment.endTime)")
            }
        }
    }
}
