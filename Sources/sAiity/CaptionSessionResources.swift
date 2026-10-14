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

    #if SAIITY_TEST_HOOKS
    var onCaptureStoppedForTests: (() -> Void)?
    #endif

    init(makeBackend: @escaping () -> TranscriptionBackend) {
        pool = ASRBackendPool(makeBackend: makeBackend)
    }

    /// Stop new input before waiting on native work; keep the backend for its final flush.
    func stopCapture() async {
        gapTask?.cancel()
        gapTask = nil
        await capture.stop()
        #if SAIITY_TEST_HOOKS
        onCaptureStoppedForTests?()
        #endif
    }

    /// Does not await startTask: failed startup calls this from inside that task.
    func stopAudio() async -> CaptionSpeakerTimeline? {
        await stopCapture()
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
