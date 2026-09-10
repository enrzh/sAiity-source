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
/// Where the capture callback delivers audio, indirected through a box.
///
/// The audio callback lives for as long as the `SCStream` does, while the
/// backend under it can be replaced — switching recognition engine or latency
/// tier builds a new one. Capturing the backend directly in that closure meant
/// the stream kept feeding the OLD, already-stopped backend after a switch, and
/// because both engines want the same 16 kHz format the capture session was
/// never rebuilt, so nothing ever corrected it. Two things followed, both
/// silent: the new engine received no audio at all and captions simply stopped,
/// and the dead backend's queue grew at roughly 64 KB/s — some 230 MB an hour —
/// with no pump left to drain it, for as long as the app stayed open.
final class BackendSink: @unchecked Sendable {
    private let lock = NSLock()
    private var backend: TranscriptionBackend?

    func point(at backend: TranscriptionBackend?) {
        lock.withLock { self.backend = backend }
    }

    /// Called ~50×/s from the capture queue. Reads the current backend under the
    /// lock and hands off; `feed` itself only copies samples and returns.
    func feed(_ buffer: AVAudioPCMBuffer) {
        let current = lock.withLock { backend }
        current?.feed(buffer)
    }
}

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

    /// End the current streaming session and reset it for reuse. Loaded model
    /// resources stay resident so a short-lived dictation session can start
    /// again without loading hundreds of megabytes a second time.
    func stop() async

    /// Release all model resources. Call this before deleting model files or
    /// discarding a backend permanently.
    func release() async

    /// Commit whatever is still volatile, without stopping. Called when the
    /// audio goes silent: an utterance boundary that is far more reliable than
    /// waiting for the engine to emit sentence punctuation — which the
    /// multilingual Nemotron often simply does not do.
    func flushPending() async

    /// Finish a short dictation session and return the engine's authoritative
    /// completed utterance when the backend can provide one. Unlike `stop()`,
    /// this must not emit the returned text through the live caption callback.
    func finishDictation() async -> String?

    /// The language identified from the AUDIO, where the engine can do that.
    /// Better than inferring it from the transcript's spelling for the case that
    /// defeats the text detector: a language whose model emits almost no text.
    /// Nil when the engine has no such ability.
    func detectedLanguage() async -> String?
}

/// Optional capability for deferred press-to-talk decoding. Live caption
/// backends do not need to implement this; dictation uses it when available so
/// the complete recording can be segmented and each region can start with
/// clean recogniser state.
protocol DictationSegmentTranscriber: AnyObject, Sendable {
    func transcribeDictation(samples: [Float],
                             regions: [DictationSpeechRegion]) async throws -> DictationTranscriptionResult
}

extension TranscriptionBackend {
    func flushPending() async {}
    func finishDictation() async -> String? {
        await flushPending()
        await stop()
        return nil
    }
    func detectedLanguage() async -> String? { nil }
    func release() async { await stop() }
}

enum BackendError: LocalizedError {
    case notPrepared

    var errorDescription: String? {
        switch self {
        case .notPrepared:
            return String(localized: "Backend used before prepare() finished.")
        }
    }
}
