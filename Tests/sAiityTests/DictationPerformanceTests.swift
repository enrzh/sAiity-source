import Foundation
import Testing

@testable import sAiity

/// Opt-in real-weight comparison. Normal tests never load/download a model.
/// SAIITY_CLEANUP_BENCHMARK=1 swift test ... --filter DictationPerformanceTests
@Suite(.serialized) @MainActor struct DictationPerformanceTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["SAIITY_CLEANUP_BENCHMARK"] == "1"))
    func compareCleanup() async throws {
        let fixtures: [DictationTranscriptionResult] = [
            .init(text: "Um, please please send the report today.", language: "en"),
            .init(text: "Ähm, bitte sende den Bericht heute.", language: "de"),
            .init(text: "Send the report, I mean the revised report.", language: "en"),
            .init(text: "Schicke den Bericht morgen, nein, am Freitag.", language: "de"),
            .init(regions: [.init(text: "Ich denke", language: "de"),
                            .init(text: "we should ship this today.", language: "en")]),
            .init(text: "你好，this is an English sentence，然后我们继续。", language: "zh")
        ]
        for model in LocalModel.builtIn {
            if !model.isDownloaded {
                try await LocalLLMTranslator.download(model) { _ in }
            }
            let session = DictationCleanupSession(gate: TranslationInferenceGate())
            for mode in ["before", "after"] {
                for round in 0..<3 {
                    for (index, fixture) in fixtures.enumerated() {
                        let start = ContinuousClock.now
                        let result: DictationTranscriptionResult?
                        if mode == "before" {
                            let original = LocalLLMTranslator()
                            try await original.prepare(model: model, from: "auto", to: "auto") { _ in }
                            var regions: [DictationRegionTranscript] = []
                            for region in fixture.regions {
                                let text = await original.cleanup(region.text, sourceLanguage: region.language,
                                    languageMetadata: .init(regions: [region])) ?? region.text
                                regions.append(.init(text: text, language: region.language))
                            }
                            await original.stop()
                            result = .init(regions: regions)
                        } else {
                            result = await session.cleanup(fixture, modelKey: model.file) {
                                let translator = LocalLLMTranslator()
                                try await translator.prepare(model: model, from: "auto", to: "auto") { _ in }
                                return .init(cleanup: { text, source, metadata in
                                    await translator.cleanup(text, sourceLanguage: source, languageMetadata: metadata)
                                }, stop: { await translator.stop() })
                            }
                        }
                        print("CLEANUP_BENCH model=\(model.file) mode=\(mode) round=\(round) fixture=\(index) seconds=\(seconds(start)) outputChars=\(result?.text.count ?? 0) memory=\(MemoryPolicy.describeFootprint())")
                        #expect(result != nil)
                        #expect(result?.languageMetadata.regionLanguages == fixture.languageMetadata.regionLanguages)
                    }
                }
            }
            await session.invalidate()
        }
    }

    private func seconds(_ start: ContinuousClock.Instant) -> Double {
        let elapsed = start.duration(to: .now).components
        return Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18
    }
}
