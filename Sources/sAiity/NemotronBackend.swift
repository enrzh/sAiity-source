import AVFoundation
import FluidAudio
import Foundation

/// NVIDIA Nemotron 3.5 streaming ASR, on-device via CoreML.
///
/// Why this one, out of everything evaluated:
///
///   - It is a **cache-aware FastConformer + RNN-T**, so it genuinely streams:
///     each audio chunk is encoded once with carried state. Whisper, by
///     contrast, has a fixed 30 s receptive field and no carried state, so
///     "streaming" there means re-decoding an overlapping window and diffing —
///     which costs latency, CPU, and a whole class of seam bugs.
///   - It ships as compiled `.mlmodelc`, so it runs on the Neural Engine.
///   - FluidAudio has **zero external dependencies**. The same Nemotron
///     checkpoint is reachable through MLX, but that drags in a 17-package tree.
///   - `languageCode: "auto"` gives a genuinely multilingual model plus
///     audio-level language identification — something Apple's Speech framework
///     exposes no public API for at all. Its own metadata declares 121 language
///     tags, well beyond the eight FluidAudio's README advertises.
///
/// The honest trade: this needs a 634 MB download where Apple's is a system
/// asset, and it is stronger on noisy or music-backed audio but not magic.
///
/// The buffering and teardown live in `StreamingASRBackend`, shared with
/// Parakeet — see that type for why exactly one `process()` may be in flight.
final class NemotronEngine: FluidStreamingEngine, @unchecked Sendable {
    /// 2240 ms chunks — FluidAudio's default balance of latency against the
    /// encoder's efficiency. Smaller chunks cut latency but cost proportionally
    /// more compute per second of audio.
    ///
    /// Each tier is a separate download of its own
    /// (`nemotron-multilingual/multilingual/<tier>ms`), not a runtime setting,
    /// so offering a choice here means offering another ~640 MB.
    static let chunkMs = 2240
    /// The tiers FluidAudio actually ships for this model. Anything else 404s.
    static let availableChunkMs = [1120, 2240]

    /// The tier the user selected. Persisted; invalid stored values fall back
    /// to the default rather than crashing a download against a bad URL.
    static var selectedChunkMs: Int {
        get {
            let v = UserDefaults.standard.integer(forKey: "nemotronChunkMs")
            return availableChunkMs.contains(v) ? v : chunkMs
        }
        set { UserDefaults.standard.set(newValue, forKey: "nemotronChunkMs") }
    }

    /// This instance's tier — fixed at init, because the tier IS the model: each
    /// one is its own ~640 MB directory with the chunk size baked into the
    /// encoder. Switching tiers means a different backend, not a setting.
    let tierChunkMs: Int

    init(chunkMs: Int = NemotronEngine.selectedChunkMs) {
        self.tierChunkMs = chunkMs
    }

    private let manager = StreamingNemotronMultilingualAsrManager()

    let sampleRate: Double = 16_000

    // MARK: - Where the weights live

    /// FluidAudio's cache ROOT, not this model's directory — it appends the repo
    /// folder name itself. Passing the shared root is correct, and is what keeps
    /// every FluidAudio engine in one place.
    ///
    /// Keeping this distinct from `assetDirectory` matters more than it looks:
    /// one constant used to serve as both, so "delete Nemotron" resolved to the
    /// root and would have taken Qwen, MADLAD and Whisper with it, and "how big
    /// is Nemotron" summed all four.
    static var downloadBase: URL { ModelRegistry.root }

    /// Everything this engine owns — the unit to measure and delete.
    static var assetDirectory: URL {
        downloadBase.appendingPathComponent("nemotron-multilingual", isDirectory: true)
    }

    static func variantDirectory(chunkMs: Int = chunkMs) -> URL {
        assetDirectory.appendingPathComponent("multilingual/\(chunkMs)ms", isDirectory: true)
    }

    static func isDownloaded(chunkMs: Int = chunkMs) -> Bool {
        // Check THIS variant's own marker. The previous version scanned the
        // whole tree for any file named metadata.json — and every .mlmodelc
        // bundle ships one, so three Whisper bundles made this claim Nemotron
        // was installed when it was not.
        FileManager.default.fileExists(
            atPath: variantDirectory(chunkMs: chunkMs).appendingPathComponent("metadata.json").path)
    }

    /// Fetch the weights WITHOUT loading them. The Models page only wants the
    /// bytes on disk; `load` additionally pulls the model into memory, which is
    /// pure cost when the user is pre-downloading.
    static func downloadWeights(chunkMs: Int = chunkMs, progress: @escaping ProgressSink) async throws {
        _ = try await StreamingNemotronMultilingualAsrManager.downloadVariant(
            languageCode: "auto",
            chunkMs: chunkMs,
            to: downloadBase,
            progressHandler: { p in
                progress(DownloadProgress(fraction: p.fractionCompleted, note: String(localized: "Downloading Nemotron…")))
            })
    }

    // MARK: - FluidStreamingEngine

    func load(progress: @escaping @Sendable (String) -> Void) async throws {
        // "auto" is the multilingual variant: one model for every supported
        // language, with the language identified from audio. That removes the
        // per-locale model juggling — and the 5-slot allocation cap — that
        // Apple's engine forces on us.
        if !Self.isDownloaded(chunkMs: tierChunkMs) { progress(String(localized: "Downloading Nemotron model…")) }
        let dir = try await StreamingNemotronMultilingualAsrManager.downloadVariant(
            languageCode: "auto",
            chunkMs: tierChunkMs,
            to: Self.downloadBase,
            progressHandler: { p in
                progress(String(localized: "Downloading Nemotron model… \(Int(p.fractionCompleted * 100))%"))
            })

        progress(String(localized: "Loading Nemotron…"))
        try await manager.loadModels(from: dir)
        // nil = let the model identify the language itself, rather than forcing
        // one. Forcing is available via setLanguage if we ever want it.
        await manager.setLanguage(nil)
        progress(String(localized: "Nemotron ready."))
    }

    func setPartial(_ callback: @escaping @Sendable (String) -> Void) async {
        await manager.setPartialCallback(callback)
    }

    func process(_ samples: [Float]) async throws {
        _ = try await manager.process(samples: samples)
    }

    func finishSession() async -> String? {
        try? await manager.finish()
    }

    func teardown() async {
        await manager.cleanup()
    }

    /// The language the model heard, identified from audio rather than inferred
    /// from the transcript's spelling. Strictly better than the text-based
    /// detector for the case that defeats it: a language whose model emits
    /// almost no text at all.
    func detectedLanguage() async -> String? {
        await manager.detectedLanguage()
    }
}
