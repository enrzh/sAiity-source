import Accelerate
import AVFoundation
import CoreGraphics
import Foundation
import ScreenCaptureKit

/// Captures **system** audio (whatever is playing: a video, a call, a browser
/// tab) via ScreenCaptureKit, converts it to the format the speech engine
/// wants, and hands it over.
///
/// Two things make this the right capture path rather than the microphone:
/// it hears the content itself instead of the room, and it needs no virtual
/// audio device like BlackHole. The cost is a Screen Recording permission
/// prompt, and that DRM-protected playback may arrive as silence — a platform
/// limit, not something to engineer around.
///
/// Measured behaviour on this machine, which drives the design below:
///   - With nothing playing, SCK delivers buffers **forever** at real time
///     (50/s, 960 frames each, 48 kHz mono Float32) and every sample is
///     bit-exact zero. So "buffers are arriving" says nothing about whether
///     there is audio — silence has to be measured, and the real failure
///     signal is the inverse: buffers *stopping*.
///   - The tap sits **upstream of the output device's volume and mute stage**.
///     Muting the Mac or setting volume to 0 does not attenuate capture at all:
///     a source peaking at 0.5 was captured at 0.49999687 in both cases. We
///     therefore keep transcribing audio the user cannot hear, and the UI has
///     to say so rather than let the user assume muting stops it.
final class SystemAudioCapture: NSObject, SCStreamOutput, @unchecked Sendable {
    /// What the capture pipeline is currently doing, for the UI to display.
    enum State: Equatable {
        case audible
        case silent        // stream healthy, but the samples are digital silence
        case stalled       // no buffers at all — the stream itself died
    }

    /// A pause in speech, as distinct from "nothing is playing".
    ///
    /// `.silent` needs two seconds of bit-exact zero, which is right for "the
    /// video ended" and useless for "the speaker took a breath" — a pause in
    /// real audio still carries room tone, music and codec noise. This is a
    /// separate, much shorter signal on level rather than on exact zero, and it
    /// is what lets a finished sentence be translated the moment the speaker
    /// stops instead of waiting out a time budget.
    var onSpeechGap: (@Sendable () -> Void)?

    private var stream: SCStream?
    private var converter: AVAudioConverter?
    private var targetFormat: AVAudioFormat?
    private var onBuffer: (@Sendable (AVAudioPCMBuffer) -> Void)?
    private var onState: (@Sendable (State) -> Void)?

    private let lock = NSLock()
    private var lastBufferAt = Date.distantPast
    private var silentFrames = 0
    private var state: State = .silent
    private var watchdog: DispatchSourceTimer?

    /// Digital silence is bit-exact 0.0, so any epsilon below the quietest real
    /// signal works. Measured: 0 nonzero samples out of 7.4 M over 154 s idle,
    /// while a source at −60 dBFS peak still transcribed correctly.
    private static let silenceEpsilon: Float = 1e-7
    /// 2 s at 48 kHz — long enough not to trip on the gap between two words.
    private static let silenceHoldFrames = 96_000

    /// Speech-gap detection lives in `SpeechGapDetector` — pure, unit-tested,
    /// and adaptive to the material's own noise floor. RMS, not peak: a single
    /// click during a pause should not reset it. The hold decides where
    /// sentences end (the caption pipeline treats a gap as the end of a
    /// thought), and its default is measured: at 450 ms it fired on the pause a
    /// speaker leaves at a comma, and "Untertitel für alles, was der Mac
    /// abspielt, direkt auf dem Gerät." was split into three, each translated
    /// without the others.
    private var gapDetector = SpeechGapDetector(holdFrames: 36_000)
    /// Mirrors `SpeechGap.enabled`; cached because `classify` runs ~50×/s on
    /// the capture queue.
    private var gapEnabled = true
    /// Quietest RMS seen in the current diagnostic window, and its length.
    private var rmsFloor: Float = .greatestFiniteMagnitude
    private var rmsWindowFrames = 0

    /// Re-read the speech-gap setting. Called on start, and again whenever the
    /// user moves the slider, so a change lands on the running session instead
    /// of waiting for the next one.
    func applySpeechGapSettings() {
        gapEnabled = SpeechGap.enabled
        gapDetector.holdFrames = SpeechGap.holdFrames(at: Self.streamSampleRate)
        // Forget both the accumulated quiet — a shortened threshold must not
        // fire immediately on silence banked under the longer one — and the
        // learned noise floor, since a new session may be different material.
        gapDetector.reset()
    }

