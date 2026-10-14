import AVFoundation
import FluidAudio
import Foundation
import CryptoKit
import Testing

@testable import sAiity

/// Opt in with SAIITY_ASR_BENCHMARK_DIR=/absolute/fixtures and filter this suite.
/// Run in a fresh test process for cold model preparation (OS caches may be warm).
/// Reads at most 12 mono Float32 16 kHz WAVs, each at most 60 seconds. No downloads.
@Suite(.serialized)
struct DictationASRPerformanceTests {
    private final class FixtureCapture: DictationAudioCapture {
        var samples: [Float] = []
        var sink: (@Sendable (AVAudioPCMBuffer) -> Void)?
        func start(targetFormat: AVAudioFormat, onBuffer: @escaping @Sendable (AVAudioPCMBuffer) -> Void) throws { sink = onBuffer }
        func stop() { sink = nil }
        func takeCollectedSamples() -> [Float] { samples }
    }

    private final class MemoryPasteboard: DictationPasteboard {
        var text = ""
        func setString(_ value: String) -> Bool { text = value; return true }
    }

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
        let expectedTranslations: [String: DictationBenchmarkFixture.TranslationReference]?
        let scoring: [String: String]?
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
                           maxWER: metadata?.maxWER, expectedTranslations: metadata?.expectedTranslations,
                           scoring: metadata?.scoring)
        }
    }

    private func record(_ fields: [String: Any], since start: ContinuousClock.Instant) throws {
        let duration = start.duration(to: .now).components
        var fields = fields
        let phase = fields["phase"] as? String
        fields["configuration"] = try Self.benchmarkConfiguration(profile:
            phase == "release_to_insertion" || phase == "pipeline_cold_prepare" ? "pipeline" : "asr")
        let seconds = Double(duration.seconds) + Double(duration.attoseconds) / 1e18
        fields["seconds"] = seconds
        fields["physicalMemoryBytes"] = MemoryPolicy.physicalFootprint()
        if let audioSeconds = fields["audioSeconds"] as? Double, audioSeconds > 0 {
            fields["realTimeFactor"] = seconds / audioSeconds
        }
        let data = try JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys])
        print("SAIITY_ASR_BENCHMARK " + String(decoding: data, as: UTF8.self))
    }

    static func benchmarkConfiguration(profile: String, environment env: [String: String] = ProcessInfo.processInfo.environment) throws -> [String: Any] {
        let prefix = profile == "captions" ? "SAIITY_CAPTION_BENCHMARK_" : "SAIITY_DICTATION_BENCHMARK_"
        guard let chunk = Int(profile == "asr" ? "2240" : env[prefix + "CHUNK_MS"] ?? "2240"),
              [1120, 2240].contains(chunk),
              let runs = Int(profile == "captions" ? env[prefix + "RUNS"] ?? "3" : "5"),
              (1...10).contains(runs), ["0", "1"].contains(env[prefix + "REALTIME"] ?? "1") else {
            throw BenchmarkError("Unsupported benchmark tier, runs or realtime setting")
        }
        let cleanup = profile == "pipeline" ? env[prefix + "CLEANUP"] ?? "rules" : "off"
        let translation = profile == "asr" ? "off" : env[prefix + "TRANSLATION"] ?? "off"
        let model = cleanup == "model" ? env[prefix + "CLEANUP_MODEL"] : nil
        let target = translation == "off" ? nil : env[prefix + "TARGET"] ?? "de"
        let validModel = model.map { $0.hasSuffix(".gguf") && URL(fileURLWithPath: $0).lastPathComponent == $0 } ?? false
        guard ["off", "rules", "model"].contains(cleanup), ["off", "hy-mt2", "madlad"].contains(translation),
              cleanup != "model" || validModel,
              target == nil || (!target!.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !["auto", "und", "unknown"].contains(target!)) else {
            throw BenchmarkError("Explicit cleanup model and translation target are required")
        }
        return ["profile": profile, "language": "auto", "chunkMs": chunk, "runs": runs,
                "realtime": profile == "captions" ? (env[prefix + "REALTIME"] != "0") as Any : NSNull(),
                "preview": profile == "pipeline" ? [false, true] as Any : NSNull(),
                "cleanup": cleanup, "cleanupModel": model as Any? ?? NSNull(),
                "translation": translation, "target": target as Any? ?? NSNull()]
    }

    static func outputHash(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    static func scoreFields(reference: String, hypothesis: String, scoring: [String: String]?) throws -> [String: Any] {
        if let scoring {
            guard let language = scoring["language"], !language.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !["auto", "und", "unknown"].contains(TranslationLanguage.baseCode(language)),
                  scoring["wordUnit"] == "natural-language", scoring["normalization"] == "nfc-grapheme-v1" else {
                throw BenchmarkError("Explicit reviewed language/word/grapheme scoring contract is required")
            }
        }
        let language = scoring?["language"]
        var fields: [String: Any] = [
            "wer": DictationBenchmarkScorer.wordErrorRate(reference: reference, hypothesis: hypothesis, language: language),
            "cer": DictationBenchmarkScorer.characterErrorRate(reference: reference, hypothesis: hypothesis),
            "missingWords": DictationBenchmarkScorer.wordErrors(reference: reference, hypothesis: hypothesis, language: language).deletions]
        if let scoring { fields["scoring"] = scoring }
        return fields
    }

    static func translationFields(reference: DictationBenchmarkFixture.TranslationReference?,
                                  output: String, target: String, languages: [String]) throws -> [String: Any] {
        guard let reference, reference.reviewed, !reference.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw BenchmarkError("Explicit reviewed target reference is required")
        }
        if let scoring = reference.scoring, scoring["language"] != target {
            throw BenchmarkError("Reviewed target scoring language differs from requested target")
        }
        let alternatives = reference.alternatives ?? []
        let texts = [reference.text] + alternatives
        guard (reference.alternatives == nil || !alternatives.isEmpty), alternatives.count <= 8,
              Set(texts).count == texts.count,
              texts.allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else {
            throw BenchmarkError("Invalid reviewed reference alternatives")
        }
        let scores = try texts.map { try scoreFields(reference: $0, hypothesis: output, scoring: reference.scoring) }
        let best = scores.min {
            let left = $0["wer"] as! Double, right = $1["wer"] as! Double
            return left == right ? ($0["cer"] as! Double) < ($1["cer"] as! Double) : left < right
        }!
        let targetParts = target.replacingOccurrences(of: "_", with: "-").lowercased().split(separator: "-")
        let script = targetParts.first == "zh" ? targetParts.first(where: { $0 == "hans" || $0 == "hant" }) : nil
        let tagsPreserved = !languages.isEmpty && languages.allSatisfy { language in
            guard TranslationLanguage.isSame(language, as: target) else { return false }
            guard let script else { return true }
            return language.replacingOccurrences(of: "_", with: "-").lowercased().split(separator: "-").contains(script)
        }
        var fields: [String: Any] = ["target": target,
            "translationReferenceSHA256": outputHash(reference.text),
            "translationWER": best["wer"]!, "translationCER": best["cer"]!,
            "translationMissingWords": best["missingWords"]!, "targetLanguagePreserved": tagsPreserved,
            "targetVariantPreserved": TranslationLanguage.satisfiesOutputVariant(in: output, target: target)]
        if reference.alternatives != nil { fields["translationReferencesSHA256"] = outputHash(texts.map(outputHash).joined(separator: "\n")) }
        if let scoring = reference.scoring { fields["translationScoring"] = scoring }
        return fields
    }

    @Test("PQL7 language evidence rejects unexplained extra or unknown spans")
    func pql7ExactLanguageSequence() {
        #expect(DictationBenchmarkScorer.preservesLanguageSequence(expected: ["de", "en"], actual: ["de-DE", "de", "en-US"]))
        for actual in [["fr", "de", "en"], ["de", "fr", "en"], ["de", "en", "fr"], ["de", "und", "en"], ["de", "auto", "en"], ["de", "en", "de"]] {
            #expect(!DictationBenchmarkScorer.preservesLanguageSequence(expected: ["de", "en"], actual: actual))
        }
    }

    @Test("PQL7 scoring preserves canonical graphemes and real word omissions")
    func pql7CanonicalScoring() {
        for (reference, hypothesis) in [("café déjà", "cafe\u{301} de\u{301}ja\u{300}"), ("가 나", "\u{1100}\u{1161} 나"), ("が", "か\u{3099}")] {
            #expect(DictationBenchmarkScorer.wordErrorRate(reference: reference, hypothesis: hypothesis) == 0)
            #expect(DictationBenchmarkScorer.characterErrorRate(reference: reference, hypothesis: hypothesis) == 0)
            #expect(DictationBenchmarkScorer.wordErrors(reference: reference, hypothesis: hypothesis).deletions == 0)
        }
        #expect(DictationBenchmarkScorer.wordErrors(reference: "café très bon", hypothesis: "cafe\u{301} bon").deletions == 1)
        #expect(DictationBenchmarkScorer.characterErrorRate(reference: "कि", hypothesis: "क") == 1)
    }

    @Test("PQL7 script targets require their own outcome")
    func pql7TargetVariant() throws {
        let reference = DictationBenchmarkFixture.TranslationReference(text: "學校", reviewed: true)
        for languages in [["zh"], ["zh-Hans"], ["zh-Hant", "zh-Hans"]] {
            let fields = try Self.translationFields(reference: reference, output: "學校", target: "zh-Hant", languages: languages)
            #expect(fields["targetLanguagePreserved"] as? Bool == false)
        }
        let fields = try Self.translationFields(reference: reference, output: "學校", target: "zh-Hant", languages: ["zh-Hant"])
        #expect(fields["targetLanguagePreserved"] as? Bool == true)
    }

    @Test("PQL7 optional reviewed alternatives survive decoding and score independently")
    func pql7ReviewedAlternatives() throws {
        let data = Data(#"{"text":"Hello world","reviewed":true,"alternatives":["Hi world"]}"#.utf8)
        let reference = try JSONDecoder().decode(DictationBenchmarkFixture.TranslationReference.self, from: data)
        let encoded = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(reference)) as? [String: Any])
        #expect(encoded["alternatives"] as? [String] == ["Hi world"])
        let fields = try Self.translationFields(reference: reference, output: "Hi world", target: "en", languages: ["en"])
        #expect(fields["translationWER"] as? Double == 0)
        #expect(fields["translationCER"] as? Double == 0)
        #expect(fields["translationMissingWords"] as? Int == 0)
        #expect(fields["translationReferenceSHA256"] as? String == SHA256.hash(data: Data("Hello world".utf8)).map { String(format: "%02x", $0) }.joined())
        #expect(fields["translationReferencesSHA256"] is String)
    }

    @Test("PQL7 reviewed Korean contract counts missing words rather than Hangul scalars")
    func pql7ReviewedWordContract() throws {
        let data = Data(#"{"text":"안녕하세요 세계","reviewed":true,"scoring":{"language":"ko","wordUnit":"natural-language","normalization":"nfc-grapheme-v1"}}"#.utf8)
        let reference = try JSONDecoder().decode(DictationBenchmarkFixture.TranslationReference.self, from: data)
        let fields = try Self.translationFields(reference: reference, output: "안녕하세요", target: "ko", languages: ["ko"])
        #expect(fields["translationMissingWords"] as? Int == 1)
        #expect(fields["translationWER"] as? Double == 0.5)
        #expect((fields["translationScoring"] as? [String: String])?["language"] == "ko")
        let encoded = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(reference)) as? [String: Any])
        #expect((encoded["scoring"] as? [String: String])?["normalization"] == "nfc-grapheme-v1")
        let legacy = DictationBenchmarkFixture.TranslationReference(text: "안녕하세요 세계", reviewed: true)
        let old = try Self.translationFields(reference: legacy, output: "안녕하세요", target: "ko", languages: ["ko"])
        #expect(old["translationMissingWords"] as? Int == 2)
        #expect(old["translationScoring"] == nil)
    }

    @Test("reviewed target scoring is separate from source recognition")
    func reviewedTargetScoring() throws {
        let reference = DictationBenchmarkFixture.TranslationReference(text: "Hello world", reviewed: true)
        let fields = try Self.translationFields(reference: reference, output: "Hello world", target: "en", languages: ["en-US"])
        #expect(fields["translationWER"] as? Double == 0)
        #expect(fields["translationMissingWords"] as? Int == 0)
        #expect(fields["targetLanguagePreserved"] as? Bool == true)
        #expect(fields["wer"] == nil)
        #expect(fields["translationReferenceSHA256"] as? String == SHA256.hash(data: Data(reference.text.utf8)).map { String(format: "%02x", $0) }.joined())
        let wrongLanguage = try Self.translationFields(reference: reference, output: "Hello world", target: "de", languages: ["en"])
        #expect(wrongLanguage["targetLanguagePreserved"] as? Bool == false)
        #expect(throws: BenchmarkError.self) {
            try Self.translationFields(reference: nil, output: "Hello world", target: "en", languages: ["en"])
        }
        #expect(throws: BenchmarkError.self) {
            try Self.translationFields(reference: .init(text: "Hello world", reviewed: false), output: "Hello world", target: "en", languages: ["en"])
        }
    }

    @Test("optional reviewed translation references decode without altering source metadata")
    func reviewedTargetManifest() throws {
        let data = Data(#"{"audio":"fixture.wav","expectedText":"Hallo Welt","expectedLanguages":["de"],"expectedTranslations":{"en":{"text":"Hello world","reviewed":true}}}"#.utf8)
        let fixture = try JSONDecoder().decode(DictationBenchmarkFixture.self, from: data)
        #expect(fixture.expectedText == "Hallo Welt")
        #expect(fixture.expectedLanguages == ["de"])
        #expect(fixture.expectedTranslations?["en"]?.reviewed == true)
        let legacy = try JSONDecoder().decode(DictationBenchmarkFixture.self, from: Data(#"{"audio":"fixture.wav"}"#.utf8))
        #expect(legacy.expectedTranslations == nil)
    }

    @Test("canonical benchmark configuration preserves tier and installed processing selection")
    func benchmarkConfigurationFields() throws {
        let pipeline = try Self.benchmarkConfiguration(profile: "pipeline", environment: [
            "SAIITY_DICTATION_BENCHMARK_CHUNK_MS": "1120", "SAIITY_DICTATION_BENCHMARK_CLEANUP": "model",
            "SAIITY_DICTATION_BENCHMARK_CLEANUP_MODEL": "gemma-3-1b-it-Q4_K_M.gguf",
            "SAIITY_DICTATION_BENCHMARK_TRANSLATION": "hy-mt2", "SAIITY_DICTATION_BENCHMARK_TARGET": "en"])
        #expect(pipeline["chunkMs"] as? Int == 1120)
        #expect(pipeline["preview"] as? [Bool] == [false, true])
        #expect(pipeline["cleanupModel"] as? String == "gemma-3-1b-it-Q4_K_M.gguf")
        #expect(pipeline["target"] as? String == "en")
        let caption = try Self.benchmarkConfiguration(profile: "captions", environment: [:])
        #expect(caption["chunkMs"] as? Int == 2240)
        #expect(caption["runs"] as? Int == 3)
        #expect(caption["realtime"] as? Bool == true)
        #expect(caption["cleanupModel"] is NSNull)
        #expect(caption["target"] is NSNull)
        #expect(throws: BenchmarkError.self) {
            try Self.benchmarkConfiguration(profile: "captions", environment: ["SAIITY_CAPTION_BENCHMARK_RUNS": "11"])
        }
        #expect(throws: BenchmarkError.self) {
            try Self.benchmarkConfiguration(profile: "pipeline", environment: ["SAIITY_DICTATION_BENCHMARK_CLEANUP": "model"])
        }
    }

    private func measure(_ model: String, fixtures: [Fixture],
                         decode: (Fixture) async throws -> DictationTranscriptionResult) async throws {
        for fixture in fixtures {
            for run in 1...5 {
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
                    "outputSHA256": Self.outputHash(result.text),
                ]
                if let expectedText = fixture.expectedText {
                    let score = try Self.scoreFields(reference: expectedText, hypothesis: result.text, scoring: fixture.scoring)
                    fields.merge(score, uniquingKeysWith: { _, new in new })
                    let wer = score["wer"] as! Double
                    if let maxWER = fixture.maxWER, wer > maxWER {
                        throw BenchmarkError("\(fixture.name): \(model) WER \(wer) exceeds max \(maxWER)")
                    }
                }
                if let expectedLanguages = fixture.expectedLanguages {
                    // Match caption matrix: judge language from the transcript
                    // text. Engines that omit or partially tag regions (Nemotron
                    // English / trailing unknown) still have to keep languages
                    // in the words they emitted.
                    let fallback = LanguageDetector.languageCode(in: result.text,
                                                                  minimumCharacters: 8) ?? "und"
                    let actual = CaptionLanguageSpanDetector.analyze(result.text,
                                                                      fallbackLanguage: fallback)
                        .map { $0.language ?? "und" }
                    fields["scoredLanguages"] = actual
                    fields["languagePreserved"] = DictationBenchmarkScorer.preservesLanguageSequence(
                        expected: expectedLanguages, actual: actual)
                }
                try record(fields, since: start)
            }
        }
    }

    /// Real controller, segmentation, cleanup, translation and insertion; fixture
    /// PCM replaces the microphone and a memory pasteboard protects user data.
    @Test("complete installed dictation pipeline with both preview states",
          .enabled(if: ProcessInfo.processInfo.environment["SAIITY_DICTATION_PIPELINE_BENCHMARK"] == "1"))
    @MainActor func completePipeline() async throws {
        let path = try #require(ProcessInfo.processInfo.environment["SAIITY_ASR_BENCHMARK_DIR"])
        let inputs = try fixtures(in: URL(fileURLWithPath: path, isDirectory: true))
        let configuration = try Self.benchmarkConfiguration(profile: "pipeline")
        let chunkMs = try #require(configuration["chunkMs"] as? Int)
        let asrModel = "nemotron-\(chunkMs)"
        try #require(NemotronEngine.isDownloaded(chunkMs: chunkMs), "Installed Nemotron required; downloads disabled")
        let cleanupMode = ProcessInfo.processInfo.environment["SAIITY_DICTATION_BENCHMARK_CLEANUP"] ?? "rules"
        try #require(["off", "rules", "model"].contains(cleanupMode))
        let model = cleanupMode == "model" ? LocalModel.all.first {
            $0.file == ProcessInfo.processInfo.environment["SAIITY_DICTATION_BENCHMARK_CLEANUP_MODEL"]
        } : nil
        if cleanupMode == "model" { try #require(model?.isCleanupCompatible() == true, "Installed compatible cleanup model required; downloads disabled") }
        let translationMode = ProcessInfo.processInfo.environment["SAIITY_DICTATION_BENCHMARK_TRANSLATION"] ?? "off"
        if translationMode == "madlad" {
            MADLADTranslator.metalLibraryRootOverride = URL(fileURLWithPath:
                "\(FileManager.default.currentDirectoryPath)/.build/release/sAiityTests.xctest/Contents/MacOS")
        }
        defer { MADLADTranslator.metalLibraryRootOverride = nil }
        let translator: (any Translating)?
        switch translationMode {
        case "off": translator = nil
        case "hy-mt2":
            try #require(HyMT2Translator.isDownloaded, "Installed Hy-MT2 required; downloads disabled")
            translator = HyMT2Translator()
        case "madlad":
            try #require(MADLADTranslator.isDownloaded() && MADLADTranslator.hasBundledMetalLibrary,
                         "Installed MADLAD and native test Metal resources required; downloads disabled")
            translator = MADLADTranslator()
        default: throw BenchmarkError("Unsupported dictation translation engine")
        }
        let target = ProcessInfo.processInfo.environment["SAIITY_DICTATION_BENCHMARK_TARGET"] ?? "de"
        if translator != nil {
            for fixture in inputs {
                _ = try Self.translationFields(reference: fixture.expectedTranslations?[target], output: "", target: target, languages: [])
            }
        }
        let gate = TranslationInferenceGate()
        let cleanup = DictationCleanupSession(gate: gate)
        var translatorPrepared = false
        let pool = ASRBackendPool(makeBackend: {
            StreamingASRBackend(name: "Pipeline Nemotron", engine: InstalledNemotron(directory: NemotronEngine.variantDirectory(chunkMs: chunkMs)))
        }, idleEvictionDelay: .seconds(3_600))
        let cold = ContinuousClock.now
        try await pool.prepare(locale: Locale(identifier: "auto")) { _ in }
        try record(["model": asrModel, "phase": "pipeline_cold_prepare"], since: cold)
        for preview in [false, true] {
            let capture = FixtureCapture()
            let pasteboard = MemoryPasteboard()
            let inserter = TextInserter(pasteboard: pasteboard, accessibilityTrusted: { false })
            var timings: [String: Double] = [:]
            var snapshot: DictationResultSnapshot?
            var cleanupResult: DictationTranscriptionResult?
            let controller = DictationController(backendProvider: pool, capture: capture, inserter: inserter,
                captionsActive: { false },
                translationConfiguration: { .init(enabled: translator != nil, target: target) },
                detailedTranslate: { _, result, target in
                    guard let translator else { return nil }
                    return try? await gate.run { @MainActor in
                        if !translatorPrepared {
                            await cleanup.releaseModel()
                            try await translator.prepare(from: "auto", to: target) { _ in }
                            translatorPrepared = true
                        }
                        var translated: [String] = []
                        for region in result.translationRuns {
                            if TranslationProcedure.isAlreadyInTarget(region.text, target: target) {
                                translated.append(region.text)
                            } else {
                                guard let output = try await translator.translate(region.text,
                                    from: region.language ?? "auto", to: target) else { return nil }
                                translated.append(output)
                            }
                        }
                        return DictationTranscriptMerger.merge(translated)
                    }
                },
                cleanupConfiguration: { .init(enabled: cleanupMode != "off") },
                detailedCleanup: { input in
                    let result = await cleanup.cleanup(input, modelKey: model?.file) {
                        await translator?.stop()
                        translatorPrepared = false
                        let local = LocalLLMTranslator()
                        try await local.prepare(model: model, from: "auto", to: "auto") { _ in }
                        return .init(cleanup: { await local.cleanup($0, sourceLanguage: $1, languageMetadata: $2) },
                                     cleanupRegions: { await local.cleanupRegions($0) }, stop: { await local.stop() })
                    }
                    cleanupResult = result
                    return result
                }, onResult: { snapshot = $0 }, dictationStreamingDraftEnabled: { preview },
                onTiming: { operation, seconds, _ in timings[operation] = seconds })
            for fixture in inputs {
                for run in 1...5 {
                    capture.samples = fixture.samples
                    pasteboard.text = ""
                    snapshot = nil
                    cleanupResult = nil
                    timings.removeAll()
                    controller.press()
                    await controller.waitForWorkForTests()
                    // Pace capture for the preview path, matching microphone callbacks.
                    for offset in stride(from: 0, to: fixture.samples.count, by: 3_200) {
                        let end = min(offset + 3_200, fixture.samples.count)
                        capture.sink?(CaptionASRPerformanceTests.audioBufferForDictation(fixture.samples[offset..<end]))
                        if preview { try await Task.sleep(for: .milliseconds(200)) }
                    }
                    let released = ContinuousClock.now
                    controller.release()
                    await controller.waitForWorkForTests()
                    try #require(!pasteboard.text.isEmpty, "No inserted dictation result")
                    if translator != nil { #expect(snapshot?.wasTranslated == true, "Translation silently fell back") }
                    if cleanupMode != "off" { #expect(snapshot?.cleanupUnavailable == false, "Cleanup was unavailable") }
                    let result = try #require(snapshot)
                    var fields: [String: Any] = ["model": asrModel, "phase": "release_to_insertion",
                        "fixture": fixture.name, "preview": preview, "run": run,
                        "cleanup": cleanupMode, "translation": translationMode, "timings": timings,
                        "outputChars": pasteboard.text.count, "outputSHA256": Self.outputHash(pasteboard.text), "wasTranslated": result.wasTranslated,
                        "cleanupUnavailable": result.cleanupUnavailable]
                    if cleanupMode != "off" {
                        let outcome = try #require(cleanupResult, "Cleanup outcome was not measured")
                        fields["modelCalls"] = outcome.modelCalls
                        fields["modelAccepted"] = outcome.modelAccepted
                        fields["modelFallbacks"] = outcome.modelFallbacks
                        fields["rulesSkipped"] = outcome.rulesSkipped
                    }
                    // Score the authoritative recognizer snapshot, before cleanup/translation.
                    if let expected = fixture.expectedText {
                        let score = try Self.scoreFields(reference: expected, hypothesis: result.rawText, scoring: fixture.scoring)
                        fields.merge(score, uniquingKeysWith: { _, new in new })
                        let wer = score["wer"] as! Double
                        if translator == nil {
                            let outputScore = try Self.scoreFields(reference: expected, hypothesis: pasteboard.text, scoring: fixture.scoring)
                            fields["outputWER"] = outputScore["wer"]
                            fields["outputCER"] = outputScore["cer"]
                            fields["outputMissingWords"] = outputScore["missingWords"]
                        }
                        if let maximum = fixture.maxWER { #expect(wer <= maximum) }
                    }
                    if let expected = fixture.expectedLanguages {
                        let hypothesis = result.rawText
                        let fallback = LanguageDetector.languageCode(in: hypothesis,
                                                                      minimumCharacters: 8) ?? "und"
                        let actual = CaptionLanguageSpanDetector.analyze(hypothesis,
                                                                          fallbackLanguage: fallback)
                            .map { $0.language ?? "und" }
                        fields["scoredLanguages"] = actual
                        fields["languagePreserved"] = DictationBenchmarkScorer.preservesLanguageSequence(
                            expected: expected, actual: actual)
                        if translator == nil {
                            let outputFallback = LanguageDetector.languageCode(in: pasteboard.text, minimumCharacters: 8) ?? "und"
                            let outputLanguages = CaptionLanguageSpanDetector.analyze(pasteboard.text, fallbackLanguage: outputFallback).map { $0.language ?? "und" }
                            fields["scoredOutputLanguages"] = outputLanguages
                            fields["outputLanguagePreserved"] = DictationBenchmarkScorer.preservesLanguageSequence(expected: expected, actual: outputLanguages)
                        }
                    }
                    if translator != nil {
                        let outputFallback = LanguageDetector.languageCode(in: pasteboard.text, minimumCharacters: 8) ?? "und"
                        let outputLanguages = CaptionLanguageSpanDetector.analyze(pasteboard.text, fallbackLanguage: outputFallback).map { $0.language ?? "und" }
                        fields.merge(try Self.translationFields(reference: fixture.expectedTranslations?[target],
                            output: pasteboard.text, target: target,
                            languages: result.languageMetadata?.regionLanguages.map { $0 ?? "und" } ?? []), uniquingKeysWith: { _, new in new })
                        fields["targetLanguagePreserved"] = (fields["targetLanguagePreserved"] as? Bool == true)
                            && !outputLanguages.isEmpty && outputLanguages.allSatisfy { TranslationLanguage.isSame($0, as: target) }
                        fields["translationFailures"] = result.wasTranslated ? 0 : 1
                        fields["translationSkipped"] = result.wasTranslated ? 0 : 1
                    }
                    try record(fields, since: released)
                }
            }
        }
        await pool.invalidate()
        await cleanup.invalidate()
        await translator?.stop()
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
                        let decoded = try await loaded.transcribe(samples, options: options)
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
