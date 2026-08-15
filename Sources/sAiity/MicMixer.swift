import Accelerate
import AVFoundation
import Foundation

/// The one deliberate exception to "the microphone is never opened".
///
/// System audio on a call carries only the remote participants — the user's
/// own voice never enters the output mix — so every saved meeting transcript
/// was structurally missing one side of the conversation, the side belonging
/// to the one person most likely to want the transcript. Turning this on
/// mixes the microphone into recognition.
///
/// Off by default, and the privacy contract around it is strict: the
/// permission prompt is only ever triggered after the user flips the setting,
/// the README and onboarding say "unless you turn this on" rather than
/// "never", and audio still never leaves the Mac.
enum MicMix {
    static var enabled: Bool {
        get { UserDefaults.standard.bool(forKey: "includeMicrophone") }
        set { UserDefaults.standard.set(newValue, forKey: "includeMicrophone") }
    }

    /// A permission request can outlive the setting change that started it.
    /// Only the latest setting is allowed to open the input again.
    static func shouldStart(requested: Bool, current: Bool) -> Bool {
        requested && current
    }
}

/// A bounded ring of 48 kHz mono mic samples, pure and testable.
///
/// The mic and ScreenCaptureKit run on different clocks, so their buffers can
/// never be assumed aligned: the ring absorbs the jitter, an underrun mixes
/// silence (the caption stream must never wait on the mic), and an overflow
/// drops the OLDEST samples so what is mixed stays near-live rather than
/// drifting seconds behind the system audio it is supposed to accompany.
struct MicRing {
    private(set) var samples: [Float] = []
    let capacity: Int

    /// 500 ms at 48 kHz — enough for scheduling jitter, small enough that a
    /// clock-drift drop is inaudible in captions.
    init(capacity: Int = 24_000) {
        self.capacity = capacity
    }

    mutating func push(_ new: [Float]) {
        samples.append(contentsOf: new)
        if samples.count > capacity {
            samples.removeFirst(samples.count - capacity)
        }
    }

    /// Sum up to `count` queued samples into `dst`, consuming them, then
    /// clamp the result to [-1, 1] — two full-scale sources summed would
    /// otherwise fold over into noise.
    mutating func mix(into dst: UnsafeMutablePointer<Float>, count: Int) {
        let n = min(count, samples.count)
        if n > 0 {
            samples.withUnsafeBufferPointer { src in
                vDSP_vadd(dst, 1, src.baseAddress!, 1, dst, 1, vDSP_Length(n))
            }
            samples.removeFirst(n)
        }
        var lo: Float = -1, hi: Float = 1
        vDSP_vclip(dst, 1, &lo, &hi, dst, 1, vDSP_Length(count))
    }
}

/// Owns the AVAudioEngine input tap and feeds the ring. The capture queue
/// pulls from it per ScreenCaptureKit buffer; the tap pushes from Core
/// Audio's own thread — hence the lock around the ring and nothing else.
final class MicMixer: @unchecked Sendable {
    private let engine = AVAudioEngine()
    private var converter: AVAudioConverter?
    private let lock = NSLock()
    private var ring = MicRing()

    func start(sampleRate: Double) throws {
        let input = engine.inputNode
        let fmt = input.outputFormat(forBus: 0)
        // A Mac with no input device at all (a Mini or Studio with nothing
        // plugged in) reports 0 Hz / 0 channels here, and installTap on that
        // format raises an Objective-C exception — which Swift's do/catch
        // cannot catch, so it would take the whole app down instead of
        // degrading to "captions run without your microphone".
        guard fmt.sampleRate > 0, fmt.channelCount > 0 else {
            throw NSError(domain: "sAiity", code: 5, userInfo: [
                NSLocalizedDescriptionKey: String(localized: "No microphone is available on this Mac.")
            ])
        }
        guard let target = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                         sampleRate: sampleRate, channels: 1,
                                         interleaved: false) else {
            throw NSError(domain: "sAiity", code: 4, userInfo: [
                NSLocalizedDescriptionKey: "could not build mic target format"])
        }
        converter = AVAudioConverter(from: fmt, to: target)
        input.installTap(onBus: 0, bufferSize: 1024, format: fmt) { [weak self] buf, _ in
            self?.push(buf, target: target)
        }
        engine.prepare()
        try engine.start()
    }

    func stop() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        lock.withLock { ring = MicRing() }
    }

    /// Sum queued mic samples into a capture buffer, consuming them.
    func mix(into dst: UnsafeMutablePointer<Float>, count: Int) {
        lock.withLock { ring.mix(into: dst, count: count) }
    }

    private func push(_ buf: AVAudioPCMBuffer, target: AVAudioFormat) {
        guard let converter else { return }
        let ratio = target.sampleRate / buf.format.sampleRate
        let cap = AVAudioFrameCount(Double(buf.frameLength) * ratio) + 64
        guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: cap) else { return }
        var consumed = false
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            if consumed { status.pointee = .noDataNow; return nil }
            consumed = true
            status.pointee = .haveData
            return buf
        }
        guard error == nil, out.frameLength > 0, let ch = out.floatChannelData else { return }
        let converted = Array(UnsafeBufferPointer(start: ch[0], count: Int(out.frameLength)))
        lock.withLock { ring.push(converted) }
    }
}
