import AVFoundation
import Foundation
import WhisperKit

/// Whisper in `translate` mode: speech in any supported language → **English
/// text**, in a single model pass.
///
/// This is the only genuinely realtime translation available locally. The
/// alternative — transcribe, then translate the text with Apple's Translation
/// framework — needs a per-pair download and can only start once a sentence has
/// been committed, so it always trails by a sentence. Whisper does both jobs at
/// once.
///
/// The hard limit: **X → English only**. Whisper's translate task has no other
/// target. For any other target language, Nemotron + Apple Translation remains
/// the path.
///
/// ## Making a batch model stream
///
/// Whisper has a fixed 30 s receptive field and no carried state, so every
/// decode is independent and "streaming" means re-transcribing an overlapping
/// window and diffing the result. Two consequences drive the design below:
/// re-decoding the same audio yields different text as right-context grows (so
/// nothing can be committed immediately), and compute is proportional to window
/// length (so the window must be cut back aggressively).
///
/// The commit rule is **LocalAgreement-2**: decode on a hop, and only commit the
/// longest common prefix between this decode and the previous one, minus a
/// couple of held-back words. Text that two independent decodes agree on is
/// stable; text that only the newest decode produced is not.
final class WhisperTranslateBackend: TranscriptionBackend, @unchecked Sendable {
    let name = "Whisper (speech → English)"

    /// large-v3. The smaller variants are false economy: turbo regresses to v2
    /// quality (notably worse on Thai and Cantonese) and distil-large-v3 is
    /// English-only despite its tempting 595 MB.
    private static let modelVariant = "openai_whisper-large-v3"

    private static let hop: TimeInterval = 1.0        // decode cadence
    private static let preroll: TimeInterval = 2.0    // acoustic left context
    private static let maxWindow: TimeInterval = 24.0 // stay clear of the 30 s limit
    private static let holdback = 2                   // words never committed at the tail
    private static let sampleRate: Double = 16_000

    private var kit: WhisperKit?
    private var format: AVAudioFormat?
    private var emit: (@Sendable (TranscriptChunk) -> Void)?

    private let lock = NSLock()
    private var ring: [Float] = []          // audio since `windowStart`
    private var prevHypothesis: [String] = []
    private var committed: [String] = []
    private var pump: Task<Void, Never>?

    var inputFormat: AVAudioFormat? {
        get async { format }
    }

    static var modelsDirectory: URL {
        ModelRegistry.root.appendingPathComponent("whisper", isDirectory: true)
    }

    /// The compiled model bundles, all three of which must be present. The old
    /// check was "the directory is not empty", which an interrupted download
    /// satisfies easily — WhisperKit leaves a HuggingFace cache behind well
    /// before any model is usable.
    static func isDownloaded() -> Bool {
        let base = modelsDirectory
            .appendingPathComponent("models/argmaxinc/whisperkit-coreml/\(modelVariant)")
        return ["AudioEncoder.mlmodelc", "TextDecoder.mlmodelc", "MelSpectrogram.mlmodelc"]
            .allSatisfy { FileManager.default.fileExists(atPath: base.appendingPathComponent($0).path) }
    }

    /// Fetch without loading. `prepare` also builds a `WhisperKit` instance,
    /// which pulls ~2.9 GB of CoreML into memory — pure waste when the user is
    /// only pre-downloading from the Models page.
    static func downloadWeights(progress: @escaping ProgressSink) async throws {
        _ = try await WhisperKit.download(
            variant: modelVariant,
            downloadBase: modelsDirectory,
            progressCallback: { p in
                progress(DownloadProgress(fraction: p.fractionCompleted, note: "Downloading Whisper…"))
            })
    }

