import Foundation
import Testing
import WhisperKit

@testable import sAiity

@Suite struct DictationTranscriptionTests {
    @Test("only immutable speech regions leave a live recording")
    func completedRegionsKeepMergeableTail() {
        let segmenter = SpeechRegionSegmenter.default
        let first = Array(repeating: Float(0.2), count: 16_000)
        let silence = Array(repeating: Float.zero, count: 6_400)
        let shortTail = Array(repeating: Float(0.2), count: 4_000)
        #expect(segmenter.completedRegions(first + silence + shortTail, sampleRate: 16_000).isEmpty)
        let samples = first + silence + Array(repeating: Float(0.2), count: 16_000)
        let complete = segmenter.completedRegions(samples, sampleRate: 16_000)
        #expect(complete.count == 1)
        #expect(complete == Array(segmenter.segment(samples + shortTail, sampleRate: 16_000).prefix(1)))
    }

    @Test("live hard cuts retain all lookahead and a nonmergeable tail")
    func completedHardCutRetainsContext() {
        let segmenter = SpeechRegionSegmenter.default
        let samples = Array(repeating: Float(0.2), count: 160_000 + 11_200)
        #expect(segmenter.completedRegions(Array(samples.prefix(160_001)), sampleRate: 16_000).isEmpty)
        let complete = segmenter.completedRegions(samples, sampleRate: 16_000)
        #expect(complete == [.init(audioRange: 0..<162_560, coveredRange: 0..<160_000, isForced: true)])
        #expect(complete == Array(segmenter.segment(samples + Array(repeating: 0.2, count: 8_000),
                                                   sampleRate: 16_000).prefix(1)))
    }
    @Test("language refinement cannot remove original code-switch paragraph boundaries")
    func pql4RawParagraphs() {
        for text in ["Please check the invoice.\n\n日本語の字幕を確認してください。",
                     "Ich  denke we should ship this today.", "Hello.\n\nHello."] {
            let result = DictationTranscriptionResult(text: text, language: "en")
            #expect(result.text.utf8.elementsEqual(text.utf8))
            #expect(result.languageMetadata.regionTexts.joined().utf8.elementsEqual(text.utf8))
        }
    }

    @Test("PQL2 Japanese text corrects stale tags regardless of first script", arguments: [
        "日本語の字幕を確認してください。", "これは日本語の文章です。",
        "ｶﾀｶﾅの字幕を確認してください。", "Swift APIの結果を3回確認してください。"
    ])
    func pql2JapaneseTag(_ text: String) {
        for hint in [nil, "zh", "zh-Hans", "en"] as [String?] {
            let result = DictationTranscriptionResult(text: text, language: hint)
            #expect(result.text == text)
            #expect(result.regions.map(\.language) == ["ja"])
            #expect(result.translationRuns.map(\.text) == [text])
            #expect(!result.languageMetadata.containsMultipleLanguages)
        }
        let compatible = DictationTranscriptionResult(text: text, language: "ja-JP")
        #expect(compatible.regions.map(\.language) == ["ja-JP"])
    }

    @Test("PQL2 clear Chinese text corrects a stale Japanese tag")
    func pql2ChineseTag() {
        let text = "我们今天需要仔细检查所有发票，然后讨论明天会议的具体安排。"
        let result = DictationTranscriptionResult(text: text, language: "ja")
        #expect(result.text == text)
        #expect(result.regions.map { $0.language.map(TranslationLanguage.baseCode) } == ["zh"])
        #expect(!result.languageMetadata.containsMultipleLanguages)
    }

    @Test("PQL2 unknown Han remains unknown and disjoint Japanese repeats survive")
    func pql2UnknownAndRepeatedRegions() {
        let unknown = DictationTranscriptionResult(text: "字幕", language: "en")
        #expect(unknown.text == "字幕")
        #expect(unknown.regions.map(\.language) == [nil])
        #expect(unknown.languageMetadata.dominantLanguage == nil)
        let repeated = DictationTranscriptionResult(regions: [
            .init(text: "はい、はい。", language: "ja"),
            .init(text: "はい、はい。", language: "ja")
        ])
        #expect(repeated.text == "はい、はい。はい、はい。")
        #expect(repeated.translationRuns.map(\.text) == [repeated.text])
        #expect(!repeated.languageMetadata.containsMultipleLanguages)
    }

    @Test("PQL2 translation runs preserve genuine Chinese Japanese Chinese switches")
    func pql2TranslationSwitches() {
        let chinese = "这是中文，请先检查发票。"
        let japanese = "これは日本語の説明です。"
        let ending = "然后我们继续讨论明天的会议安排。"
        let result = DictationTranscriptionResult(text: chinese + japanese + ending, language: "zh")
        #expect(result.text == chinese + japanese + ending)
        #expect(result.translationRuns.map(\.text) == [chinese, japanese, ending])
        #expect(result.translationRuns.map { $0.language.map(TranslationLanguage.baseCode) } == ["zh", "ja", "zh"])
        #expect(result.languageMetadata.containsMultipleLanguages)
    }

    @Test("an empty overlapped decode cannot deduplicate a disjoint repetition")
    func emptyRegionDoesNotInventOverlap() async throws {
        actor Counter {
            var count = 0
            func next() -> Int { defer { count += 1 }; return count }
        }
        let counter = Counter()
        let backend = WhisperDictationBackend(segmentTranscribe: { _, _, _, _ in
            let index = await counter.next()
            return .init(text: index == 1 ? "" : "Hello world.", language: "en")
        })
        let regions = [
            DictationSpeechRegion(audioRange: 0..<3, coveredRange: 0..<2),
            DictationSpeechRegion(audioRange: 2..<5, coveredRange: 2..<4),
            DictationSpeechRegion(audioRange: 4..<8, coveredRange: 4..<8)
        ]
        let result = try await backend.transcribeDictation(samples: Array(repeating: 0.5, count: 8),
            regions: regions, locale: Locale(identifier: "auto"))
        #expect(result.text == "Hello world. Hello world.")
    }
    @Test("short Latin fillers retain audio tags and Japanese Han-kana is one language")
    func conservativeLanguageEvidence() {
        let english = DictationTranscriptionResult(text: "Um, send the report, I mean the revised report.", language: "en")
        #expect(english.regions.map(\.language) == ["en"])
        let japanese = DictationTranscriptionResult(text: "日本語の字幕を確認してください。", language: "ja")
        #expect(japanese.text == "日本語の字幕を確認してください。")
        #expect(japanese.regions.map(\.language) == ["ja"])
        #expect(!japanese.languageMetadata.containsMultipleLanguages)
        let incompatible = DictationTranscriptionResult(text: "これは日本語の文章です。", language: "en")
        #expect(!incompatible.regions.map(\.language).contains("en"))
    }
    @Test("silence-only capture does not create an ASR region")
    func silenceOnlyCaptureSkipsDecode() {
        let samples = Array(repeating: Float.zero, count: 16_000 * 3)
        #expect(SpeechRegionSegmenter.default.segment(samples, sampleRate: 16_000).isEmpty)
    }

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
        #expect(DictationTranscriptMerger.merge(["hello world", "world again"], removingAudioOverlap: true) == "hello world again")
        #expect(DictationTranscriptMerger.merge(["你好", "世界"]) == "你好世界")
        #expect(DictationTranscriptMerger.merge(["你好世界", "世界很好"], removingAudioOverlap: true) == "你好世界很好")
        #expect(DictationTranscriptMerger.merge(["Very good.", "Very good."]) == "Very good. Very good.")
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

    @Test("obvious mixed-script speech is refined without an extra audio pause")
    func mixedScriptRegionIsRefined() {
        let transcription = DictationTranscriptionResult(regions: [
            .init(text: "你好, can you check das nochmal", language: "zh")
        ])

        #expect(transcription.regions.first?.language == "zh")
        #expect(transcription.regions.dropFirst().allSatisfy { $0.language != "zh" })
        #expect(transcription.text == "你好, can you check das nochmal")
        #expect(transcription.languageMetadata.containsMultipleLanguages)
    }

    @Test("overlap metadata preserves disjoint repetition and unknown languages")
    func overlapMetadataAndUnknownLanguages() {
        let disjoint = DictationTranscriptionResult(regions: [
            .init(text: "Very good.", language: "en"), .init(text: "Very good.", language: "en")])
        #expect(disjoint.text == "Very good. Very good.")
        let overlap = DictationTranscriptionResult(regions: [
            .init(text: "hello world", language: "en"),
            .init(text: "world again", language: "en", overlapsPreviousAudio: true)])
        #expect(overlap.text == "hello world again")
        let tied = DictationLanguageMetadata(regions: [
            .init(text: "Hallo", language: "de"), .init(text: "world", language: "en")])
        #expect(tied.dominantLanguage == nil)
        let scripts = DictationTranscriptionResult(text: "Hallo Привет как ваши дела сегодня", language: "de")
        #expect(scripts.regions.last?.language != "de")
    }

    @Test("translation runs batch only adjacent regions with the same language")
    func translationRunsPreserveSwitches() {
        let transcription = DictationTranscriptionResult(regions: [
            .init(text: "Ich denke", language: "de-DE"),
            .init(text: "bitte", language: "de"),
            .init(text: "we should ship", language: "en-US"),
            .init(text: "today", language: "en"),
            .init(text: "bitte", language: "de-DE"),
        ])

        #expect(transcription.translationRuns.map(\.text) == [
            "Ich denke bitte",
            "we should ship today",
            "bitte",
        ])
        #expect(transcription.translationRuns.map(\.language) == ["de-DE", "en-US", "de-DE"])
    }

    @Test("unknown region language is not replaced by the dominant language")
    func unknownRegionStaysUnknown() {
        let transcription = DictationTranscriptionResult(regions: [
            .init(text: "Ich denke", language: "de-DE"),
            .init(text: "maybe", language: nil),
            .init(text: "bitte", language: "de-DE"),
        ])

        #expect(transcription.translationRuns.map(\.language) == ["de-DE", nil, "de-DE"])
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

@Suite struct SpeechRegionVoiceTests {
    private func region(_ range: Range<Int>) -> DictationSpeechRegion {
        DictationSpeechRegion(audioRange: range, coveredRange: range)
    }

    @Test("a tail of room noise and a click is not sent to the recognizer")
    func noiseTailHasNoSpeech() {
        var samples = (0..<16_000).map { _ in Float.random(in: -0.003...0.003) }
        samples[8_000] = 0.4    // one key click
        samples[8_001] = -0.35
        #expect(!SpeechRegionSegmenter.default.containsSpeech(samples, in: region(0..<16_000), sampleRate: 16_000))
    }

    @Test("a short spoken word is enough")
    func shortWordHasSpeech() {
        var samples = [Float](repeating: 0, count: 16_000)
        for i in 6_000..<10_000 { samples[i] = 0.05 * sin(Float(i) * 0.06) }   // 250 ms
        #expect(SpeechRegionSegmenter.default.containsSpeech(samples, in: region(0..<16_000), sampleRate: 16_000))
    }

    @Test("quiet speech above the noise floor still counts")
    func quietSpeechHasSpeech() {
        let samples = (0..<16_000).map { i in 0.015 * sin(Float(i) * 0.05) }
        #expect(SpeechRegionSegmenter.default.containsSpeech(samples, in: region(0..<16_000), sampleRate: 16_000))
    }

    @Test("a region shorter than the minimum must be voiced throughout")
    func shortRegionNeedsVoiceThroughout() {
        #expect(SpeechRegionSegmenter.default.containsSpeech([0.2, 0.3], in: region(0..<2), sampleRate: 16_000))
        #expect(!SpeechRegionSegmenter.default.containsSpeech([0, 0], in: region(0..<2), sampleRate: 16_000))
    }
}
