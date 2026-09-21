import Foundation

/// A boundary produced from the capture sample clock.
///
/// The event is metadata only. The capture path still forwards every sample to
/// the recogniser, including the pre-roll and the post-roll around a pause.
enum SpeechActivityEvent: Equatable, Sendable {
    case speechStarted(sampleRange: Range<Int>)
    case gap(sampleRange: Range<Int>)
}

/// Small deterministic speech-activity state machine used by captions.
///
/// It deliberately does not gate audio. Relative energy handles a stable music
/// bed, hysteresis prevents a consonant from splitting a sentence, and the
/// sample range makes the boundary auditable without retaining another audio
/// copy. This is intentionally a level detector, not a promise of speaker
/// separation.
struct SpeechActivityDetector: Sendable {
    struct Configuration: Sendable {
        var onsetMultiplier: Float = 2.0
        var offsetMultiplier: Float = 1.78
        var minimumSpeechMs = 100
        var preRollMs = 200
        var postRollMs = 400
        var holdMs = 750
        var absoluteThreshold: Float = 0.0056
        var bucketSeconds: Float = 6
    }

    var configuration: Configuration

    private var currentBucketMin: Float = .greatestFiniteMagnitude
    private var previousBucketMin: Float = .greatestFiniteMagnitude
    private var framesInBucket = 0
    private var quietFrames = 0
    private var speechFrames = 0
    private var observedSamples = 0
    private var speechStartSample: Int?
    private var speaking = false

    init(configuration: Configuration = Configuration()) {
        self.configuration = configuration
    }

    var noiseFloor: Float { min(currentBucketMin, previousBucketMin) }

    var currentThreshold: Float {
        max(configuration.absoluteThreshold, noiseFloor * configuration.offsetMultiplier)
    }

    var isSpeaking: Bool { speaking }
    var observedSampleCount: Int { observedSamples }

    mutating func reset() {
        currentBucketMin = .greatestFiniteMagnitude
        previousBucketMin = .greatestFiniteMagnitude
        framesInBucket = 0
        quietFrames = 0
        speechFrames = 0
        observedSamples = 0
        speechStartSample = nil
        speaking = false
    }

    mutating func process(rms: Float, frames: Int, sampleRate: Float) -> SpeechActivityEvent? {
        guard frames > 0, sampleRate > 0, rms.isFinite else { return nil }

        let start = observedSamples
        observedSamples += frames
        currentBucketMin = min(currentBucketMin, max(0, rms))
        framesInBucket += frames
        let bucketFrames = max(1, Int(configuration.bucketSeconds * sampleRate))
        if framesInBucket >= bucketFrames {
            previousBucketMin = currentBucketMin
            currentBucketMin = max(0, rms)
            framesInBucket = 0
        }

        let onsetThreshold = max(configuration.absoluteThreshold,
                                  noiseFloor * configuration.onsetMultiplier)
        let offsetThreshold = currentThreshold
        let minimumSpeechFrames = max(1, Int(Double(configuration.minimumSpeechMs) / 1000 * Double(sampleRate)))
        let postRollFrames = max(1, Int(Double(configuration.postRollMs) / 1000 * Double(sampleRate)))
        let configuredHoldFrames = max(1, Int(Double(configuration.holdMs) / 1000 * Double(sampleRate)))
        let endFrames = max(postRollFrames, configuredHoldFrames)

        if !speaking {
            quietFrames = 0
            if rms >= onsetThreshold {
                speechFrames += frames
                if speechFrames >= minimumSpeechFrames {
                    speaking = true
                    let preRoll = max(0, Int(Double(configuration.preRollMs) / 1000 * Double(sampleRate)))
                    speechStartSample = max(0, observedSamples - speechFrames - preRoll)
                    return .speechStarted(sampleRange: (speechStartSample ?? start)..<observedSamples)
                }
            } else {
                speechFrames = 0
            }
            return nil
        }

        if rms <= offsetThreshold {
            quietFrames += frames
            if quietFrames >= endFrames {
                let rangeStart = speechStartSample ?? start
                speaking = false
                speechFrames = 0
                quietFrames = 0
                speechStartSample = nil
                return .gap(sampleRange: rangeStart..<observedSamples)
            }
        } else {
            quietFrames = 0
        }
        return nil
    }
}
