import Foundation
import Testing
import WhisperKit

@testable import sAiity

@Suite struct DictationTranscriptionTests {
    @Test("speech regions prefer a long silence boundary")
    func silenceBoundary() {
        var configuration = SpeechRegionSegmenter.Configuration()
        configuration.silenceDuration = .milliseconds(300)
        configuration.minimumSpeechDuration = .milliseconds(500)
        let segmenter = SpeechRegionSegmenter(configuration: configuration)
        let samples = Array(repeating: Float(0.4), count: 1_000)
            + Array(repeating: Float.zero, count: 400)
            + Array(repeating: Float(0.4), count: 1_000)

        let regions = segmenter.segment(samples, sampleRate: 1_000)

        #expect(regions.count == 2)
        #expect(regions.allSatisfy { !$0.isForced })
        #expect(regions[0].coveredRange.upperBound >= 1_000)
        #expect(regions[0].coveredRange.upperBound <= 1_400)
        #expect(regions[0].audioRange == regions[0].coveredRange)
    }

    @Test("speech segmentation conserves every sample and overlaps only hard cuts")
    func sampleConservationAndHardMaximum() {
        var configuration = SpeechRegionSegmenter.Configuration()
        configuration.silenceDuration = .milliseconds(300)
        configuration.minimumSpeechDuration = .milliseconds(500)
        configuration.maximumRegionDuration = .seconds(10)
        configuration.forcedCutOverlap = .milliseconds(200)
        let segmenter = SpeechRegionSegmenter(configuration: configuration)
        let samples = Array(repeating: Float(0.5), count: 25_000)

        let regions = segmenter.segment(samples, sampleRate: 1_000)

        #expect(regions.count == 3)
        #expect(regions.first?.coveredRange.lowerBound == 0)
        #expect(regions.last?.coveredRange.upperBound == samples.count)
        for pair in zip(regions, regions.dropFirst()) {
            #expect(pair.0.coveredRange.upperBound == pair.1.coveredRange.lowerBound)
        }
        #expect(regions[0].audioRange.count > regions[0].coveredRange.count)
        #expect(regions[0].audioRange.upperBound == regions[1].coveredRange.lowerBound + 200)
        #expect(regions[1].audioRange.upperBound == regions[2].coveredRange.lowerBound + 200)
        #expect(regions.dropLast().allSatisfy { $0.coveredRange.count <= 10_000 })
    }

    @Test("a short tail never makes a forced region exceed the hard maximum")
    func shortTailKeepsHardMaximum() {
        var configuration = SpeechRegionSegmenter.Configuration()
        configuration.minimumSpeechDuration = .seconds(1)
        configuration.maximumRegionDuration = .seconds(10)
        let samples = Array(repeating: Float(0.5), count: 10_500)
        let regions = SpeechRegionSegmenter(configuration: configuration)
            .segment(samples, sampleRate: 1_000)

        #expect(regions.map(\.coveredRange.count) == [10_000, 500])
        #expect(regions.allSatisfy { $0.coveredRange.count <= 10_000 })
        #expect(regions[0].audioRange.upperBound == regions[1].coveredRange.lowerBound + 160)
    }

    @Test("transcript merger removes overlap and applies script-aware spacing")
    func transcriptMerging() {
        #expect(DictationTranscriptMerger.merge(["I don't know.[BLANK_AUDIO]Do you know me?"]) == "I don't know. Do you know me?")
        #expect(DictationTranscriptMerger.merge(["hello [BLANK_AUDIO], world"]) == "hello, world")
        #expect(DictationTranscriptMerger.merge(["[BLANK_AUDIO]"]) == "")
        #expect(DictationTranscriptMerger.merge(["hello world", "world again"]) == "hello world again")
        #expect(DictationTranscriptMerger.merge(["你好", "世界"]) == "你好世界")
        #expect(DictationTranscriptMerger.merge(["你好世界", "世界很好"]) == "你好世界很好")
        #expect(DictationTranscriptMerger.merge(["Hallo", "world"]) == "Hallo world")
        #expect(DictationTranscriptMerger.merge(["你好", "can you check"]) == "你好 can you check")
        #expect(DictationTranscriptMerger.merge(["Ich denke", "we should ship"]) == "Ich denke we should ship")
        #expect(DictationTranscriptMerger.merge(["we should ship", "die Rechnung öffnen"]) == "we should ship die Rechnung öffnen")
        #expect(DictationTranscriptMerger.merge(["Ich denke", "we should ship", "bitte"]) == "Ich denke we should ship bitte")
        #expect(DictationTranscriptMerger.merge(["Can you check", "你好", "then continue"]) == "Can you check 你好 then continue")
    }

