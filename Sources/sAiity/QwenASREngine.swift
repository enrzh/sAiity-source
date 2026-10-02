import AudioCommon
import Foundation
import MLX
import Qwen3ASR
import SpeechVAD

/// Sample-clock storage shared by production VAD and weight-free boundary tests.
struct QwenSpeechBuffer {
    private var audio: [Float] = []
    private(set) var origin = 0
    private var speechStart: Int?
    private var transcribedThrough = 0
    var retainedSampleCount: Int { audio.count }
    static let sampleRate = 16_000
    static let silenceHistorySamples = sampleRate
    static let boundaryContextSamples = sampleRate / 5

    mutating func append(_ samples: [Float], events: [VADEvent], flush: Bool = false) -> [[Float]] {
        audio.append(contentsOf: samples)
        var slices: [[Float]] = []
        for event in events {
            switch event {
            case .speechStarted(let time):
                speechStart = max(origin, Int((Double(time) * Double(Self.sampleRate)).rounded()) - Self.boundaryContextSamples)
            case .speechEnded(let segment):
                let end = Int((Double(segment.endTime) * Double(Self.sampleRate)).rounded()) + Self.boundaryContextSamples
                slices += takeSlices(endingAt: end)
                speechStart = nil
            }
        }
        let maximum = Int(QwenASREngine.forceSplitSeconds * Double(Self.sampleRate))
        while let start = speechStart, origin + audio.count - max(start, transcribedThrough) >= maximum {
            if let slice = takeSlice(endingAt: max(start, transcribedThrough) + maximum) { slices.append(slice) }
            speechStart = transcribedThrough
        }
        if flush, speechStart != nil {
            slices += takeSlices(endingAt: origin + audio.count)
            speechStart = nil
        }
        if speechStart == nil {
            drop(through: max(origin, origin + audio.count - Self.silenceHistorySamples))
        }
        return slices
    }

    private mutating func takeSlices(endingAt end: Int) -> [[Float]] {
        var slices: [[Float]] = []
        let maximum = Int(QwenASREngine.forceSplitSeconds * Double(Self.sampleRate))
        let availableEnd = min(end, origin + audio.count)
        while max(speechStart ?? transcribedThrough, transcribedThrough) < availableEnd {
            let start = max(origin, max(speechStart ?? transcribedThrough, transcribedThrough))
            guard let slice = takeSlice(endingAt: min(availableEnd, start + maximum)) else { break }
            slices.append(slice)
        }
        return slices
    }

    private mutating func takeSlice(endingAt endAbsolute: Int) -> [Float]? {
        let start = max(origin, max(speechStart ?? transcribedThrough, transcribedThrough))
        let end = min(max(endAbsolute, start), origin + audio.count)
        guard end > start else { return nil }
        let slice = Array(audio[(start - origin)..<(end - origin)])
        transcribedThrough = end
        drop(through: end)
        return slice
    }

    private mutating func drop(through end: Int) {
        let count = min(max(0, end - origin), audio.count)
        guard count > 0 else { return }
        audio.removeFirst(count)
        origin += count
        transcribedThrough = max(transcribedThrough, origin)
    }
}

/// Qwen3-ASR as a caption engine.
///
/// Two sizes, one behaviour. `transcribeStream` cannot be called on each
/// arriving chunk: it treats the end of whatever buffer it was given as the
/// end of speech, so a growing prefix would finalize a half-sentence and then
/// re-decode it. Partials are worse. On the three measured clips the first
/// partial ended in a period that was not the sentence, the reconciler
/// committed that fragment, and the correction never arrived.
///
/// So this engine segments with the same Silero VAD the probe used, and
/// transcribes a slice once — when speech pauses, or after ten seconds of
/// uninterrupted speech. The callback receives only the growing final text.
final class QwenASREngine: FluidStreamingEngine, @unchecked Sendable {
    enum Size: String, Sendable {
        case small
        case large

        var modelId: String {
            switch self {
            case .small: "aufklarer/Qwen3-ASR-0.6B-MLX-4bit"
            case .large: "aufklarer/Qwen3-ASR-1.7B-MLX-4bit"
            }
        }

        var directoryName: String {
            switch self {
            case .small: "qwen3-asr-0.6b-4bit"
            case .large: "qwen3-asr-1.7b-4bit"
            }
        }

        var advertisedBytes: Int64 {
            switch self {
            case .small: 700 * 1_048_576
            case .large: 2_200 * 1_048_576
            }
        }
    }

    /// A monologue with no pause still has to produce a caption. Matches the
    /// library stream's own force-split.
    static let forceSplitSeconds: Double = 10

    let size: Size
    let sampleRate: Double = 16_000

    private let lock = NSLock()
    private var asr: Qwen3ASRModel?
    private var vadModel: SileroVADModel?
    private var vad: StreamingVADProcessor?
    private var onPartial: (@Sendable (String) -> Void)?
    private var audio = QwenSpeechBuffer()
    private var committed = ""
    private let resourceRoot: URL?

    private static let residentLock = NSLock()
    private static var resident: [Size: QwenASREngine] = [:]

    init(size: Size, resourceRoot: URL? = Bundle.main.resourceURL) {
        self.size = size
        self.resourceRoot = resourceRoot
    }

    static func directory(for size: Size) -> URL {
        ModelRegistry.root.appendingPathComponent(size.directoryName, isDirectory: true)
    }

    static func vadDirectory(for size: Size) -> URL {
        directory(for: size).appendingPathComponent("vad", isDirectory: true)
    }

    private static let completionMarker = "saiity-complete"

