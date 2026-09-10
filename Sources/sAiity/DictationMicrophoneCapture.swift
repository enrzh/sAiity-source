import AVFoundation
import Foundation

/// Pure lifecycle guard used by the hardware-backed capture object and tests.
struct DictationCaptureLifecycle: Sendable {
    private(set) var isRunning = false

    @discardableResult
    mutating func start() -> Bool {
        guard !isRunning else { return false }
        isRunning = true
        return true
    }

    @discardableResult
    mutating func stop() -> Bool {
        guard isRunning else { return false }
        isRunning = false
        return true
    }
}

/// A microphone-only input path for short dictation sessions.
///
/// This is intentionally separate from `MicMixer`: captions need a ring that
/// can be sampled by ScreenCaptureKit, while dictation needs every microphone
/// frame delivered directly to one short-lived backend.
final class DictationMicrophoneCapture: @unchecked Sendable {
    private let engine = AVAudioEngine()
    private let lock = NSLock()
    private var lifecycle = DictationCaptureLifecycle()
    private var converter: AVAudioConverter?
    private var sampleCount = 0
    // Keep one contiguous buffer so releasing a long dictation does not need
    // to allocate and flatten one array per audio callback.
    private var convertedSamples: [Float] = []
    private var didEmitLimit = false
    private var waveformFrameCounter = 0
    private var waveformHandler: (@Sendable ([Float]) -> Void)?
    var onLimit: (@Sendable () -> Void)?

    func setLimitHandler(_ handler: (@Sendable () -> Void)?) {
        onLimit = handler
    }

    func setWaveformHandler(_ handler: (@Sendable ([Float]) -> Void)?) {
        lock.withLock { waveformHandler = handler }
    }

    var isRunning: Bool {
        lock.withLock { lifecycle.isRunning }
    }

    func start(targetFormat: AVAudioFormat,
               onBuffer: @escaping @Sendable (AVAudioPCMBuffer) -> Void) throws {
        guard lock.withLock({ lifecycle.start() }) else { return }

        let input = engine.inputNode
        let sourceFormat = input.outputFormat(forBus: 0)
        guard sourceFormat.sampleRate > 0, sourceFormat.channelCount > 0 else {
            finishStartFailure()
            throw NSError(domain: "sAiity", code: 5, userInfo: [
                NSLocalizedDescriptionKey: String(localized: "No microphone is available on this Mac.")
            ])
        }

        guard let converter = AVAudioConverter(from: sourceFormat, to: targetFormat) else {
            finishStartFailure()
            throw NSError(domain: "sAiity", code: 4, userInfo: [
                NSLocalizedDescriptionKey: String(localized: "Could not prepare the microphone for dictation.")
            ])
        }
        self.converter = converter
        lock.withLock {
            sampleCount = 0
            convertedSamples.removeAll(keepingCapacity: true)
            convertedSamples.reserveCapacity(DictationAudioSampleLimit.maximumSamples)
            didEmitLimit = false
            waveformFrameCounter = 0
        }

        input.installTap(onBus: 0, bufferSize: 1024, format: sourceFormat) { [weak self] buffer, _ in
            self?.convert(buffer, to: targetFormat, onBuffer: onBuffer)
        }

        do {
            engine.prepare()
            try engine.start()
        } catch {
            finishStartFailure()
            throw error
        }
    }

    func stop() {
        guard lock.withLock({ lifecycle.stop() }) else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        converter = nil
    }

    private func finishStartFailure() {
        lock.withLock { _ = lifecycle.stop() }
        converter = nil
    }

    private func convert(_ buffer: AVAudioPCMBuffer,
                         to target: AVAudioFormat,
                         onBuffer: @escaping @Sendable (AVAudioPCMBuffer) -> Void) {
        guard lock.withLock({ lifecycle.isRunning }), let converter else { return }
        let ratio = target.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 64
        guard let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return }

