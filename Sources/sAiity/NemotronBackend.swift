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

    static let captionTierKey = "nemotronChunkMs"
    /// Dictation's own tier. A separate key on purpose: picking a dictation
    /// profile used to write the caption tier, and because a tier is part of
    /// the engine's identity that posted the engine-changed notification and
    /// rebuilt the live caption backend — so choosing "Fast" for press-to-talk
    /// interrupted captions that were already running.
    static let dictationTierKey = "dictationNemotronChunkMs"

    /// The tier the user selected. Persisted; invalid stored values fall back
    /// to the default rather than crashing a download against a bad URL.
    static var selectedChunkMs: Int {
        get { Self.storedTier(forKey: Self.captionTierKey) ?? chunkMs }
        set { UserDefaults.standard.set(newValue, forKey: Self.captionTierKey) }
    }

    /// A missing preference means the user has not chosen a tier and adaptive
    /// dictation may select among tiers already on disk.
    static var hasExplicitChunkSelection: Bool {
        UserDefaults.standard.object(forKey: Self.captionTierKey) != nil
    }

    /// The tier dictation runs. Its own choice once it has made one; the
    /// caption tier until then, so an installation that never touched a
    /// dictation profile behaves exactly as it did before the two separated.
    static var dictationSelectedChunkMs: Int {
        get { Self.storedTier(forKey: Self.dictationTierKey) ?? selectedChunkMs }
        set {
            guard availableChunkMs.contains(newValue) else { return }
            UserDefaults.standard.set(newValue, forKey: Self.dictationTierKey)
        }
    }

    /// True when dictation's tier is pinned — by its own preference, or because
    /// it is still following a caption tier the user did choose. Only when
    /// neither exists may the adaptive policy pick a tier by itself.
    static var hasExplicitDictationChunkSelection: Bool {
        UserDefaults.standard.object(forKey: Self.dictationTierKey) != nil
            || hasExplicitChunkSelection
    }

    /// A stored tier, or nil when absent or nonsense.
    private static func storedTier(forKey key: String) -> Int? {
        let v = UserDefaults.standard.integer(forKey: key)
        return availableChunkMs.contains(v) ? v : nil
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

    /// FluidAudio writes `metadata.json` while it is still assembling the
    /// variant. It is useful to the runtime, but it is not a completion marker:
    /// treating it as one made a half-fetched Nemotron look ready to Settings.
    static let completionMarker = "saiity-download-complete"
    static let requiredRuntimeFiles = [
        "metadata.json",
        "tokenizer.json",
        "joint.mlmodelc/model.mil",
        "encoder.mlmodelc/model.mil",
        "decoder.mlmodelc/model.mil",
        "decoder_joint.mlmodelc/model.mil",
        "preprocessor.mlmodelc/model.mil",
    ]

    static func completionMarkerURL(chunkMs: Int = chunkMs) -> URL {
        variantDirectory(chunkMs: chunkMs).appendingPathComponent(completionMarker)
    }

    static func hasCompletionMarker(chunkMs: Int = chunkMs) -> Bool {
        FileManager.default.fileExists(atPath: completionMarkerURL(chunkMs: chunkMs).path)
    }

    /// Older complete installs predate our marker. Recognize their full model
    /// shape during migration, while a metadata-only tree remains partial.
    static func hasCompleteRuntimeFiles(chunkMs: Int = chunkMs) -> Bool {
        let directory = variantDirectory(chunkMs: chunkMs)
        return requiredRuntimeFiles.allSatisfy {
            FileManager.default.fileExists(atPath: directory.appendingPathComponent($0).path)
        }
    }

    static func isDownloaded(chunkMs: Int = chunkMs) -> Bool {
        hasCompletionMarker(chunkMs: chunkMs) || hasCompleteRuntimeFiles(chunkMs: chunkMs)
    }

    static func markDownloaded(chunkMs: Int = chunkMs) {
        let marker = completionMarkerURL(chunkMs: chunkMs)
        try? FileManager.default.createDirectory(at: marker.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        try? Data().write(to: marker, options: .atomic)
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
        // `downloadVariant` returns only after its transfer has completed; the
        // marker is written here rather than trusting metadata.json, which is
        // present while the transfer is still running.
        markDownloaded(chunkMs: chunkMs)
    }

    // MARK: - FluidStreamingEngine

    func load(progress: @escaping @Sendable (String) -> Void) async throws {
        // "auto" is the multilingual variant: one model for every supported
        // language, with the language identified from audio. That removes the
        // per-locale model juggling — and the 5-slot allocation cap — that
        // Apple's engine forces on us.
        // Through the coordinator, so a Download pressed on this row in Settings
        // joins the fetch a session start is already doing rather than writing
        // into the same tree behind it.
        let ms = tierChunkMs
        let base = Self.downloadBase
        if !Self.isDownloaded(chunkMs: ms) {
            progress(String(localized: "Downloading Nemotron model…"))
            try await DownloadCoordinator.shared.run(AssetID.nemotron(chunkMs: ms)) {
                _ = try await StreamingNemotronMultilingualAsrManager.downloadVariant(
                    languageCode: "auto", chunkMs: ms, to: base,
                    progressHandler: { p in
                        progress(String(localized: "Downloading Nemotron model… \(Int(p.fractionCompleted * 100))%"))
                    })
            }
        }
        // Resolve the directory once the bytes are certainly there. A second
        // downloadVariant on an installed tree is a no-op lookup.
        let dir = try await StreamingNemotronMultilingualAsrManager.downloadVariant(
            languageCode: "auto", chunkMs: ms, to: base, progressHandler: { _ in })
        // Adopt a complete legacy install (which predates our marker) without
        // forcing another multi-hundred-megabyte download. A genuinely partial
        // FluidAudio tree has no usable model and still follows the download path.
        // This call has completed successfully, so it is safe to adopt the
        // result as the registry's explicit completion marker.
        Self.markDownloaded(chunkMs: ms)

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

    func reset() async {
        await manager.reset()
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