    @Test("language metadata retains every region and does not use the first as source")
    func languageMetadataRetainsRegions() {
        let transcription = DictationTranscriptionResult(regions: [
            DictationRegionTranscript(text: "Ich denke", language: "de-DE"),
            DictationRegionTranscript(text: "we should ship this today", language: "en-US"),
            DictationRegionTranscript(text: "bitte", language: "de-DE"),
        ])

        #expect(transcription.languageMetadata.regionLanguages == ["de-DE", "en-US", "de-DE"])
        #expect(transcription.languageMetadata.dominantLanguage == "de-DE")
        #expect(transcription.languageMetadata.containsMultipleLanguages)
    }

    @Test("mixed cleanup preserves spans and rejects a translated collapse")
    func mixedCleanupValidation() {
        let transcription = DictationTranscriptionResult(regions: [
            DictationRegionTranscript(text: "Ich denke", language: "de-DE"),
            DictationRegionTranscript(text: "we should ship this today", language: "en-US"),
        ])
        let preserved = "Ich denke we should ship this today."
        let translated = "Ich denke, wir sollten das heute versenden."

        #expect(DictationCleanupValidator.validate(
            preserved,
            preserving: transcription.text,
            sourceLanguage: transcription.languageMetadata.dominantLanguage,
            languageMetadata: transcription.languageMetadata) == preserved)
        #expect(DictationCleanupValidator.validate(
            translated,
            preserving: transcription.text,
            sourceLanguage: transcription.languageMetadata.dominantLanguage,
            languageMetadata: transcription.languageMetadata) == nil)
    }

    @Test("mixed cleanup prompt explicitly preserves code switching")
    func mixedCleanupPrompt() {
        let metadata = DictationLanguageMetadata(regions: [
            DictationRegionTranscript(text: "Ich denke", language: "de-DE"),
            DictationRegionTranscript(text: "we should ship", language: "en-US"),
        ])
        let prompt = LocalLLMTranslator.cleanupUserPrompt(
            "Ich denke we should ship",
            languageMetadata: metadata).lowercased()

        #expect(prompt.contains("multiple languages"))
        #expect(prompt.contains("preserve the language of every span"))
        #expect(prompt.contains("never translate"))
    }

    @Test("Whisper Auto decodes each region with independent language detection")
    func whisperAutoOptionsPerRegion() async throws {
        final actor Calls {
            var options: [DecodingOptions] = []
            var audio: [[Float]] = []
            var index = 0

            func record(_ samples: [Float], _ option: DecodingOptions) -> Int {
                audio.append(samples)
                options.append(option)
                defer { index += 1 }
                return index
            }
        }

        let calls = Calls()
        let backend = WhisperDictationBackend(
            transcribe: { _, _, _, _ in "unused" },
            segmentTranscribe: { _, _, samples, options in
                let index = await calls.record(samples, options)
                return DictationRegionTranscript(
                    text: index == 0 ? "Ich denke" : "we should ship",
                    language: index == 0 ? "de" : "en")
            })
        let regions = [
            DictationSpeechRegion(audioRange: 0..<2, coveredRange: 0..<2),
            DictationSpeechRegion(audioRange: 2..<4, coveredRange: 2..<4),
        ]

        let result = try await backend.transcribeDictation(
            samples: [1, 2, 3, 4],
            regions: regions,
            locale: Locale(identifier: "auto"))
        let recordedOptions = await calls.options
        let recordedAudio = await calls.audio

        #expect(result.text == "Ich denke we should ship")
        #expect(recordedAudio == [[1, 2], [3, 4]])
        #expect(recordedOptions.count == 2)
        #expect(recordedOptions.allSatisfy { $0.language == nil && $0.detectLanguage })
    }
}