    /// SCStream delivers 48 kHz; the gap threshold is measured against the
    /// stream, not the resampled buffer the recogniser receives.
    private static let streamSampleRate: Double = 48_000

    // Diagnostics: audio seconds captured vs audio seconds actually delivered.
    private var inSeconds = 0.0
    private var outSeconds = 0.0
    private var lastReport = 0.0
    private let debug = TestHooks.verboseLogging

    /// Excludes our own process so the app can never transcribe itself.
    func start(targetFormat: AVAudioFormat,
               onBuffer: @escaping @Sendable (AVAudioPCMBuffer) -> Void,
               onState: @escaping @Sendable (State) -> Void) async throws {
        self.targetFormat = targetFormat
        self.onBuffer = onBuffer
        self.onState = onState
        // The stream is 48 kHz regardless of the target format the recogniser
        // wants, and `classify` measures the stream, so the conversion uses the
        // stream's rate rather than the target's.
        applySpeechGapSettings()

        // Ask up front rather than letting SCK fail with a generic error. The
        // first call raises the system prompt; macOS only actually grants it
        // after the app is relaunched, so say that plainly.
        if !CGPreflightScreenCaptureAccess() {
            CGRequestScreenCaptureAccess()
            throw NSError(domain: "sAiity", code: 2, userInfo: [
                NSLocalizedDescriptionKey:
                    String(localized: "Screen Recording permission needed (that is how macOS gates system audio). Allow sAiity in System Settings → Privacy & Security → Screen Recording, then relaunch.")
            ])
        }

        // Audio-only capture still needs a content filter; use the main display
        // and keep the video stream as small/slow as possible since we discard it.
        let content = try await SCShareableContent.excludingDesktopWindows(false,
                                                                          onScreenWindowsOnly: false)
        guard let display = content.displays.first else {
            throw NSError(domain: "sAiity", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: String(localized: "No display available to attach audio capture to.")])
        }
        let filter = SCContentFilter(display: display, excludingWindows: [])

        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.excludesCurrentProcessAudio = true
        config.sampleRate = 48_000
        config.channelCount = 1
        // Video is mandatory on the stream but we never read it — keep it tiny.
        config.width = 2
        config.height = 2
        config.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        config.queueDepth = 6

        let s = SCStream(filter: filter, configuration: config, delegate: nil)
        try s.addStreamOutput(self, type: .audio, sampleHandlerQueue: DispatchQueue(label: "captions.audio"))
        try await s.startCapture()
        self.stream = s

