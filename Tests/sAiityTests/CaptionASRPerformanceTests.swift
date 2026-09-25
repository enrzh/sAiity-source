import AVFoundation
import FluidAudio
import Foundation
import Testing

@testable import sAiity

/// Opt in with SAIITY_CAPTION_BENCHMARK_DIR=/absolute/fixtures and filter this
/// suite. Audio is paced at real time by default so first-text latency and
/// backlog describe the live caption path, not a burst-decoding stress test.
@Suite(.serialized)
struct CaptionASRPerformanceTests {
    private struct BenchmarkError: Error, CustomStringConvertible {
        let description: String
        init(_ description: String) { self.description = description }
    }

    private struct Fixture {
        let name: String
        let samples: [Float]
        let expectedText: String?
        let expectedLanguages: [String]?
        let maxWER: Double?
    }

    private struct Snapshot {
        let chunks: [TranscriptChunk]
        let firstVolatileSeconds: Double?
        let firstFinalSeconds: Double?

        var finalText: String {
            CaptionTextMerger.join(chunks.filter { $0.isFinal }.map(\.text))
        }
    }

    private final class Observation: @unchecked Sendable {
        private let lock = NSLock()
        private let started: ContinuousClock.Instant
        private var chunks: [TranscriptChunk] = []
        private var firstVolatile: Double?
        private var firstFinal: Double?

        init(started: ContinuousClock.Instant) {
            self.started = started
        }

        func append(_ chunk: TranscriptChunk) {
            let text = chunk.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return }
            let seconds = Self.seconds(started.duration(to: .now))
            lock.withLock {
                chunks.append(chunk)
                if chunk.isFinal {
                    firstFinal = firstFinal ?? seconds
                } else {
                    firstVolatile = firstVolatile ?? seconds
                }
            }
        }

        func snapshot() -> Snapshot {
            lock.withLock {
                Snapshot(chunks: chunks,
                         firstVolatileSeconds: firstVolatile,
                         firstFinalSeconds: firstFinal)
            }
        }

