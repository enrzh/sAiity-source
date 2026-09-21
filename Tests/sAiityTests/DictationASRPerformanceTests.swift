import AVFoundation
import FluidAudio
import Foundation
import Testing

@testable import sAiity

/// Opt in with SAIITY_ASR_BENCHMARK_DIR=/absolute/fixtures and filter this suite.
/// Run in a fresh test process for cold model preparation (OS caches may be warm).
/// Reads at most 12 mono Float32 16 kHz WAVs, each at most 60 seconds. No downloads.
@Suite(.serialized)
struct DictationASRPerformanceTests {
    private struct BenchmarkError: Error, CustomStringConvertible {
        let description: String
        init(_ description: String) { self.description = description }
    }

    private struct Fixture {
        let name: String
        let samples: [Float]
        let regions: [DictationSpeechRegion]
        let expectedText: String?
        let expectedLanguages: [String]?
        let maxWER: Double?
    }

    /// The app's Nemotron loader also offers downloads. This adapter uses only
    /// the same manager's local loader, with the app's streaming/segmentation code.
    private final class InstalledNemotron: FluidStreamingEngine, @unchecked Sendable {
        let sampleRate = 16_000.0
        let directory: URL
        let manager = StreamingNemotronMultilingualAsrManager()

        init(directory: URL) { self.directory = directory }
        func load(progress: @escaping @Sendable (String) -> Void) async throws {
            try await manager.loadModels(from: directory)
            await manager.setLanguage(nil)
        }
        func reset() async { await manager.reset() }
        func setPartial(_ callback: @escaping @Sendable (String) -> Void) async {
            await manager.setPartialCallback(callback)
        }
        func process(_ samples: [Float]) async throws { _ = try await manager.process(samples: samples) }
        func finishSession() async -> String? { try? await manager.finish() }
        func teardown() async { await manager.cleanup() }
        func detectedLanguage() async -> String? { await manager.detectedLanguage() }
    }

