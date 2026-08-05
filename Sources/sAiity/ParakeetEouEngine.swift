import AVFoundation
import FluidAudio
import Foundation

/// Parakeet EOU 120M — the fast, English-only streaming recogniser.
///
/// A fifth of Nemotron's parameters, so noticeably quicker to the first word,
/// at the cost of every language except English. Note the DOWNLOAD is 437 MB,
/// not the "120 MB" the model's name suggests: the repo ships both the
/// `.mlpackage` sources and the compiled `.mlmodelc`. Measured, not quoted.
///
/// It also detects end-of-utterance itself, which is a better sentence boundary
/// than our silence heuristic — see `setPartial`.
final class ParakeetEouEngine: FluidStreamingEngine, @unchecked Sendable {
    /// 320 ms: the middle tier. 160 ms is lower latency for more compute per
    /// second of audio; 1280 ms is the reverse.
    private static let chunk: StreamingChunkSize = .ms320

    /// `Repo.parakeetEou320.folderName` is `parakeet-eou-streaming/320ms` — the
    /// tiers are siblings under one family directory, and the name bears no
    /// relation to the remote repo path. Verified against a real download; a
    /// plausible-looking guess here silently produces a row that never shows a
    /// size and never offers Delete.
    static let tier = "320ms"

    /// `loadModels(to:)` takes the models ROOT and appends the folder itself.
    /// Note this is the opposite convention from `AsrModels.download(to:)`,
    /// which wants the repo directory.
    static var downloadBase: URL { ModelRegistry.root }

    /// The whole family, so deleting also reclaims any other tier that was
    /// tried. Only 320 ms is offered today.
    static var assetDirectory: URL {
        downloadBase.appendingPathComponent("parakeet-eou-streaming", isDirectory: true)
    }

    /// All three compiled models plus the vocabulary, per
    /// `ModelNames.ParakeetEOU.requiredModels`, relative to `assetDirectory`.
    static let markers = ["\(tier)/streaming_encoder.mlmodelc", "\(tier)/decoder.mlmodelc",
                          "\(tier)/joint_decision.mlmodelc", "\(tier)/vocab.json"]

    static func isDownloaded() -> Bool {
        markers.allSatisfy {
            FileManager.default.fileExists(atPath: assetDirectory.appendingPathComponent($0).path)
        }
    }

    static func downloadWeights(progress: @escaping ProgressSink) async throws {
        // FluidAudio has no download-only entry point for EOU: loading is what
        // fetches. Load it, then drop it — still cheaper than the alternative of
        // making the user discover the download by starting captions.
        let m = StreamingEouAsrManager(chunkSize: chunk)
        try await m.loadModels(to: downloadBase, progressHandler: { p in
            progress(DownloadProgress(fraction: p.fractionCompleted, note: "Downloading Parakeet EOU…"))
        })
        await m.cleanup()
    }

    private let manager = StreamingEouAsrManager(chunkSize: chunk)
    let sampleRate: Double = 16_000

    func load(progress: @escaping @Sendable (String) -> Void) async throws {
        if !Self.isDownloaded() { progress("Downloading Parakeet EOU…") }
        try await manager.loadModels(to: Self.downloadBase, progressHandler: { p in
            progress("Downloading Parakeet EOU… \(Int(p.fractionCompleted * 100))%")
        })
        progress("Parakeet ready.")
    }

    func setPartial(_ callback: @escaping @Sendable (String) -> Void) async {
        await manager.setPartialCallback(callback)
        // The model's own end-of-utterance signal, debounced at 1280 ms. Re-emit
        // the transcript so the shared committer treats it as a boundary — this
        // is a better sentence break than waiting for punctuation the model may
        // never produce.
        await manager.setEouCallback { text in callback(text) }
    }

    func process(_ samples: [Float]) async throws {
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                         sampleRate: sampleRate, channels: 1, interleaved: false),
              let buffer = AVAudioPCMBuffer(pcmFormat: format,
                                            frameCapacity: AVAudioFrameCount(samples.count)),
              let dst = buffer.floatChannelData else { return }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { src in
            dst[0].update(from: src.baseAddress!, count: samples.count)
        }
        try await manager.appendAudio(buffer)
        try await manager.processBufferedAudio()
    }

    func finishSession() async -> String? {
        try? await manager.finish()
    }

    func teardown() async {
        await manager.cleanup()
    }
}