        private static func seconds(_ duration: Duration) -> Double {
            let components = duration.components
            return Double(components.seconds)
                + Double(components.attoseconds) / 1_000_000_000_000_000_000
        }
    }

    private final class MetricsBox: @unchecked Sendable {
        private let lock = NSLock()
        private var value: StreamingASRMetrics?

        func reset() {
            lock.withLock { value = nil }
        }

        func set(_ metrics: StreamingASRMetrics) {
            lock.withLock { value = metrics }
        }

        func snapshot() -> StreamingASRMetrics? {
            lock.withLock { value }
        }
    }

    /// Uses the production FluidAudio manager directly, but only after the
    /// fixture harness has verified that the requested model is already local.
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

        func process(_ samples: [Float]) async throws {
            _ = try await manager.process(samples: samples)
        }

        func finishSession() async -> String? { try? await manager.finish() }
        func teardown() async { await manager.cleanup() }
        func detectedLanguage() async -> String? { await manager.detectedLanguage() }
    }

    private func fixtures(in directory: URL) throws -> [Fixture] {
        let manifest = try DictationBenchmarkManifest.load(from: directory)
        let urls = try FileManager.default.contentsOfDirectory(at: directory,
            includingPropertiesForKeys: nil)
            .filter { $0.pathExtension.lowercased() == "wav" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        guard (1...12).contains(urls.count) else {
            throw BenchmarkError("Expected 1...12 WAV fixtures in \(directory.path)")
        }

        return try urls.map { url in
            let file = try AVAudioFile(forReading: url)
            guard file.fileFormat.sampleRate == 16_000,
                  file.fileFormat.channelCount == 1,
                  file.fileFormat.commonFormat == .pcmFormatFloat32,
                  file.length > 0,
                  file.length <= 16_000 * 60 else {
                throw BenchmarkError("\(url.lastPathComponent): expected mono Float32 16 kHz WAV, 0 < duration <= 60s")
            }
            guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                                                frameCapacity: AVAudioFrameCount(file.length)) else {
                throw BenchmarkError("Cannot allocate PCM buffer for \(url.lastPathComponent)")
            }
            try file.read(into: buffer)
            guard buffer.frameLength > 0,
                  let channel = buffer.floatChannelData?[0] else {
                throw BenchmarkError("No Float32 PCM in \(url.lastPathComponent)")
            }
            let samples = Array(UnsafeBufferPointer(start: channel,
                                                     count: Int(buffer.frameLength)))
            guard samples.allSatisfy(\.isFinite) else {
                throw BenchmarkError("Non-finite samples in \(url.lastPathComponent)")
            }
            let metadata = manifest[url.lastPathComponent]
            return Fixture(name: url.lastPathComponent,
                           samples: samples,
                           expectedText: metadata?.expectedText,
                           expectedLanguages: metadata?.expectedLanguages,
                           maxWER: metadata?.maxWER)
        }
    }

    private static func audioBuffer(_ samples: ArraySlice<Float>) -> AVAudioPCMBuffer {
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                   sampleRate: 16_000,
                                   channels: 1,
                                   interleaved: false)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format,
                                      frameCapacity: AVAudioFrameCount(samples.count))!
        buffer.frameLength = AVAudioFrameCount(samples.count)
        for (index, sample) in samples.enumerated() {
            buffer.floatChannelData![0][index] = sample
        }
        return buffer
    }

    private static func durationSeconds(_ duration: Duration) -> Double {
        let components = duration.components
        return Double(components.seconds)
            + Double(components.attoseconds) / 1_000_000_000_000_000_000
    }

    private static func record(_ fields: [String: Any]) throws {
        let data = try JSONSerialization.data(withJSONObject: fields,
                                               options: [.sortedKeys])
        print("SAIITY_CAPTION_BENCHMARK " + String(decoding: data, as: UTF8.self))
    }

    private static func stream(_ samples: [Float],
                               to backend: StreamingASRBackend) async throws {
        let chunkSamples = 3_200 // 200 ms of the 16 kHz capture format.
        let paced = ProcessInfo.processInfo.environment["SAIITY_CAPTION_BENCHMARK_REALTIME"] != "0"
        var offset = 0
        while offset < samples.count {
            try Task.checkCancellation()
            let end = min(offset + chunkSamples, samples.count)
            backend.feed(audioBuffer(samples[offset..<end]))
            offset = end
            if paced, offset < samples.count {
                try await Task.sleep(nanoseconds: 200_000_000)
            }
        }
    }

    private static func run(_ fixture: Fixture,
                            model: String,
                            run: Int,
                            backend: StreamingASRBackend,
                            metrics: MetricsBox) async throws {
        let started = ContinuousClock.now
        let observation = Observation(started: started)
        metrics.reset()
        try await backend.start { observation.append($0) }
        do {
            try await stream(fixture.samples, to: backend)
        } catch {
            await backend.stop()
            throw error
        }
        let stopStarted = ContinuousClock.now
        await backend.stop()
        let finalizationSeconds = durationSeconds(stopStarted.duration(to: .now))

        let snapshot = observation.snapshot()
        guard !snapshot.finalText.isEmpty else {
            throw BenchmarkError("\(fixture.name): \(model) emitted no final caption")
        }

        var fields: [String: Any] = [
            "model": model,
            "phase": "warm_live_stream",
            "fixture": fixture.name,
            "run": run,
            "audioSeconds": Double(fixture.samples.count) / 16_000,
            "outputChars": snapshot.finalText.count,
            "finalRegions": snapshot.chunks.filter { $0.isFinal }.count,
            "firstVolatileSeconds": snapshot.firstVolatileSeconds ?? NSNull(),
            "firstFinalSeconds": snapshot.firstFinalSeconds ?? NSNull(),
            "finalizationSeconds": finalizationSeconds,
            "elapsedSeconds": durationSeconds(started.duration(to: .now)),
        ]
        if let expectedText = fixture.expectedText {
            let wer = DictationBenchmarkScorer.wordErrorRate(reference: expectedText,
                                                              hypothesis: snapshot.finalText)
            fields["wer"] = wer
            if let maxWER = fixture.maxWER, wer > maxWER {
                throw BenchmarkError("\(fixture.name): \(model) WER \(wer) exceeds max \(maxWER)")
            }
        }
        if let expectedLanguages = fixture.expectedLanguages {
            let fallback = LanguageDetector.languageCode(in: snapshot.finalText) ?? "und"
            let spans = CaptionLanguageSpanDetector.analyze(snapshot.finalText,
                                                             fallbackLanguage: fallback)
            fields["languagePreserved"] = DictationBenchmarkScorer.preservesLanguageSequence(
                expected: expectedLanguages,
                actual: spans.compactMap(\.language))
        }
        if let asrMetrics = metrics.snapshot() {
            fields["realTimeFactor"] = asrMetrics.realTimeFactor
            fields["peakBacklogSeconds"] = asrMetrics.peakBacklogSeconds
            fields["droppedAudioSeconds"] = asrMetrics.droppedAudioSeconds
            fields["processedBatchCount"] = asrMetrics.processedBatchCount
            fields["overloadEvents"] = asrMetrics.overloadEvents
        } else {
            fields["realTimeFactor"] = NSNull()
            fields["peakBacklogSeconds"] = NSNull()
            fields["droppedAudioSeconds"] = NSNull()
            fields["processedBatchCount"] = NSNull()
            fields["overloadEvents"] = NSNull()
        }
        try record(fields)
    }

    @Test("Installed Nemotron live-caption latency and backlog benchmark",
          .enabled(if: !(ProcessInfo.processInfo.environment["SAIITY_CAPTION_BENCHMARK_DIR"] ?? "").isEmpty))
    func installedNemotronBenchmark() async throws {
        let path = try #require(ProcessInfo.processInfo.environment["SAIITY_CAPTION_BENCHMARK_DIR"])
        let inputs = try fixtures(in: URL(fileURLWithPath: path, isDirectory: true))
        let chunkMs = Int(ProcessInfo.processInfo.environment["SAIITY_CAPTION_BENCHMARK_CHUNK_MS"]
            ?? "\(NemotronEngine.chunkMs)") ?? NemotronEngine.chunkMs
        guard NemotronEngine.availableChunkMs.contains(chunkMs) else {
            throw BenchmarkError("Unsupported Nemotron chunk tier: \(chunkMs)")
        }
        let directory = NemotronEngine.variantDirectory(chunkMs: chunkMs)
        let required = ["metadata.json", "tokenizer.json", "encoder.mlmodelc", "decoder.mlmodelc",
                        "joint.mlmodelc", "preprocessor.mlmodelc"]
        for name in required {
            guard FileManager.default.fileExists(atPath: directory.appendingPathComponent(name).path) else {
                throw BenchmarkError("Missing installed Nemotron \(chunkMs) asset: \(name)")
            }
        }

        let model = "nemotron-\(chunkMs)"
        let metrics = MetricsBox()
        let engine = InstalledNemotron(directory: directory)
        let backend = StreamingASRBackend(name: "Nemotron \(chunkMs) caption benchmark",
                                           engine: engine,
                                           onMetrics: { metrics.set($0) })
        do {
            let prepareStart = ContinuousClock.now
            try await backend.prepare(locale: Locale(identifier: "auto")) { _ in }
            try Self.record(["model": model,
                             "phase": "cold_prepare",
                             "chunkMs": chunkMs,
                             "seconds": Self.durationSeconds(prepareStart.duration(to: .now))])
            let configuredRuns = Int(ProcessInfo.processInfo.environment["SAIITY_CAPTION_BENCHMARK_RUNS"]
                ?? "3") ?? 3
            let runs = min(max(configuredRuns, 1), 10)
            for fixture in inputs {
                for run in 1...runs {
                    try await Self.run(fixture,
                                       model: model,
                                       run: run,
                                       backend: backend,
                                       metrics: metrics)
                }
            }
        } catch {
            await backend.release()
            throw error
        }
        await backend.release()
    }
}