    private func fixtures(in directory: URL) throws -> [Fixture] {
        let manifest = try DictationBenchmarkManifest.load(from: directory)
        let urls = try FileManager.default.contentsOfDirectory(at: directory,
            includingPropertiesForKeys: nil).filter { $0.pathExtension.lowercased() == "wav" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        guard (1...12).contains(urls.count) else {
            throw BenchmarkError("Expected 1...12 WAV fixtures in \(directory.path)")
        }
        return try urls.map { url in
            let file = try AVAudioFile(forReading: url)
            guard file.fileFormat.sampleRate == 16_000,
                  file.fileFormat.channelCount == 1,
                  file.fileFormat.commonFormat == .pcmFormatFloat32,
                  file.length > 0, file.length <= 16_000 * 60 else {
                throw BenchmarkError("\(url.lastPathComponent): expected mono Float32 16 kHz WAV, 0 < duration <= 60s")
            }
            guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                                                frameCapacity: AVAudioFrameCount(file.length)) else {
                throw BenchmarkError("Cannot allocate PCM buffer for \(url.lastPathComponent)")
            }
            try file.read(into: buffer)
            guard buffer.frameLength > 0, let channel = buffer.floatChannelData?[0] else {
                throw BenchmarkError("No Float32 PCM in \(url.lastPathComponent)")
            }
            let samples = Array(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
            guard samples.allSatisfy({ $0.isFinite }) else {
                throw BenchmarkError("Non-finite samples in \(url.lastPathComponent)")
            }
            let metadata = manifest[url.lastPathComponent]
            return Fixture(name: url.lastPathComponent, samples: samples,
                           regions: SpeechRegionSegmenter.default.segment(samples, sampleRate: 16_000),
                           expectedText: metadata?.expectedText,
                           expectedLanguages: metadata?.expectedLanguages,
                           maxWER: metadata?.maxWER)
        }
    }

    private func record(_ fields: [String: Any], since start: ContinuousClock.Instant) throws {
        let duration = start.duration(to: .now).components
        var fields = fields
        let seconds = Double(duration.seconds) + Double(duration.attoseconds) / 1e18
        fields["seconds"] = seconds
        if let audioSeconds = fields["audioSeconds"] as? Double, audioSeconds > 0 {
            fields["realTimeFactor"] = seconds / audioSeconds
        }
        let data = try JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys])
        print("SAIITY_ASR_BENCHMARK " + String(decoding: data, as: UTF8.self))
    }

    private func measure(_ model: String, fixtures: [Fixture],
                         decode: (Fixture) async throws -> DictationTranscriptionResult) async throws {
        for fixture in fixtures {
            for run in 1...3 {
                try Task.checkCancellation()
                let start = ContinuousClock.now
                let result = try await decode(fixture)
                let audioSeconds = Double(fixture.samples.count) / 16_000
                var fields: [String: Any] = [
                    "model": model,
                    "phase": "warm_segmented_decode",
                    "fixture": fixture.name,
                    "run": run,
                    "audioSeconds": audioSeconds,
                    "inputRegions": fixture.regions.count,
                    "outputChars": result.text.count,
                    "languages": result.languageMetadata.regionLanguages.map { $0 ?? "unknown" },
                    "outputRegions": result.regions.count,
                ]
                if let expectedText = fixture.expectedText {
                    let wer = DictationBenchmarkScorer.wordErrorRate(reference: expectedText,
                                                                      hypothesis: result.text)
                    fields["wer"] = wer
                    if let maxWER = fixture.maxWER, wer > maxWER {
                        throw BenchmarkError("\(fixture.name): \(model) WER \(wer) exceeds max \(maxWER)")
                    }
                }
                if let expectedLanguages = fixture.expectedLanguages {
                    fields["languagePreserved"] = DictationBenchmarkScorer.preservesLanguageSequence(
                        expected: expectedLanguages,
                        actual: result.languageMetadata.regionLanguages.compactMap { $0 })
                }
                try record(fields, since: start)
            }
        }
    }

    @Test("Installed Nemotron 2240 versus Whisper base, three sequential decodes per fixture",
          .enabled(if: !(ProcessInfo.processInfo.environment["SAIITY_ASR_BENCHMARK_DIR"] ?? "").isEmpty))
    func installedModelsBenchmark() async throws {
        let path = try #require(ProcessInfo.processInfo.environment["SAIITY_ASR_BENCHMARK_DIR"])
        let inputs = try fixtures(in: URL(fileURLWithPath: path, isDirectory: true))
        let nemotronDirectory = NemotronEngine.variantDirectory(chunkMs: 2240)
        let required = ["metadata.json", "tokenizer.json", "encoder.mlmodelc", "decoder.mlmodelc",
                        "joint.mlmodelc", "preprocessor.mlmodelc"]
        for name in required {
            guard FileManager.default.fileExists(atPath: nemotronDirectory.appendingPathComponent(name).path) else {
                throw BenchmarkError("Missing installed Nemotron 2240 asset: \(name)")
            }
        }
        guard WhisperDictationBackend.isReady(.base) else {
            throw BenchmarkError("Installed Whisper base assets/readiness marker are missing; downloads are disabled")
        }

        let nemotron = StreamingASRBackend(name: "Nemotron 2240 benchmark",
            engine: InstalledNemotron(directory: nemotronDirectory))
        do {
            let start = ContinuousClock.now
            try await nemotron.prepare(locale: Locale(identifier: "auto")) { _ in }
            try record(["model": "nemotron-2240", "phase": "cold_prepare"], since: start)
            try await measure("nemotron-2240", fixtures: inputs) { fixture in
                try await nemotron.transcribeDictation(samples: fixture.samples, regions: fixture.regions)
            }
        } catch {
            await nemotron.release()
            throw error
        }
        await nemotron.release() // stop and unload before Whisper allocates its models.

        // A private benchmark cache reuses the production loader and its existing
        // invalidate/unload hook, without touching the app's private global cache.
        let key = WhisperModelCacheKey(identifier: WhisperDictationBackend.ModelChoice.base.identifier,
            folderPath: WhisperDictationBackend.modelFolder(for: .base).path)
        let cache = WhisperModelCache<WhisperModelCacheKey, LoadedWhisperDictationModel> { key in
            try await LoadedWhisperDictationModel(identifier: key.identifier,
                                                  folder: URL(fileURLWithPath: key.folderPath))
        }
        do {
            let start = ContinuousClock.now
            try await cache.withModel(for: key) { _ in () }
            try record(["model": "whisper-base", "phase": "cold_prepare"], since: start)
            // Hold one cache lease for the entire benchmark, preventing idle
            // eviction from silently turning a later decode into a cold run.
            try await cache.withModel(for: key) { loaded in
                let whisper = WhisperDictationBackend(
                    download: { _, _, _ in throw BenchmarkError("Downloads disabled in benchmark") },
                    segmentTranscribe: { _, _, samples, options in
                        let decoded = await loaded.transcribe(samples, options: options)
                        return .init(text: decoded.text, language: decoded.language)
                    })
                try await measure("whisper-base", fixtures: inputs) { fixture in
                    try await whisper.transcribeDictation(samples: fixture.samples, regions: fixture.regions,
                                                         locale: Locale(identifier: "auto"), model: .base)
                }
            }
        } catch {
            await cache.invalidate(key)
            throw error
        }
        await cache.invalidate(key)
    }
}
