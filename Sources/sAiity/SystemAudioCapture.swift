import Accelerate
import AppKit
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
/// Which audio the stream captures: the whole system mix (the default), or a
/// single application. Scoping is what keeps notification pings, a second
/// video, or a game out of a meeting's captions — and it removes at the
/// source the whole-mix failure mode where a music bed from another app holds
/// RMS above the speech-gap threshold through every pause.
enum CaptureScope {
    /// Bundle id of the single app to capture, or nil for everything.
    /// Applies when captions next start; the filter is built at that moment.
    static var appBundleID: String? {
        get { UserDefaults.standard.string(forKey: "captureAppBundleID") }
        set { UserDefaults.standard.set(newValue, forKey: "captureAppBundleID") }
    }

    static func displayName(for bundleID: String) -> String {
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            .first?.localizedName ?? bundleID
    }
}

final class SystemAudioCapture: NSObject, SCStreamOutput, @unchecked Sendable {
    /// What the capture pipeline is currently doing, for the UI to display.
    enum State: Equatable {
        case audible
        case silent        // stream healthy, but the samples are digital silence
        case stalled       // no buffers at all — the stream itself died
    }

    /// Live speech-gap numbers for the Settings page, posted every 5 s of
    /// audio while running (userInfo: floor, threshold, fires) and once with
    /// no userInfo on stop. This is the slider's missing feedback: tuning the
    /// pause length used to mean dragging blind and watching captions for a
    /// minute to infer whether sentences now close at commas or not at all.
    static let gapDiagnostics = Notification.Name("saiityGapDiagnostics")

    /// A pause in speech, as distinct from "nothing is playing".
    ///
    /// `.silent` needs two seconds of bit-exact zero, which is right for "the
    /// video ended" and useless for "the speaker took a breath" — a pause in
    /// real audio still carries room tone, music and codec noise. This is a
    /// separate, much shorter signal on level rather than on exact zero, and it
    /// is what lets a finished sentence be translated the moment the speaker
    /// stops instead of waiting out a time budget.
    ///
    /// Set from the main actor, read on the capture queue, so the accessors take
    /// the same lock as the rest of the shared state — a closure is two words
    /// wide and a torn one is a jump through a stale context.
    var onSpeechGap: (@Sendable (Range<Int>) -> Void)? {
        get { lock.withLock { speechGapHandler } }
        set { lock.withLock { speechGapHandler = newValue } }
    }
    private var speechGapHandler: (@Sendable (Range<Int>) -> Void)?

    private var stream: SCStream?
    private var converter: AVAudioConverter?
    private var targetFormat: AVAudioFormat?
    private var onBuffer: (@Sendable (AVAudioPCMBuffer) -> Void)?
    private var onState: (@Sendable (State) -> Void)?

    /// How the opt-in mic mixing fared at this session's start, for the UI.
    /// A mic that cannot start never takes the captions down with it — the
    /// mic is an addition, and its failure is reported, not propagated.
    enum MicStatus: Equatable { case off, mixing, denied, failed }
    private(set) var micStatus: MicStatus = .off
    private var micMixer: MicMixer?

    private let lock = NSLock()
    private var lastBufferAt = Date.distantPast
    /// Consecutive digital-silence frames. Capture queue and `stop()` both write
    /// it, so it lives under `lock` like everything else the main actor can
    /// reach.
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
    ///
    /// Behind `SpeechGapGate` rather than held here directly, because the
    /// Pause-length slider reaches this state from the main actor while
    /// `classify` runs 50×/s on the capture queue, and the gate also owns the
    /// enabled flag it mirrors from `SpeechGap.enabled` plus the diagnostics
    /// window and the per-session fire count.
    private let gapGate = SpeechGapGate(holdFrames: 36_000)

    /// Apply the microphone setting to a session that is already running.
    ///
    /// Switching it off has to take effect NOW, not at the next start. The
    /// setting was read once in `start()`, so turning it off mid-session left
    /// the input tap open — and macOS quite correctly went on showing the
    /// microphone as in use, in an app whose whole argument is that it does
    /// not listen to you unless you ask it to. A privacy control that applies
    /// later is not a privacy control.
    ///
    /// Switching it on mid-session works too, and asks for permission the same
    /// way `start()` does.
    func applyMicSetting() async {
        let wanted = MicMix.enabled
        let running = lock.withLock { micMixer != nil }
        guard wanted != running else { return }

        if !wanted {
            let m = lock.withLock { () -> MicMixer? in
                let old = micMixer
                micMixer = nil          // the audio callback sees nil from here
                return old
            }
            m?.stop()
            micStatus = .off
            NSLog("sAiity mic: released mid-session (setting turned off)")
            return
        }
        // Turning it on: only meaningful while a stream is actually running;
        // otherwise the next start() will pick the setting up anyway.
        guard stream != nil else { return }
        guard await AVCaptureDevice.requestAccess(for: .audio) else {
            micStatus = .denied
            return
        }
        guard MicMix.shouldStart(requested: wanted, current: MicMix.enabled) else {
            micStatus = .off
            return
        }
        let m = MicMixer()
        do {
            try m.start(sampleRate: Self.streamSampleRate)
            guard MicMix.shouldStart(requested: wanted, current: MicMix.enabled) else {
                m.stop()
                micStatus = .off
                return
            }
            lock.withLock { micMixer = m }
            micStatus = .mixing
            NSLog("sAiity mic: mixing into a running session (setting turned on)")
        } catch {
            micStatus = .failed
            NSLog("sAiity mic: failed to start mid-session — \(error.localizedDescription)")
        }
    }

