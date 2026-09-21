import Foundation
import Testing

@testable import sAiity

@Suite struct HardeningTests {
    @Test("translation preflight accepts only a non-empty metallib")
    func metalLibraryPreflight() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("saiity-preflight-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        #expect(!TranslationPreflight.hasBundledMetalLibrary(resourceRoot: root))
        try Data().write(to: root.appendingPathComponent("empty.metallib"))
        #expect(!TranslationPreflight.hasBundledMetalLibrary(resourceRoot: root))
        try Data([0x01]).write(to: root.appendingPathComponent("default.metallib"))
        #expect(TranslationPreflight.hasBundledMetalLibrary(resourceRoot: root))
    }

    @Test("a failed specialist translator falls back once and does not loop")
    func translationRuntimeFallback() {
        var state = TranslationRuntimeFallback()
        #expect(state.resolve(.hyMT2) == .hyMT2)
        state.quarantine(.hyMT2)
        #expect(state.resolve(.hyMT2) == .madlad)
        state.quarantine(.madlad)
        #expect(state.resolve(.hyMT2) == nil)
        #expect(state.resolve(.madlad) == nil)
    }

    @Test("benchmark scorer reports WER and preserves language order")
    func benchmarkScoring() {
        #expect(DictationBenchmarkScorer.wordErrorRate(
            reference: "Ich denke we should ship today",
            hypothesis: "Ich denke we should ship today") == 0)
        #expect(DictationBenchmarkScorer.wordErrorRate(
            reference: "send the report today",
            hypothesis: "send report") > 0)
        #expect(DictationBenchmarkScorer.preservesLanguageSequence(
            expected: ["de-DE", "en-US", "de"],
            actual: ["de", "de-DE", "en", "en-US", "de-DE"]))
        #expect(!DictationBenchmarkScorer.preservesLanguageSequence(
            expected: ["de", "en", "de"], actual: ["en", "de"]))
    }

    @Test("benchmark manifest loads expected text metadata without audio")
    func benchmarkManifest() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("saiity-manifest-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let data = Data(#"{"fixtures":[{"audio":"de.wav","expectedText":"Das ist ein Test.","expectedLanguages":["de"],"maxWER":0.25}]}"#.utf8)
        try data.write(to: root.appendingPathComponent("manifest.json"))

        let manifest = try DictationBenchmarkManifest.load(from: root)
        #expect(manifest["de.wav"]?.expectedText == "Das ist ein Test.")
        #expect(manifest["de.wav"]?.expectedLanguages == ["de"])
        #expect(manifest["de.wav"]?.maxWER == 0.25)
    }
}