    func prepare(locale: Locale, progress: @escaping @Sendable (String) -> Void) async throws {
        if !Self.isDownloaded() { progress("Downloading Whisper model (2.9 GB)…") }
        let folder = try await WhisperKit.download(
            variant: Self.modelVariant,
            downloadBase: Self.modelsDirectory,
            progressCallback: { p in
                progress("Downloading Whisper model… \(Int(p.fractionCompleted * 100))%")
            })

        progress("Loading Whisper…")
        let config = WhisperKitConfig(modelFolder: folder.path, download: false)
        kit = try await WhisperKit(config)

        format = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                               sampleRate: Self.sampleRate, channels: 1, interleaved: false)
        progress("Whisper ready.")
    }

    func start(onChunk: @escaping @Sendable (TranscriptChunk) -> Void) async throws {
        emit = onChunk
        lock.withLock {
            ring.removeAll(keepingCapacity: true)
            prevHypothesis.removeAll()
            committed.removeAll()
        }

        pump = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(Self.hop * 1_000_000_000))
                guard let self, !Task.isCancelled else { return }
                await self.decodeOnce(onChunk: onChunk)
            }
        }
    }

    func feed(_ buffer: AVAudioPCMBuffer) {
        guard let ch = buffer.floatChannelData else { return }
        let n = Int(buffer.frameLength)
        guard n > 0 else { return }
        let src = UnsafeBufferPointer(start: ch[0], count: n)
        lock.withLock {
            ring.append(contentsOf: src)
            // Bound the window; forceCut equivalent. Anything older than
            // maxWindow cannot influence the current utterance anyway.
            let cap = Int(Self.maxWindow * Self.sampleRate)
            if ring.count > cap { ring.removeFirst(ring.count - cap) }
        }
    }

    private func decodeOnce(onChunk: @escaping @Sendable (TranscriptChunk) -> Void) async {
        guard let kit else { return }
        let samples: [Float] = lock.withLock { ring }
        // Below ~0.8 s there is not enough for a useful decode.
        guard samples.count > Int(0.8 * Self.sampleRate) else { return }

        // Pure digital silence: do NOT decode. This is exactly where Whisper
        // hallucinates "Thank you." and "Subtitles by …" into the transcript.
        var peak: Float = 0
        for v in samples where abs(v) > peak { peak = abs(v) }
        guard peak > 0.005 else { return }

        let options = DecodingOptions(
            task: .translate,            // the whole point: speech -> English
            language: nil,               // let Whisper identify it from audio
            temperatureFallbackCount: 0, // keep latency predictable
            wordTimestamps: false,
            concurrentWorkerCount: 1     // default is 16; wrong for live use
        )
        guard let results = try? await kit.transcribe(audioArray: samples,
                                                      decodeOptions: options),
              let text = results.first?.text else { return }

        let words = text.split(separator: " ").map(String.init)
        guard !words.isEmpty else { return }

        let (finalPart, volatilePart): (String, String) = lock.withLock {
            // LocalAgreement-2: only text that two consecutive decodes agree on
            // is stable enough to commit.
            var agreed = 0
            while agreed < min(prevHypothesis.count, words.count),
                  prevHypothesis[agreed] == words[agreed] { agreed += 1 }
            let commitCount = max(0, agreed - Self.holdback)

            var newlyCommitted: [String] = []
            if commitCount > committed.count {
                newlyCommitted = Array(words[committed.count..<commitCount])
                committed = Array(words[0..<commitCount])
            }
            prevHypothesis = words
            let tail = words.count > committed.count
                ? Array(words[committed.count...]) : []
            return (newlyCommitted.joined(separator: " "), tail.joined(separator: " "))
        }

        if !finalPart.isEmpty { onChunk(TranscriptChunk(text: finalPart, isFinal: true)) }
        if !volatilePart.isEmpty { onChunk(TranscriptChunk(text: volatilePart, isFinal: false)) }
    }

    func stop() async {
        pump?.cancel()
        await pump?.value
        pump = nil
        lock.withLock {
            ring.removeAll(keepingCapacity: true)
            prevHypothesis.removeAll()
            committed.removeAll()
        }
        kit = nil
    }
}