    /// Re-read the speech-gap setting. Called on start, and again whenever the
    /// user moves the slider, so a change lands on the running session instead
    /// of waiting for the next one.
    ///
    /// One call, one lock: the flag, the new hold and the reset that discards
    /// the quiet banked under the old one cannot be seen apart by a capture
    /// buffer arriving between them.
    func applySpeechGapSettings() {
        gapGate.apply(enabled: SpeechGap.enabled,
                      holdFrames: SpeechGap.holdFrames(at: Self.streamSampleRate))
    }

    /// SCStream delivers 48 kHz; the gap threshold is measured against the
    /// stream, not the resampled buffer the recogniser receives.
    static let streamSampleRate: Double = 48_000

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
        let filter: SCContentFilter
        if let bundleID = CaptureScope.appBundleID {
            // Failing beats falling back: the user scoped capture to one app,
            // and quietly capturing everything instead would break exactly the
            // expectation ("only Zoom is being captured") the setting exists
            // to give them.
            guard let app = content.applications.first(where: {
                $0.bundleIdentifier == bundleID
            }) else {
                throw NSError(domain: "sAiity", code: 3, userInfo: [
                    NSLocalizedDescriptionKey: String(
                        localized: "Capture is set to \(CaptureScope.displayName(for: bundleID)) only, and it is not running. Start it, or set capture back to Everything in Settings → Captions.")
                ])
            }
            filter = SCContentFilter(display: display, including: [app],
                                     exceptingWindows: [])
        } else {
            filter = SCContentFilter(display: display, excludingWindows: [])
        }

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

        // Opt-in mic mixing, before the stream starts delivering. The system
        // permission prompt appears here on first use — only ever after the
        // user has explicitly turned the setting on, which is the privacy
        // contract the README states.
        micStatus = .off
        if MicMix.enabled {
            if await AVCaptureDevice.requestAccess(for: .audio) {
                let m = MicMixer()
                do {
                    try m.start(sampleRate: Self.streamSampleRate)
                    lock.withLock { micMixer = m }
                    micStatus = .mixing
                    NSLog("sAiity mic: mixing into recognition")
                } catch {
                    micStatus = .failed
                    NSLog("sAiity mic: failed to start — \(error.localizedDescription)")
                }
            } else {
                micStatus = .denied
                NSLog("sAiity mic: permission denied")
            }
        }

        // From here on the microphone may already be open, so every exit has
        // to close it. Without this a failed stream start — or a Stop landing
        // during one — left the engine running with nothing consuming it: the
        // orange mic indicator lit, in an app that had just failed to start
        // captions. Nothing outside this type can see micMixer, so the
        // cleanup cannot be left to the caller.
        do {
            let s = SCStream(filter: filter, configuration: config, delegate: nil)
            try s.addStreamOutput(self, type: .audio,
                                  sampleHandlerQueue: DispatchQueue(label: "captions.audio"))
            try await s.startCapture()
            self.stream = s
        } catch {
            lock.withLock { () -> MicMixer? in
                let m = micMixer; micMixer = nil; return m
            }?.stop()
            micStatus = .off
            throw error
        }