        var consumed = false
        var error: NSError?
        converter.convert(to: output, error: &error) { _, status in
            if consumed {
                status.pointee = .noDataNow
                return nil
            }
            consumed = true
            status.pointee = .haveData
            return buffer
        }
        guard error == nil, output.frameLength > 0 else { return }
        guard let channel = output.floatChannelData?[0] else { return }
        let rawSamples = UnsafeBufferPointer(start: channel, count: Int(output.frameLength))
        let accounting = storeConvertedFrame(rawSamples)
        guard accounting.acceptedFrameCount > 0 else { return }
        output.frameLength = AVAudioFrameCount(accounting.acceptedFrameCount)
        let emitWaveform = lock.withLock {
            waveformFrameCounter += 1
            guard waveformFrameCounter >= 3 else { return false }
            waveformFrameCounter = 0
            return waveformHandler != nil
        }
        if emitWaveform {
            let levels = Self.waveformLevels(rawSamples, count: accounting.acceptedFrameCount)
            let handler = lock.withLock { waveformHandler }
            handler?(levels)
        }
        // Feed the recognizer after sampling the level. A streaming backend is
        // allowed to do synchronous work here; letting it run first made the
        // visual feedback stall whenever inference briefly occupied the audio
        // callback.
        onBuffer(output)
        if accounting.shouldEmitLimit { onLimit?() }
    }

    private static func waveformLevels(_ samples: UnsafeBufferPointer<Float>,
                                       count: Int,
                                       barCount: Int = 28) -> [Float] {
        guard count > 0 else { return [] }
        return (0..<barCount).map { bar in
            let start = count * bar / barCount
            let end = max(start + 1, count * (bar + 1) / barCount)
            let slice = samples[start..<min(end, count)]
            let meanSquare = slice.reduce(into: Float.zero) { sum, sample in
                sum += sample * sample
            } / Float(max(1, slice.count))
            // Square-rooted RMS keeps quiet speech visible without flattening
            // louder syllables into a solid block. Audio samples are normalized
            // floats, so 8x gives ordinary speech enough range to move the bars.
            return min(1, max(0.06, sqrt(meanSquare) * 8.0))
        }
    }

    /// Accounts one successfully converted buffer atomically. The returned
    /// values let the audio callback do feed/limit work after releasing lock.
    func acceptConvertedFrame(_ frameCount: Int) -> (acceptedFrameCount: Int, shouldEmitLimit: Bool) {
        lock.withLock {
            let remaining = DictationAudioSampleLimit.maximumSamples - sampleCount
            guard frameCount > 0, remaining > 0 else { return (0, false) }
            let accepted = min(frameCount, remaining)
            sampleCount += accepted
            let shouldEmit = sampleCount == DictationAudioSampleLimit.maximumSamples && !didEmitLimit
            if shouldEmit { didEmitLimit = true }
            return (accepted, shouldEmit)
        }
    }

    private func storeConvertedFrame(_ samples: UnsafeBufferPointer<Float>) -> (acceptedFrameCount: Int, shouldEmitLimit: Bool) {
        lock.withLock {
            guard lifecycle.isRunning, !samples.isEmpty else { return (0, false) }
            let remaining = DictationAudioSampleLimit.maximumSamples - sampleCount
            guard remaining > 0 else { return (0, false) }
            let accepted = min(samples.count, remaining)
            sampleCount += accepted
            convertedSamples.append(contentsOf: samples.prefix(accepted))
            let shouldEmit = sampleCount == DictationAudioSampleLimit.maximumSamples && !didEmitLimit
            if shouldEmit { didEmitLimit = true }
            return (accepted, shouldEmit)
        }
    }

    private func storeConvertedFrame(_ samples: [Float]) -> (acceptedFrameCount: Int, shouldEmitLimit: Bool) {
        samples.withUnsafeBufferPointer { storeConvertedFrame($0) }
    }

    var collectedSamples: [[Float]] {
        lock.withLock { convertedSamples.isEmpty ? [] : [convertedSamples] }
    }

    func takeCollectedSamples() -> [Float] {
        lock.withLock {
            let samples = convertedSamples
            convertedSamples.removeAll(keepingCapacity: true)
            return samples
        }
    }

    #if SAIITY_TEST_HOOKS
    func beginForTesting() {
        lock.withLock {
            _ = lifecycle.start()
            sampleCount = 0
            convertedSamples.removeAll(keepingCapacity: true)
            convertedSamples.reserveCapacity(DictationAudioSampleLimit.maximumSamples)
            didEmitLimit = false
            waveformFrameCounter = 0
        }
    }

    func recordConvertedSamplesForTesting(_ samples: [Float]) {
        _ = storeConvertedFrame(samples)
    }

    static func waveformLevelsForTesting(_ samples: [Float], barCount: Int = 28) -> [Float] {
        samples.withUnsafeBufferPointer {
            waveformLevels($0, count: samples.count, barCount: barCount)
        }
    }
    #endif
}
