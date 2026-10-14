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
    @Test("caption evidence uses the production mixed-language and output-script procedure")
    func pql7CaptionTranslationProcedure() async {
        let english = "Please check the invoice before continuing with the meeting today."
        let japanese = "日本語の字幕を確認してください。"
        let engine = TranslationProcedureTests.Engine()
        engine.outputs = ["Please check the Japanese subtitles."]
        let mixed = Observation(started: .now, translator: engine, target: "en")
        mixed.append(.init(text: english + " " + japanese, isFinal: true))
        _ = await mixed.translationMetrics()
        #expect(engine.inputs.map(\.source) == ["ja"])
        #expect(engine.inputs.map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) } == [japanese])
        #expect(mixed.translatedText() == english + " Please check the Japanese subtitles.")

        let traditional = "我們今天需要檢查這張發票並討論會議安排。"
        let variantEngine = TranslationProcedureTests.Engine()
        variantEngine.outputs = [traditional]
        let variant = Observation(started: .now, translator: variantEngine, target: "zh-Hant")
        variant.append(.init(text: "我们今天需要检查这张发票并讨论会议安排。", isFinal: true))
        _ = await variant.translationMetrics()
        #expect(variantEngine.inputs.count == 1)
        #expect(variant.translatedText() == traditional)
    }

    private final class EvidenceTranslator: Translating, Sendable {
        let name = "Synthetic evidence translator"
        let output: String?
        init(output: String?) { self.output = output }
        func prepare(from: String, to: String, progress: @escaping @Sendable (String) -> Void) async throws {}
        func translate(_ text: String, from: String, to: String) async throws -> String? { output }
        func stop() async {}
    }

    @Test("target caption evidence measures first output, final output and post-ASR drain separately")
    func targetLatencyEvidence() async throws {
        let started = ContinuousClock.now.advanced(by: .seconds(-1))
        let observation = Observation(started: started, translator: EvidenceTranslator(output: "Hallo Welt."), target: "de")
        observation.append(.init(text: "Hello world.", isFinal: true))
        let metrics = await observation.translationMetrics()
        let first = try #require(metrics["firstTargetSeconds"] as? Double)
        let final = try #require(metrics["targetFinalSeconds"] as? Double)
        let drain = try #require(metrics["translationDrainSeconds"] as? Double)
        #expect(first >= 1)
        #expect(final >= first)
        #expect(drain >= 0)
        #expect(observation.translatedText() == "Hallo Welt.")
        #expect(observation.snapshot().finalText == "Hello world.")

        let declined = Observation(started: started, translator: EvidenceTranslator(output: nil), target: "de")
        declined.append(.init(text: "Hello world.", isFinal: true))
        let failed = await declined.translationMetrics()
        #expect(failed["firstTargetSeconds"] is NSNull)
        #expect(failed["targetFinalSeconds"] is NSNull)
        #expect(failed["translationSkipped"] as? Int == 1)
    }

    private static func requested(_ name: String) -> Bool {
        let models = ProcessInfo.processInfo.environment["SAIITY_CAPTION_BENCHMARK_MODELS"] ?? "nemotron"
        return models.split(separator: ",").contains(Substring(name))
    }
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
        let expectedTranslations: [String: DictationBenchmarkFixture.TranslationReference]?
        let scoring: [String: String]?
    }

    private struct Snapshot {
        let chunks: [TranscriptChunk]
        let firstVolatileSeconds: Double?
        let firstFinalSeconds: Double?

        var finalText: String {
            chunks.filter { $0.isFinal }.reduce("") { CaptionTextMerger.concatenate($0, $1.text) }
        }
    }

    private final class Observation: @unchecked Sendable {
        private let lock = NSLock()
        private let started: ContinuousClock.Instant
        private var chunks: [TranscriptChunk] = []
        private var firstVolatile: Double?
        private var firstFinal: Double?
        private let translator: (any Translating)?
        private let target: String
        private let gate = TranslationInferenceGate()
        private var translationTasks: [Task<Void, Never>] = []
        private var pendingTranslations = 0
        private var skippedTranslations = 0
        private var translationFailures = 0
        private var translatedLines = 0
        private var gateWaitSeconds = 0.0
        private var translatedOutput: [Int: String] = [:]
        private var firstTarget: Double?
        private var targetFinal: Double?

        init(started: ContinuousClock.Instant, translator: (any Translating)?, target: String) {
            self.started = started
            self.translator = translator
            self.target = target
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
                if chunk.isFinal, let translator {
                    guard pendingTranslations < 4 else { skippedTranslations += 1; return }
                    pendingTranslations += 1
                    let queued = ContinuousClock.now
                    let index = translationTasks.count
                    translationTasks.append(Task { [self] in
                        defer { lock.withLock { pendingTranslations -= 1 } }
                        do {
                            let output = try await gate.run { [self] () async throws -> String? in
                                let wait = Self.seconds(queued.duration(to: .now))
                                lock.withLock { gateWaitSeconds += wait }
                                let source = LanguageDetector.sourceLanguage(in: text) ?? "auto"
                                let spans = CaptionLanguageSpanDetector.analyze(text, fallbackLanguage: source)
                                // Match AppDelegate's committed-caption procedure, including
                                // uncertain/mixed sources and explicit output scripts.
                                let regions: [TranslationRegion] = CaptionLanguageSpanDetector.isMixed(spans)
                                    ? spans.map { .init(text: $0.text, source: $0.language ?? "auto") }
                                    : [.init(text: text, source: spans.first?.language ?? "auto")]
                                return try await TranslationProcedure.translate(regions, to: target, engine: translator)
                            }
                            lock.withLock {
                                if let output, !output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                    translatedLines += 1
                                    translatedOutput[index] = output
                                    let completed = Self.seconds(started.duration(to: .now))
                                    firstTarget = firstTarget ?? completed
                                    targetFinal = completed
                                } else { skippedTranslations += 1 }
                            }
                        } catch { lock.withLock { translationFailures += 1 } }
                    })
                }
            }
        }

        func translationMetrics(drainStarted: ContinuousClock.Instant = .now) async -> [String: Any] {
            let tasks = lock.withLock { translationTasks }
            for task in tasks { await task.value }
            return lock.withLock { ["translatedLines": translatedLines, "translationSkipped": skippedTranslations,
                                    "translationFailures": translationFailures, "translationGateWaitSeconds": gateWaitSeconds,
                                    "firstTargetSeconds": firstTarget ?? NSNull(), "targetFinalSeconds": targetFinal ?? NSNull(),
                                    "translationDrainSeconds": Self.seconds(drainStarted.duration(to: .now))] }
        }

        func snapshot() -> Snapshot {
            lock.withLock {
                Snapshot(chunks: chunks,
                         firstVolatileSeconds: firstVolatile,
                         firstFinalSeconds: firstFinal)
            }
        }

        func translatedText() -> String {
            lock.withLock { translatedOutput.keys.sorted().reduce("") { CaptionTextMerger.concatenate($0, translatedOutput[$1]!) } }
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
                           maxWER: metadata?.maxWER, expectedTranslations: metadata?.expectedTranslations,
                           scoring: metadata?.scoring)
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

    static func audioBufferForDictation(_ samples: ArraySlice<Float>) -> AVAudioPCMBuffer { audioBuffer(samples) }

    private static func durationSeconds(_ duration: Duration) -> Double {
        let components = duration.components
        return Double(components.seconds)
            + Double(components.attoseconds) / 1_000_000_000_000_000_000
    }

    private static func record(_ fields: [String: Any]) throws {
        var fields = fields
        fields["configuration"] = try DictationASRPerformanceTests.benchmarkConfiguration(profile: "captions")
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
                            metrics: MetricsBox,
                            translator: (any Translating)?, target: String) async throws {
        let started = ContinuousClock.now
        let observation = Observation(started: started, translator: translator, target: target)
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
        let translationDrainStarted = ContinuousClock.now

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
            "outputSHA256": DictationASRPerformanceTests.outputHash(snapshot.finalText),
            "finalRegions": snapshot.chunks.filter { $0.isFinal }.count,
            "physicalMemoryBytes": MemoryPolicy.physicalFootprint(),
            "firstVolatileSeconds": snapshot.firstVolatileSeconds ?? NSNull(),
            "firstFinalSeconds": snapshot.firstFinalSeconds ?? NSNull(),
            "finalizationSeconds": finalizationSeconds,
            "elapsedSeconds": durationSeconds(started.duration(to: .now)),
        ]
        let translationMetrics = await observation.translationMetrics(drainStarted: translationDrainStarted)
        fields.merge(translationMetrics, uniquingKeysWith: { _, new in new })
        fields["translationEngine"] = ProcessInfo.processInfo.environment["SAIITY_CAPTION_BENCHMARK_TRANSLATION"] ?? "off"
        if translator != nil {
            let output = observation.translatedText()
            fields["outputSHA256"] = DictationASRPerformanceTests.outputHash(output)
            let language = LanguageDetector.languageCode(in: output, minimumCharacters: 8) ?? "und"
            let languages = CaptionLanguageSpanDetector.analyze(output, fallbackLanguage: language).map { $0.language ?? "und" }
            fields.merge(try DictationASRPerformanceTests.translationFields(reference: fixture.expectedTranslations?[target],
                output: output, target: target, languages: languages), uniquingKeysWith: { _, new in new })
        }
        if translationMetrics["translationFailures"] as? Int != 0 {
            throw BenchmarkError("\(fixture.name): native translation failed")
        }
        if ProcessInfo.processInfo.environment["SAIITY_BENCHMARK_INCLUDE_TEXT"] == "1" {
            fields["text"] = snapshot.finalText
        }
        if let expectedText = fixture.expectedText {
            let score = try DictationASRPerformanceTests.scoreFields(reference: expectedText, hypothesis: snapshot.finalText, scoring: fixture.scoring)
            fields.merge(score, uniquingKeysWith: { _, new in new })
            let wer = score["wer"] as! Double
            if let maxWER = fixture.maxWER, wer > maxWER {
                throw BenchmarkError("\(fixture.name): \(model) WER \(wer) exceeds max \(maxWER)")
            }
        }
        if let expectedLanguages = fixture.expectedLanguages {
            let fallback = LanguageDetector.languageCode(in: snapshot.finalText) ?? "und"
            let spans = CaptionLanguageSpanDetector.analyze(snapshot.finalText,
                                                             fallbackLanguage: fallback)
            let languages = spans.map { $0.language ?? "und" }
            fields["scoredLanguages"] = languages
            fields["languagePreserved"] = DictationBenchmarkScorer.preservesLanguageSequence(
                expected: expectedLanguages, actual: languages)
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

    /// Pace every fixture through one backend and record the result. Shared by
    /// both engines so the two are measured the same way: same fixtures, same
    /// chunking, same WER scorer, same metric set. A comparison where one side
    /// ran with different settings is not a comparison.
    private static func benchmark(model: String,
                                  coldPrepare: @Sendable () async throws -> [String: Any],
                                  inputs: [Fixture],
                                  backend: StreamingASRBackend,
                                  metrics: MetricsBox) async throws {
        let configuration = try DictationASRPerformanceTests.benchmarkConfiguration(profile: "captions")
        let runs = try #require(configuration["runs"] as? Int)
        let target = ProcessInfo.processInfo.environment["SAIITY_CAPTION_BENCHMARK_TARGET"] ?? "de"
        let translator: (any Translating)?
        if ProcessInfo.processInfo.environment["SAIITY_CAPTION_BENCHMARK_TRANSLATION"] == "madlad" {
            MADLADTranslator.metalLibraryRootOverride = URL(fileURLWithPath:
                ProcessInfo.processInfo.environment["SAIITY_BENCHMARK_RESOURCE_ROOT"]
                ?? "\(FileManager.default.currentDirectoryPath)/.build/release/sAiityTests.xctest/Contents/MacOS")
        }
        defer { MADLADTranslator.metalLibraryRootOverride = nil }
        switch ProcessInfo.processInfo.environment["SAIITY_CAPTION_BENCHMARK_TRANSLATION"] ?? "off" {
        case "off": translator = nil
        case "hy-mt2":
            guard HyMT2Translator.isDownloaded else {
                throw BenchmarkError("Installed Hy-MT2 required; downloads disabled")
            }
            translator = HyMT2Translator()
        case "madlad":
            guard MADLADTranslator.isDownloaded(), MADLADTranslator.hasBundledMetalLibrary else {
                throw BenchmarkError("Installed MADLAD and test-bundle Metal resources required; downloads disabled")
            }
            translator = MADLADTranslator()
        default: throw BenchmarkError("Unsupported caption benchmark translation engine")
        }
        if translator != nil {
            for fixture in inputs {
                _ = try DictationASRPerformanceTests.translationFields(reference: fixture.expectedTranslations?[target],
                    output: "", target: target, languages: [])
            }
        }
        do {
            if let translator {
                let start = ContinuousClock.now
                try await translator.prepare(from: "auto", to: target) { _ in }
                try record(["model": model, "phase": "translation_prepare",
                            "seconds": durationSeconds(start.duration(to: .now)),
                            "physicalMemoryBytes": MemoryPolicy.physicalFootprint()])
            }
            let prepareStart = ContinuousClock.now
            try await backend.prepare(locale: Locale(identifier: "auto")) { _ in }
            try record(try await coldPrepare().merging(
                ["model": model,
                 "phase": "cold_prepare",
                 "physicalMemoryBytes": MemoryPolicy.physicalFootprint(),
                 "seconds": durationSeconds(prepareStart.duration(to: .now))],
                uniquingKeysWith: { _, new in new }))
            for fixture in inputs {
                for run in 1...runs {
                    // Qualified: the loop variable `run` shadows the method.
                    try await Self.run(fixture, model: model, run: run,
                                       backend: backend, metrics: metrics, translator: translator, target: target)
                }
            }
        } catch {
            await backend.release()
            await translator?.stop()
            throw error
        }
        await backend.release()
        await translator?.stop()
    }

    @Test("Installed Nemotron live-caption latency and backlog benchmark",
          .enabled(if: requested("nemotron") && !(ProcessInfo.processInfo.environment["SAIITY_CAPTION_BENCHMARK_DIR"] ?? "").isEmpty))
    func installedNemotronBenchmark() async throws {
        let path = try #require(ProcessInfo.processInfo.environment["SAIITY_CAPTION_BENCHMARK_DIR"])
        let inputs = try fixtures(in: URL(fileURLWithPath: path, isDirectory: true))
        let configuration = try DictationASRPerformanceTests.benchmarkConfiguration(profile: "captions")
        let chunkMs = try #require(configuration["chunkMs"] as? Int)
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
        try await Self.benchmark(
            model: model,
            coldPrepare: { ["chunkMs": chunkMs] },
            inputs: inputs,
            backend: StreamingASRBackend(name: "Nemotron \(chunkMs) caption benchmark",
                                         engine: InstalledNemotron(directory: directory),
                                         onMetrics: { metrics.set($0) }),
            metrics: metrics)
    }

    @Test("Installed production Qwen caption adapter",
          .enabled(if: !(ProcessInfo.processInfo.environment["SAIITY_CAPTION_BENCHMARK_DIR"] ?? "").isEmpty
                && (requested("qwen-small") || requested("qwen-large"))))
    func installedQwenBenchmark() async throws {
        let path = try #require(ProcessInfo.processInfo.environment["SAIITY_CAPTION_BENCHMARK_DIR"])
        let inputs = try fixtures(in: URL(fileURLWithPath: path, isDirectory: true))
        let resources = URL(fileURLWithPath: ProcessInfo.processInfo.environment["SAIITY_BENCHMARK_RESOURCE_ROOT"]
            ?? "\(FileManager.default.currentDirectoryPath)/.build/release/sAiityTests.xctest/Contents/MacOS", isDirectory: true)
        for size in [QwenASREngine.Size.small, .large] where Self.requested("qwen-\(size.rawValue)") {
            guard QwenASREngine.isDownloaded(size) else {
                throw BenchmarkError("Missing installed production Qwen \(size.rawValue); downloads are disabled")
            }
            let metrics = MetricsBox()
            try await Self.benchmark(model: "qwen-\(size.rawValue)", coldPrepare: { [:] }, inputs: inputs,
                backend: StreamingASRBackend(name: "Qwen caption benchmark",
                    engine: QwenASREngine(size: size, resourceRoot: resources), onMetrics: { metrics.set($0) }),
                metrics: metrics)
        }
    }

    /// The same run against Whisper large-v3-turbo, so the two engines can be
    /// compared on identical audio.
    ///
    /// This is the measurement the engine exists for. It is a separate opt-in
    /// test rather than a flag on the Nemotron one because the 626 MB weights
    /// are usually not installed, and a benchmark that failed for want of a
    /// model would take the Nemotron numbers down with it.
    ///
    /// Set SAIITY_CAPTION_BENCHMARK_WHISPER=1 alongside the directory.
    @Test("Installed Whisper turbo live-caption benchmark",
          .enabled(if: (requested("whisper") || ProcessInfo.processInfo.environment["SAIITY_CAPTION_BENCHMARK_WHISPER"] == "1")
                   && !(ProcessInfo.processInfo.environment["SAIITY_CAPTION_BENCHMARK_DIR"] ?? "").isEmpty))
    func installedWhisperTurboBenchmark() async throws {
        let path = try #require(ProcessInfo.processInfo.environment["SAIITY_CAPTION_BENCHMARK_DIR"])
        let inputs = try fixtures(in: URL(fileURLWithPath: path, isDirectory: true))
        if !WhisperTurboEngine.isDownloaded() {
            // Never fetched silently: 626 MB is a real download and a benchmark
            // that quietly starts one is a benchmark nobody expects to wait for.
            // Opt in with SAIITY_CAPTION_BENCHMARK_DOWNLOAD=1, which is also
            // how this model gets onto a machine in the first place — the same
            // call the Models page's Download button makes.
            guard ProcessInfo.processInfo.environment["SAIITY_CAPTION_BENCHMARK_DOWNLOAD"] == "1" else {
                throw BenchmarkError("Whisper turbo is not installed at \(WhisperTurboEngine.assetDirectory.path); "
                                     + "set SAIITY_CAPTION_BENCHMARK_DOWNLOAD=1 to fetch it")
            }
            try await WhisperTurboEngine.downloadWeights { progress in
                print("SAIITY_CAPTION_BENCHMARK_DOWNLOAD \(progress.fraction.map { String(format: "%.2f", $0) } ?? "?") \(progress.note)")
            }
        }
        let metrics = MetricsBox()
        try await Self.benchmark(
            model: "whisper-\(WhisperTurboEngine.modelIdentifier)",
            coldPrepare: {
                ["model": WhisperTurboEngine.modelIdentifier,
                 "commitHorizonSeconds": WhisperTurboEngine.commitHorizonSeconds,
                 "leftContextSeconds": WhisperTurboEngine.leftContextSeconds,
                 "stepSeconds": WhisperTurboEngine.stepSeconds]
            },
            inputs: inputs,
            backend: StreamingASRBackend(name: "Whisper turbo caption benchmark",
                                         engine: WhisperTurboEngine(),
                                         onMetrics: { metrics.set($0) }),
            metrics: metrics)
    }
}
