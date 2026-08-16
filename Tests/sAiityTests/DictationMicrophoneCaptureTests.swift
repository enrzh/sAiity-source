import Testing

@testable import sAiity

@Suite struct DictationMicrophoneCaptureTests {
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
