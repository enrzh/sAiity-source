import Foundation

/// Compatibility wrapper around the caption speech-activity state machine.
///
/// Existing capture code only needs a Boolean gap decision, while diagnostics
/// and tests can inspect the richer event and sample-clock state. Audio is
/// always forwarded independently of this value.
///
/// This is a value type on purpose: it is only safe while exactly one thread
/// owns it. `SpeechGapGate` below is what the capture path uses, because the
/// settings UI reaches the same state from the main actor.
struct SpeechGapDetector {
    init(holdFrames: Int) {
        var configuration = SpeechActivityDetector.Configuration()
        configuration.holdMs = max(1, Int(Double(holdFrames) / 48_000 * 1000))
        activity = SpeechActivityDetector(configuration: configuration)
    }

    private var activity: SpeechActivityDetector

    var holdFrames: Int {
        get { Int(Double(activity.configuration.holdMs) / 1000 * 48_000) }
        set {
            activity.configuration.holdMs = max(1, Int(Double(newValue) / 48_000 * 1000))
        }
    }

    static let absoluteThreshold: Float = SpeechActivityDetector.Configuration().absoluteThreshold
    static let headroom: Float = SpeechActivityDetector.Configuration().offsetMultiplier
    static let bucketSeconds: Float = SpeechActivityDetector.Configuration().bucketSeconds

    var noiseFloor: Float { activity.noiseFloor }
    var currentThreshold: Float { activity.currentThreshold }
    var isSpeaking: Bool { activity.isSpeaking }
    var observedSampleCount: Int { activity.observedSampleCount }

    mutating func reset() {
        activity.reset()
    }

    /// Returns the next activity event, if one completed in this buffer.
    mutating func processEvent(rms: Float, frames: Int, sampleRate: Float) -> SpeechActivityEvent? {
        activity.process(rms: rms, frames: frames, sampleRate: sampleRate)
    }

    /// Feed one buffer and report whether a speech gap has just completed.
    mutating func process(rms: Float, frames: Int, sampleRate: Float) -> Bool {
        if case .gap = processEvent(rms: rms, frames: frames, sampleRate: sampleRate) {
            return true
        }
        return false
    }
}

/// The synchronized boundary every capture buffer passes through to reach the
/// detector.
///
/// Two threads used to write the same `SpeechGapDetector`: `classify` runs on
/// ScreenCaptureKit's callback queue fifty times a second, and
/// `applySpeechGapSettings()` runs on the main actor the instant the user moves
/// the Pause-length slider. `holdFrames` and `reset()` are multi-field writes to
/// a state machine, so a slider drag mid-session could read a half-updated
/// threshold, lose a gap event, or arm with one hold and fire with another —
/// none of which is reproducible and all of which looks like "it only
/// translates sometimes". Every field a buffer touches is behind one lock here,
/// and no callback is ever invoked while it is held: callers get a value back
/// and act on it after the lock is released, so a settings change can never
/// re-enter through a notification.
final class SpeechGapGate: @unchecked Sendable {
    /// One Settings readout, sampled over a fixed window of capture audio.
    struct Diagnostics: Equatable, Sendable {
        var floor: Float
        var threshold: Float
        var fires: Int
    }

    /// What one buffer produced. Filled under the lock, acted on outside it.
    struct Reading: Equatable, Sendable {
        var diagnostics: Diagnostics? = nil
        /// A completed pause, in capture-sample coordinates.
        var gap: Range<Int>? = nil
        /// A stretch of speech that just armed the detector.
        var speechStarted: Range<Int>? = nil
        /// The detector's noise floor after this buffer, for the verbose log.
        var noiseFloor: Float = 0
    }

    /// Five seconds of 48 kHz audio between Settings readouts. Sized in frames,
    /// not seconds, because it is the capture clock the window is measured on.
    static let diagnosticFrames = 240_000

    private let lock = NSLock()
    private var detector: SpeechGapDetector
    private var enabled: Bool
    /// Quietest RMS seen in the current diagnostic window.
    private var floor: Float = .greatestFiniteMagnitude
    private var windowFrames = 0
    /// Pauses that actually ended a sentence.
    private var fires = 0

    init(holdFrames: Int = 36_000, enabled: Bool = true) {
        detector = SpeechGapDetector(holdFrames: holdFrames)
        self.enabled = enabled
    }

    /// A setting changed, mid-session.
    ///
    /// Applied as one transaction: the flag, the hold and the reset land
    /// together, so no buffer can see the new hold with the old accumulated
    /// quiet. Forgetting the accumulated quiet is the point of the reset — a
    /// shortened threshold must not fire immediately on silence banked under the
    /// longer one — as is forgetting the learned noise floor, since a new
    /// session may be different material.
    func apply(enabled: Bool, holdFrames: Int) {
        lock.withLock {
            self.enabled = enabled
            detector.holdFrames = holdFrames
            detector.reset()
        }
    }

    /// A session ended. The next one starts from a clean gate: a floor learned
    /// from the last video must not arm this one, and the fire count is a
    /// per-session readout.
    func reset() {
        lock.withLock {
            detector.reset()
            floor = .greatestFiniteMagnitude
            windowFrames = 0
            fires = 0
        }
    }

    /// Pauses that closed a sentence in this session. Read on demand, never
    /// cached: it is the same number the diagnostics window reports.
    var fireCount: Int { lock.withLock { fires } }

    /// Feed one buffer of capture audio.
    ///
    /// Disabled is a hard stop, not a pause: with gaps off the detector is left
    /// exactly as it was, so turning the setting back on resumes rather than
    /// replaying a window of audio it never looked at.
    func consume(rms: Float, frames: Int, sampleRate: Float) -> Reading {
        lock.withLock {
            var reading = Reading(noiseFloor: detector.noiseFloor)
            guard enabled else { return reading }
            floor = min(floor, rms)
            windowFrames += frames
            if windowFrames >= Self.diagnosticFrames {
                reading.diagnostics = Diagnostics(floor: floor,
                                                  threshold: detector.currentThreshold,
                                                  fires: fires)
                floor = .greatestFiniteMagnitude
                windowFrames = 0
            }
            if let event = detector.processEvent(rms: rms, frames: frames,
                                                 sampleRate: sampleRate) {
                switch event {
                case .speechStarted(let range):
                    reading.speechStarted = range
                case .gap(let range):
                    fires += 1
                    reading.gap = range
                }
            }
            reading.noiseFloor = detector.noiseFloor
            return reading
        }
    }
}
