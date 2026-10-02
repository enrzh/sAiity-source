import Foundation

/// Owns caption audio delivery and the pooled backend lease for one session.
@MainActor
final class CaptionSessionResources {
    let capture = SystemAudioCapture()
    let pool: ASRBackendPool
    let sink = BackendSink()
    let speakerSink = CaptionSpeakerSink()
    var backend: (any TranscriptionBackend)?
    var speakerTracker: CaptionSpeakerTracker?
    var speakerPreparation: Task<Void, Never>?
    var startTask: Task<Void, Never>?
    var gapTask: Task<Void, Never>?

    init(makeBackend: @escaping () -> TranscriptionBackend) {
        pool = ASRBackendPool(makeBackend: makeBackend)
    }

    /// Does not await startTask: failed startup calls this from inside that task.
    func stopAudio() async -> CaptionSpeakerTimeline? {
        gapTask?.cancel()
        gapTask = nil
        await capture.stop()
        speakerSink.point(at: nil)
        speakerPreparation?.cancel()
        await speakerPreparation?.value
        speakerPreparation = nil
        let timeline = await speakerTracker?.stop()
        speakerTracker = nil
        // Stop delivery before returning a backend to the warm pool.
        sink.point(at: nil)
        if let backend {
            await backend.stop()
            await pool.release(backend, discard: false)
            self.backend = nil
        }
        return timeline
    }
}
