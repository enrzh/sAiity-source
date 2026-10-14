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
        #expect(capture.inputDeviceName == nil)
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

    @Test("waveform levels distinguish silence from speech")
    func waveformLevelsHaveUsefulRange() {
        let silence = DictationMicrophoneCapture.waveformLevelsForTesting(
            Array(repeating: Float.zero, count: 280))
        let speech = DictationMicrophoneCapture.waveformLevelsForTesting(
            Array(repeating: Float(0.08), count: 280))

        #expect(silence.allSatisfy { $0 == 0.06 })
        #expect(speech.allSatisfy { $0 > 0.5 })
        #expect(speech != silence)
    }

    private func healthFields(_ capture: DictationMicrophoneCapture) throws -> DictationInputHealth {
        try #require(capture.inputHealth, "Missing accepted-frame health")
    }

    @Test("microphone name stays unavailable without a running capture engine")
    func inputDeviceNameIsUnavailableWithoutRunningEngine() {
        let capture = DictationMicrophoneCapture()
        #expect(!capture.isRunning)
        #expect(capture.inputDeviceName == nil)
        capture.stop()
        #expect(capture.inputDeviceName == nil)
        capture.beginForTesting()
        #expect(capture.isRunning)
        #expect(capture.inputDeviceName == nil)
    }

    @Test("microphone health stays unavailable for empty and inactive input")
    func healthEmptyInputIsUnavailable() throws {
        let capture = DictationMicrophoneCapture()
        capture.recordConvertedSamplesForTesting([0.5])
        #expect(capture.inputHealth == nil)
        #expect(capture.collectedSamples.isEmpty)
        capture.beginForTesting()
        capture.recordConvertedSamplesForTesting([])
        #expect(capture.inputHealth == nil)
    }

    @Test("microphone health reports silence without rejecting its samples")
    func healthSilenceIsObserved() throws {
        let capture = DictationMicrophoneCapture()
        capture.beginForTesting()
        let samples = Array(repeating: Float.zero, count: 32_000)
        capture.recordConvertedSamplesForTesting(samples)
        let health = try healthFields(capture)
        #expect(health.sampleCount == samples.count)
        #expect(health.rmsDBFS == -Double.infinity)
        #expect(health.clippedSampleFraction == 0)
        #expect(health.observedDuration == 2)
        #expect(capture.takeCollectedSamples() == samples)
    }

    @Test("microphone health measures finite normalized samples in dBFS")
    func healthFiniteSignalHasExpectedRMS() throws {
        let capture = DictationMicrophoneCapture()
        capture.beginForTesting()
        let samples = Array(repeating: Float(0.1), count: 16_000)
        capture.recordConvertedSamplesForTesting(samples)
        let health = try healthFields(capture)
        let rms = try #require(health.rmsDBFS)
        #expect(abs(rms - (-20)) < 0.000_001)
        #expect(health.sampleCount == 16_000)
        #expect(health.observedDuration == 1)
        #expect(health.clippedSampleFraction == 0)
        #expect(capture.takeCollectedSamples() == samples)
    }

    @Test("microphone health weights uneven buffers by accepted sample count")
    func healthAccumulatesUnevenBuffers() throws {
        let capture = DictationMicrophoneCapture()
        capture.beginForTesting()
        capture.recordConvertedSamplesForTesting(Array(repeating: 0.5, count: 8_000))
        capture.recordConvertedSamplesForTesting(Array(repeating: 0, count: 24_000))
        let health = try healthFields(capture)
        let rms = try #require(health.rmsDBFS)
        #expect(abs(rms - 20 * log10(0.25)) < 0.000_001)
        #expect(health.sampleCount == 32_000)
        #expect(health.observedDuration == 2)
        #expect(health.clippedSampleFraction == 0)
    }

    @Test("microphone health includes both signs at the clipping boundary")
    func healthClippingIncludesThreshold() throws {
        let capture = DictationMicrophoneCapture()
        capture.beginForTesting()
        let samples: [Float] = [0.994, -0.994, 0.995, -0.995, 1, -1]
        capture.recordConvertedSamplesForTesting(samples)
        let health = try healthFields(capture)
        #expect(health.sampleCount == samples.count)
        #expect(abs(health.clippedSampleFraction - 4.0 / 6.0) < 0.000_001)
        #expect(try #require(health.rmsDBFS).isFinite)
        #expect(capture.takeCollectedSamples() == samples)
    }

    @Test("microphone health marks nonfinite signal unknown without filtering audio")
    func healthNonfiniteInputIsUnknown() throws {
        let capture = DictationMicrophoneCapture()
        capture.beginForTesting()
        capture.recordConvertedSamplesForTesting([0.25, .nan, .infinity, -.infinity])
        let health = try healthFields(capture)
        #expect(health.sampleCount == 4)
        #expect(health.rmsDBFS == nil)
        #expect(health.clippedSampleFraction == 0)
        #expect(health.observedDuration == 4.0 / 16_000)
        let samples = capture.takeCollectedSamples()
        #expect(samples.count == 4)
        #expect(samples.first == 0.25)
        #expect(samples.dropFirst().first?.isNaN == true)
        #expect(samples.dropFirst(2).first == Float.infinity)
        #expect(samples.last == -Float.infinity)
        capture.recordConvertedSamplesForTesting([0.5])
        #expect(try healthFields(capture).rmsDBFS == nil)
    }

    @Test("microphone health ignores the rejected suffix and later limit buffers")
    func healthCountsOnlyAcceptedPrefix() throws {
        let capture = DictationMicrophoneCapture()
        capture.beginForTesting()
        let maximum = DictationAudioSampleLimit.maximumSamples
        capture.recordConvertedSamplesForTesting(Array(repeating: 0, count: maximum - 1))
        capture.recordConvertedSamplesForTesting([0.5, 1, -1, .nan])
        capture.recordConvertedSamplesForTesting([1, .nan])
        let health = try healthFields(capture)
        #expect(health.sampleCount == maximum)
        #expect(health.observedDuration == 60)
        #expect(health.clippedSampleFraction == 0)
        let rms = try #require(health.rmsDBFS)
        #expect(abs(rms - 10 * log10(0.25 / Double(maximum))) < 0.000_001)
        let samples = capture.takeCollectedSamples()
        #expect(samples.count == maximum)
        #expect(samples.last == 0.5)
    }

    @Test("taking audio does not erase observed microphone health")
    func healthSurvivesTakingSamples() throws {
        let capture = DictationMicrophoneCapture()
        capture.beginForTesting()
        capture.recordConvertedSamplesForTesting([0.5, -0.5])
        #expect(capture.takeCollectedSamples() == [0.5, -0.5])
        #expect(capture.takeCollectedSamples().isEmpty)
        let health = try healthFields(capture)
        #expect(health.sampleCount == 2)
        #expect(abs(try #require(health.rmsDBFS) - 20 * log10(0.5)) < 0.000_001)
    }

    @Test("a new microphone session clears all previous health accounting")
    func healthResetsBetweenSessions() throws {
        let capture = DictationMicrophoneCapture()
        capture.beginForTesting()
        capture.recordConvertedSamplesForTesting([1, .nan])
        capture.beginForTesting()
        #expect(capture.inputHealth == nil)
        capture.recordConvertedSamplesForTesting([0.5, -0.5])
        let health = try healthFields(capture)
        #expect(health.sampleCount == 2)
        #expect(health.clippedSampleFraction == 0)
        #expect(health.observedDuration == 2.0 / 16_000)
        #expect(abs(try #require(health.rmsDBFS) - 20 * log10(0.5)) < 0.000_001)
        #expect(capture.takeCollectedSamples() == [0.5, -0.5])
    }
}
