import Testing

@testable import sAiity

@Suite struct DictationMicrophoneCaptureTests {
    @Test("audio sample limit accepts exactly the configured maximum")
    func sampleLimitIsExact() {
        var limit = DictationAudioSampleLimit()
        #expect(limit.accepted(sampleCount: DictationAudioSampleLimit.maximumSamples - 1) == .accepted)
        #expect(limit.accepted(sampleCount: 1) == .limited)
        #expect(limit.accepted(sampleCount: 1) == .limited)
    }

    @Test("capture lifecycle starts once and stops once")
    func lifecycleIsIdempotent() {
        var lifecycle = DictationCaptureLifecycle()
        let firstStart = lifecycle.start()
        let secondStart = lifecycle.start()
        #expect(firstStart)
        #expect(!secondStart)
        #expect(lifecycle.isRunning)
        let firstStop = lifecycle.stop()
        let secondStop = lifecycle.stop()
        #expect(firstStop)
        #expect(!secondStop)
        #expect(!lifecycle.isRunning)
    }
}
