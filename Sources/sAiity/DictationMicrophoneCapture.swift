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
    private var didEmitLimit = false
    var onLimit: (@Sendable () -> Void)?

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
        lock.withLock { sampleCount = 0; didEmitLimit = false }

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
        guard isRunning, let converter else { return }
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
        let remaining = DictationAudioSampleLimit.maximumSamples - lock.withLock { sampleCount }
        guard remaining > 0 else { return }
        let accepted = min(Int(output.frameLength), remaining)
        lock.withLock { sampleCount += accepted }
        output.frameLength = AVAudioFrameCount(accepted)
        onBuffer(output)
        if accepted == remaining, lock.withLock({ !didEmitLimit }) {
            lock.withLock { didEmitLimit = true }
            onLimit?()
        }
    }
}