    static func isDownloaded(_ size: Size) -> Bool {
        let dir = directory(for: size)
        let marker = dir.appendingPathComponent(completionMarker)
        let vocab = dir.appendingPathComponent("vocab.json")
        return FileManager.default.fileExists(atPath: marker.path)
            && FileManager.default.fileExists(atPath: vocab.path)
    }

    static func extending(_ committed: String, with addition: String) -> String {
        let next = addition.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !next.isEmpty else { return committed }
        return CaptionTextMerger.concatenate(committed, next)
    }

    static func downloadWeights(size: Size, progress: @escaping ProgressSink) async throws {
        let dir = directory(for: size)
        let vadDir = vadDirectory(for: size)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: vadDir, withIntermediateDirectories: true)
        progress(DownloadProgress(fraction: 0, note: String(localized: "Downloading Qwen3-ASR…")))
        try await HuggingFaceDownloader.downloadWeights(
            modelId: size.modelId,
            to: dir,
            additionalFiles: ["vocab.json", "merges.txt", "tokenizer_config.json"]
        ) { fraction in
            progress(DownloadProgress(fraction: fraction * 0.9,
                                      note: String(localized: "Downloading Qwen3-ASR…")))
        }
        progress(DownloadProgress(fraction: 0.9, note: String(localized: "Downloading the voice detector…")))
        try await HuggingFaceDownloader.downloadWeights(
            modelId: SileroVADModel.defaultModelId,
            to: vadDir
        ) { fraction in
            progress(DownloadProgress(fraction: 0.9 + fraction * 0.1,
                                      note: String(localized: "Downloading the voice detector…")))
        }
        let marker = dir.appendingPathComponent(completionMarker)
        FileManager.default.createFile(atPath: marker.path, contents: Data())
        progress(DownloadProgress(fraction: 1, note: String(localized: "Qwen3-ASR downloaded.")))
    }

    /// Drop a loaded model without waiting. Settings calls this from a button
    /// handler, and the weights have to be unmapped before the files are unlinked.
    static func forgetLoadedModel(_ size: Size) {
        let engine = residentLock.withLock { resident[size] }
        engine?.dropModel()
    }

    func load(progress: @escaping @Sendable (String) -> Void) async throws {
        guard TranslationPreflight.hasBundledMetalLibrary(resourceRoot: resourceRoot) else {
            throw TranslationEngineError.runtimeUnavailable(
                String(localized: "The MLX Metal library is missing from this app build."))
        }
        MemoryPolicy.prepareForMLX()
        if !Self.isDownloaded(size) {
            progress(String(localized: "Downloading Qwen3-ASR…"))
            try await Self.downloadWeights(size: size) { update in
                progress(update.note)
            }
        }
        progress(String(localized: "Loading Qwen3-ASR…"))
        let dir = Self.directory(for: size)
        let model = try await Qwen3ASRModel.fromPretrained(
            modelId: size.modelId,
            cacheDir: dir,
            offlineMode: true
        ) { _, note in
            progress(note)
        }
        let vadWeights = try await SileroVADModel.fromPretrained(
            cacheDir: Self.vadDirectory(for: size),
            offlineMode: true
        ) { _, note in
            progress(note)
        }
        lock.withLock {
            asr = model
            vadModel = vadWeights
            vad = StreamingVADProcessor(model: vadWeights)
        }
        Self.residentLock.withLock { Self.resident[size] = self }
        progress(String(localized: "Qwen3-ASR ready."))
    }

    func setPartial(_ callback: @escaping @Sendable (String) -> Void) async {
        lock.withLock { onPartial = callback }
    }

    func reset() async {
        lock.withLock {
            audio = QwenSpeechBuffer()
            committed = ""
            if let vadModel {
                vad = StreamingVADProcessor(model: vadModel)
            }
        }
    }

    func process(_ samples: [Float]) async throws {
        let model = lock.withLock { asr }
        guard let model else { throw BackendError.notPrepared }
        let events = lock.withLock { () -> [VADEvent] in
            return vad?.process(samples: samples) ?? []
        }
        await commit(samples: samples, events: events, model: model, flushOpenSpeech: false)
    }

    func finishSession() async -> String? {
        let model = lock.withLock { asr }
        guard let model else {
            let text = lock.withLock { committed }
            return text.isEmpty ? nil : text
        }
        let events = lock.withLock { vad?.flush() ?? [] }
        await commit(samples: [], events: events, model: model, flushOpenSpeech: true)
        let text = lock.withLock { committed }
        return text.isEmpty ? nil : text
    }

    func teardown() async {
        dropModel()
        let size = size
        Self.residentLock.withLock {
            if Self.resident[size] === self { Self.resident[size] = nil }
        }
    }

    func detectedLanguage() async -> String? { nil }

    private func dropModel() {
        lock.withLock {
            asr = nil
            vadModel = nil
            vad = nil
            audio = QwenSpeechBuffer()
        }
        MemoryPolicy.releaseCaches()
    }

    /// Transcribe each closed slice once, then publish the extended transcript.
    private func commit(samples: [Float], events: [VADEvent], model: Qwen3ASRModel, flushOpenSpeech: Bool) async {
        let slices = lock.withLock { audio.append(samples, events: events, flush: flushOpenSpeech) }

        for slice in slices where !slice.isEmpty {
            let text = model.transcribe(audio: slice, sampleRate: Int(sampleRate))
            let update = lock.withLock { () -> (callback: (@Sendable (String) -> Void)?, text: String)? in
                let next = Self.extending(committed, with: text)
                guard next != committed else { return nil }
                committed = next
                return (onPartial, next)
            }
            if let update, let callback = update.callback, !update.text.isEmpty {
                callback(update.text)
            }
        }
    }

}