        lock.withLock { lastBufferAt = Date() }
        startWatchdog()
    }

    func stop() async {
        watchdog?.cancel()
        watchdog = nil
        try? await stream?.stopCapture()
        stream = nil
        converter = nil
        onBuffer = nil
        onState = nil
        lock.withLock {
            silentFrames = 0
            state = .silent
        }
    }

    /// A healthy stream fires ~50×/s even in total silence, so *no* callback is
    /// the real failure signal — not "no captions appeared".
    private func startWatchdog() {
        let t = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "captions.watchdog"))
        t.schedule(deadline: .now() + 1.5, repeating: 1.0)
        t.setEventHandler { [weak self] in
            guard let self else { return }
            let stalled = self.lock.withLock { Date().timeIntervalSince(self.lastBufferAt) > 1.5 }
            if stalled { self.transition(to: .stalled) }
        }
        t.resume()
        watchdog = t
    }

    private func transition(to new: State) {
        let changed = lock.withLock { () -> Bool in
            guard state != new else { return false }
            state = new
            return true
        }
        if changed { onState?(new) }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
                of type: SCStreamOutputType) {
        guard type == .audio,
              let target = targetFormat,
              let onBuffer,
              sampleBuffer.isValid,
              let pcm = Self.pcmBuffer(from: sampleBuffer) else { return }

        lock.withLock { lastBufferAt = Date() }
        classify(pcm)

        if debug {
            inSeconds += Double(pcm.frameLength) / pcm.format.sampleRate
        }

        if pcm.format.sampleRate == target.sampleRate,
           pcm.format.channelCount == target.channelCount {
            if debug { report(out: Double(pcm.frameLength) / target.sampleRate) }
            onBuffer(pcm)
            return
        }

        // Engine sample rate rarely matches the 48 kHz we capture at, so convert.
        if converter == nil || converter?.inputFormat != pcm.format {
            converter = AVAudioConverter(from: pcm.format, to: target)
        }
        guard let converter else { return }

        let ratio = target.sampleRate / pcm.format.sampleRate
        let capacity = AVAudioFrameCount(Double(pcm.frameLength) * ratio) + 1024
        guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return }

        var consumed = false
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            if consumed { status.pointee = .noDataNow; return nil }
            consumed = true
            status.pointee = .haveData
            return pcm
        }
        if error == nil, out.frameLength > 0 {
            if debug { report(out: Double(out.frameLength) / target.sampleRate) }
            onBuffer(out)
        }
    }

    /// Peak magnitude on the raw float samples, before conversion. Cheap
    /// (vDSP over 960 frames) and exact: idle capture measures 0.0, not
    /// near-zero, so this cleanly separates "nothing is playing" from
    /// "something quiet is playing".
    private func classify(_ pcm: AVAudioPCMBuffer) {
        guard let ch = pcm.floatChannelData else { return }
        var peak: Float = 0
        vDSP_maxmgv(ch[0], 1, &peak, vDSP_Length(pcm.frameLength))

        if peak <= Self.silenceEpsilon {
            silentFrames += Int(pcm.frameLength)
            if silentFrames >= Self.silenceHoldFrames { transition(to: .silent) }
        } else {
            silentFrames = 0
            transition(to: .audible)
        }

        // Speech gaps, measured independently of the digital-silence state above
        // — quiet is not the same as nothing, and only the former marks the end
        // of a sentence.
        var rms: Float = 0
        vDSP_rmsqv(ch[0], 1, &rms, vDSP_Length(pcm.frameLength))
        guard gapEnabled else { return }
        // Diagnostics for "it only translates when I stop the video". The gap is
        // measured on the whole mix, so continuously scored material — a film,
        // most anime — can keep the RMS above the threshold through every pause
        // in speech, and then no sentence ever closes on a pause. Logging the
        // floor actually reached says whether that is what is happening, rather
        // than leaving it to be guessed at.
        if debug {
            rmsFloor = min(rmsFloor, rms)
            rmsWindowFrames += Int(pcm.frameLength)
            if rmsWindowFrames >= 48_000 * 5 {
                let db = rmsFloor > 0 ? 20 * log10(rmsFloor) : -.infinity
                let th = gapDetector.currentThreshold
                NSLog(String(format:
                    "sAiity gap: quietest RMS in 5s %.5f (%.1f dBFS), adaptive threshold %.5f (%.1f dBFS) — %@",
                    rmsFloor, db, th, 20 * log10(th),
                    rmsFloor < th ? "crosses" : "NEVER crosses"))
                rmsFloor = .greatestFiniteMagnitude
                rmsWindowFrames = 0
            }
        }
        if gapDetector.process(rms: rms, frames: Int(pcm.frameLength),
                               sampleRate: Float(Self.streamSampleRate)) {
            if debug { NSLog("sAiity gap: FIRED (floor \(gapDetector.noiseFloor))") }
            onSpeechGap?()
        }
    }

    /// If delivered audio-seconds lag captured audio-seconds, the resampler is
    /// eating audio and the analyzer's clock runs slow — which shows up as
    /// captions arriving seconds late.
    private func report(out seconds: Double) {
        outSeconds += seconds
        if inSeconds - lastReport >= 2.0 {
            lastReport = inSeconds
            NSLog(String(format: "sAiity audio: captured %.2fs delivered %.2fs (lag %.2fs)",
                         inSeconds, outSeconds, inSeconds - outSeconds))
        }
    }

    /// CMSampleBuffer (interleaved from SCK) -> AVAudioPCMBuffer.
    private static func pcmBuffer(from sampleBuffer: CMSampleBuffer) -> AVAudioPCMBuffer? {
        guard let fmtDesc = sampleBuffer.formatDescription,
              let asbd = fmtDesc.audioStreamBasicDescription else { return nil }
        var streamDesc = asbd
        guard let format = AVAudioFormat(streamDescription: &streamDesc) else { return nil }

        let frames = AVAudioFrameCount(sampleBuffer.numSamples)
        guard frames > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return nil }
        buffer.frameLength = frames

        do {
            try sampleBuffer.withAudioBufferList { abl, _ in
                guard let src = abl.unsafePointer.pointee.mBuffers.mData else { return }
                let dstABL = buffer.mutableAudioBufferList
                if let dst = dstABL.pointee.mBuffers.mData {
                    let bytes = min(Int(abl.unsafePointer.pointee.mBuffers.mDataByteSize),
                                    Int(dstABL.pointee.mBuffers.mDataByteSize))
                    memcpy(dst, src, bytes)
                }
            }
        } catch {
            return nil
        }
        return buffer
    }
}