        lock.withLock { lastBufferAt = Date() }
        gapGate.reset()
        startWatchdog()
    }

    func stop() async {
        watchdog?.cancel()
        watchdog = nil
        try? await stream?.stopCapture()
        // After stopCapture, so no buffer callback can race the teardown.
        lock.withLock { () -> MicMixer? in
            let m = micMixer; micMixer = nil; return m
        }?.stop()
        micStatus = .off
        stream = nil
        converter = nil
        onBuffer = nil
        onState = nil
        lock.withLock {
            silentFrames = 0
            state = .silent
        }
        // A finished session's floor, fire count and accumulated quiet are not the
        // next session's. The stream is already stopped, so no buffer can be in
        // flight to race this.
        gapGate.reset()
        // No userInfo = "the session ended, take the readout down".
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: Self.gapDiagnostics, object: nil)
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

        // Mic joins the stream BEFORE gap detection on purpose: the user
        // speaking is not a pause, and their sentences should close on their
        // own pauses like everyone else's.
        //
        // Read under the lock: this runs on the capture queue ~50×/s while the
        // setting can be switched off from the main actor, and tearing the
        // mixer down underneath an unsynchronised read of the reference is a
        // use-after-free waiting for a user who flips the toggle mid-sentence.
        let mixer = lock.withLock { micMixer }
        if let mixer, let ch = pcm.floatChannelData {
            mixer.mix(into: ch[0], count: Int(pcm.frameLength))
        }
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
    ///
    /// Runs on the capture queue ~50×/s, so every field it touches is either
    /// local to this call or under `lock`/`gapGate`. Each critical section ends
    /// before the next one starts: `transition` takes `lock` itself, and
    /// `onSpeechGap` and the diagnostics notification are fired with nothing
    /// held, so a listener that calls back into capture cannot deadlock.
    private func classify(_ pcm: AVAudioPCMBuffer) {
        guard let ch = pcm.floatChannelData else { return }
        let frames = Int(pcm.frameLength)
        var peak: Float = 0
        vDSP_maxmgv(ch[0], 1, &peak, vDSP_Length(pcm.frameLength))

        let desired: State? = lock.withLock {
            if peak <= Self.silenceEpsilon {
                silentFrames += frames
                return silentFrames >= Self.silenceHoldFrames ? .silent : nil
            }
            silentFrames = 0
            return .audible
        }
        if let desired { transition(to: desired) }

        // Speech gaps, measured independently of the digital-silence state above
        // — quiet is not the same as nothing, and only the former marks the end
        // of a sentence.
        var rms: Float = 0
        vDSP_rmsqv(ch[0], 1, &rms, vDSP_Length(pcm.frameLength))
        let reading = gapGate.consume(rms: rms, frames: frames,
                                      sampleRate: Float(Self.streamSampleRate))

        // Diagnostics for "it only translates when I stop the video". The gap is
        // measured on the scoped source, so continuously scored material — a
        // film, most anime — can keep the RMS above the threshold through every
        // pause in speech, and then no sentence ever closes on a pause. The
        // floor actually reached says whether that is what is happening; it
        // feeds the Settings readout next to the Pause-length slider (always)
        // and the log (verbose builds), rather than leaving it to be guessed at.
        if let sample = reading.diagnostics {
            if debug {
                let db = sample.floor > 0 ? 20 * log10(sample.floor) : -.infinity
                NSLog(String(format:
                    "sAiity gap: quietest RMS in 5s %.5f (%.1f dBFS), adaptive threshold %.5f (%.1f dBFS) — %@",
                    sample.floor, db, sample.threshold, 20 * log10(sample.threshold),
                    sample.floor < sample.threshold ? "crosses" : "NEVER crosses"))
            }
            DispatchQueue.main.async {
                NotificationCenter.default.post(
                    name: Self.gapDiagnostics, object: nil,
                    userInfo: ["floor": sample.floor, "threshold": sample.threshold,
                               "fires": sample.fires])
            }
        }
        if let range = reading.speechStarted {
            if debug { NSLog("sAiity speech: started samples=%@", "\(range)") }
        }
        if let range = reading.gap {
            if debug {
                NSLog("sAiity gap: FIRED samples=%@ floor %.6f",
                      "\(range)", reading.noiseFloor)
            }
            onSpeechGap?(range)
        }
    }

#if SAIITY_TEST_HOOKS
    /// Cached because a stress test drives this tens of thousands of times.
    private static let testFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                                  sampleRate: SystemAudioCapture.streamSampleRate,
                                                  channels: 1, interleaved: false)

    /// Drive `classify` the way the capture callback does, from a buffer built
    /// here — ScreenCaptureKit cannot be started from a unit test. A constant
    /// level makes peak and RMS the same value, so one level exercises both the
    /// digital-silence and the speech-gap half.
    func classifyForTests(level: Float, frames: Int = 960) {
        guard let format = Self.testFormat,
              let buffer = AVAudioPCMBuffer(pcmFormat: format,
                                            frameCapacity: AVAudioFrameCount(frames)),
              let samples = buffer.floatChannelData else { return }
        buffer.frameLength = AVAudioFrameCount(frames)
        samples[0].update(repeating: level, count: frames)
        classify(buffer)
    }

    /// Pauses that closed a sentence since the last `reset`.
    var gapFireCountForTests: Int { gapGate.fireCount }
#endif

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
