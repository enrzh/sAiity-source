import Foundation

/// Compatibility wrapper around the caption speech-activity state machine.
///
/// Existing capture code only needs a Boolean gap decision, while diagnostics
/// and tests can inspect the richer event and sample-clock state. Audio is
/// always forwarded independently of this value.
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
