import Foundation
import Testing

@testable import sAiity

@Suite struct DictationMicrophoneCaptureTests {
    @Test("dictation allows a full minute before applying the safety limit")
    func sampleLimitAllowsLongHold() {
        #expect(DictationAudioSampleLimit.maximumSamples == 16_000 * 60)

        var limit = DictationAudioSampleLimit()
        #expect(limit.accepted(sampleCount: DictationAudioSampleLimit.maximumSamples - 1) == .accepted)
        #expect(limit.accepted(sampleCount: 1) == .limited)
    }

    @Test("audio sample limit accepts exactly the configured maximum")
    func sampleLimitIsExact() {
        var limit = DictationAudioSampleLimit()
        #expect(limit.accepted(sampleCount: DictationAudioSampleLimit.maximumSamples - 1) == .accepted)
        #expect(limit.accepted(sampleCount: 1) == .limited)
        #expect(limit.accepted(sampleCount: 1) == .limited)
    }

    @Test("converted frame accounting is atomic across concurrent callbacks")
    func convertedFrameAccountingIsAtomic() {
        let capture = DictationMicrophoneCapture()
        let lock = NSLock()
        var accepted = 0
        var limitSignals = 0
        DispatchQueue.concurrentPerform(iterations: 2) { _ in
            let result = capture.acceptConvertedFrame(DictationAudioSampleLimit.maximumSamples / 2)
            lock.withLock {
                accepted += result.acceptedFrameCount
                if result.shouldEmitLimit { limitSignals += 1 }
            }
        }
        #expect(accepted == DictationAudioSampleLimit.maximumSamples)
        #expect(limitSignals == 1)
    }

    @Test("failed conversion does not enter frame accounting")
    func failedConversionDoesNotCount() {
        let capture = DictationMicrophoneCapture()
        let result = capture.acceptConvertedFrame(0)
        #expect(result.acceptedFrameCount == 0)
        #expect(!result.shouldEmitLimit)
        #expect(capture.acceptConvertedFrame(10).acceptedFrameCount == 10)
    }

    @Test("taking samples owns the capture buffer against a late callback")
    func takeOwnsSamplesAgainstLateCallback() {
        let capture = DictationMicrophoneCapture()
        capture.beginForTesting()
        capture.recordConvertedSamplesForTesting([1, 2])
        capture.stop()
        let first = capture.takeCollectedSamples()
        capture.recordConvertedSamplesForTesting([3, 4])
        #expect(first == [1, 2])
        #expect(capture.takeCollectedSamples().isEmpty)
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
