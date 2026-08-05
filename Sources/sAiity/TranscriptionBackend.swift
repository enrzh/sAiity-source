import AVFoundation
import Foundation

/// One chunk of recognised speech.
///
/// `isFinal == false` is a *volatile* result: the engine's current best guess,
/// which it may revise. Rendering volatile text is what makes captions feel
/// live; committing only finals is what keeps them from flickering. The overlay
/// keeps the last final line and shows the volatile tail after it.
struct TranscriptChunk: Sendable {
    let text: String
    let isFinal: Bool
    /// Seconds from the start of the analysed audio. Present on finals; the
    /// engine gives these to us for free because the transcriber is configured
    /// with `.audioTimeRange`, and without them there are no SRT timings.
    var start: Double = 0
    var end: Double = 0
    /// Per-word timings, finals only. A single final can span 15 seconds and
    /// four sentences, which is unusable as one subtitle cue — these are what
    /// make it splittable.
    var words: [TimedWord] = []
}

/// One attribute run (in practice one word) with its audio time range.
struct TimedWord: Sendable, Codable {
    let start: Double
    let end: Double
    let text: String
}

/// A pluggable speech-to-text engine.
///
/// Deliberately narrow so the non-Apple engines can slot in behind it later
/// without touching capture or UI. Concretely, the ones worth adding (all
/// proven by ghost-pepper on Apple Silicon):
///
///   - WhisperKit   — CoreML Whisper, 99 languages, SwiftPM, no cmake
///   - FluidAudio   — Parakeet v3, 25 languages, ~1.4 GB
///   - MLX Audio    — Nemotron streaming models, built for low latency
///
/// Each of those is "feed PCM, get text back", which is exactly this protocol.
protocol TranscriptionBackend: AnyObject, Sendable {
    /// Shown in the UI so it is always obvious which engine is running.
    var name: String { get }

    /// The PCM format this engine wants. Capture converts to it.
    /// Nil until `prepare` has succeeded.
    var inputFormat: AVAudioFormat? { get async }

    /// Download/allocate models. May take a while on first run.
    func prepare(locale: Locale, progress: @escaping @Sendable (String) -> Void) async throws

    /// Begin streaming. `onChunk` is called on an arbitrary task.
    func start(onChunk: @escaping @Sendable (TranscriptChunk) -> Void) async throws

    /// Feed captured audio, already converted to `inputFormat`.
    ///
    /// Synchronous on purpose. Capture delivers ~50 buffers a second, and an
    /// `async` signature meant each one was handed to its own unstructured
    /// `Task` — which have no ordering guarantee between them, so PCM could be
    /// appended out of order. Implementations must only copy the samples into a
    /// queue and return; the engine is driven from elsewhere.
    func feed(_ buffer: AVAudioPCMBuffer)

    /// Flush and tear down.
    func stop() async

    /// Commit whatever is still volatile, without stopping. Called when the
    /// audio goes silent: an utterance boundary that is far more reliable than
    /// waiting for the engine to emit sentence punctuation — which the
    /// multilingual Nemotron often simply does not do.
    func flushPending() async

    /// The language identified from the AUDIO, where the engine can do that.
    /// Better than inferring it from the transcript's spelling for the case that
    /// defeats the text detector: a language whose model emits almost no text.
    /// Nil when the engine has no such ability.
    func detectedLanguage() async -> String?
}

extension TranscriptionBackend {
    func flushPending() async {}
    func detectedLanguage() async -> String? { nil }
}

enum BackendError: LocalizedError {
    case localeUnsupported(Locale)
    case modelUnavailable(String)
    case notPrepared

    var errorDescription: String? {
        switch self {
        case .localeUnsupported(let l):
            return "No on-device speech model for \(l.identifier(.bcp47))."
        case .modelUnavailable(let why):
            return "Speech model unavailable: \(why)"
        case .notPrepared:
            return "Backend used before prepare() finished."
        }
    }
}
