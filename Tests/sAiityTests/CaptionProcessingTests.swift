import Foundation
import Testing

@testable import sAiity

@Suite("Caption processing")
struct CaptionProcessingTests {
    @Test("language spans preserve every original separator and Unicode character")
    func pql4RawSpanPreservation() {
        for text in ["Hello.\n\nHello.", "Ich  denke we should ship this today.",
                     "\n\tPlease check the invoice.\n日本語の字幕を確認してください。  ",
                     "مرحبا.\n\nHello.\t", "e\u{301}.\n𠮷野家。"] {
            let spans = CaptionLanguageSpanDetector.analyze(text)
            #expect(spans.map(\.text).joined().utf8.elementsEqual(text.utf8))
        }
    }

    @Test("PQL2 Japanese scripts and borrowed identifiers stay in one phrase", arguments: [
        "日本語の字幕を確認してください。", "明日の会議は東京で行います。",
        "これは日本語の文章です。", "カタカナと漢字を確認します。",
        "ｶﾀｶﾅの字幕を確認してください。", "Swift APIの結果を3回確認してください。",
        "はい、はい。確認してください。"
    ])
    func pql2JapanesePhrase(_ text: String) {
        let spans = CaptionLanguageSpanDetector.analyze(text, fallbackLanguage: "zh")
        #expect(spans.map(\.text) == [text])
        #expect(spans.map(\.language) == ["ja"])
        #expect(!CaptionLanguageSpanDetector.isMixed(spans))
    }

    @Test("PQL2 Korean Han belongs to its Korean phrase")
    func pql2KoreanHan() {
        let text = "韓國의 회의 내용을 오늘 확인해 주세요."
        let spans = CaptionLanguageSpanDetector.analyze(text, fallbackLanguage: "zh")
        #expect(spans.map(\.text) == [text])
        #expect(spans.map(\.language) == ["ko"])
        #expect(!CaptionLanguageSpanDetector.isMixed(spans))
    }

    @Test("PQL2 ambiguous Han has no invented language", arguments: ["字幕", "東京"])
    func pql2AmbiguousHan(_ text: String) {
        for hint in [nil, "en"] as [String?] {
            let spans = CaptionLanguageSpanDetector.analyze(text, fallbackLanguage: hint)
            #expect(spans.map(\.text) == [text])
            #expect(spans.map(\.language) == [nil])
        }
        for hint in ["ja-JP", "zh-Hans", "zh-Hant"] {
            let spans = CaptionLanguageSpanDetector.analyze(text, fallbackLanguage: hint)
            #expect(spans.map(\.text) == [text])
            #expect(spans.map(\.language) == [hint])
        }
    }

    @Test("PQL2 shared scripts alone cannot assign Russian Arabic or Hindi",
          arguments: ["Ж", "م", "क", "א", "ก", "க", "ক"])
    func pql2SharedScriptIsNotLanguage(_ text: String) {
        let spans = CaptionLanguageSpanDetector.analyze(text)
        #expect(spans.map(\.text) == [text])
        #expect(spans.map(\.language) == [nil])
    }

    @Test("PQL2 genuine Chinese Japanese clauses retain all source characters")
    func pql2ChineseJapaneseSwitch() {
        let chinese = "这是中文，请先检查发票。"
        let japanese = "これは日本語の説明です。"
        let ending = "然后我们继续讨论明天的会议安排。"
        let spans = CaptionLanguageSpanDetector.analyze(chinese + japanese + ending,
                                                      fallbackLanguage: "zh")
        #expect(spans.map(\.text) == [chinese, japanese, ending])
        #expect(spans.map { $0.language.map(TranslationLanguage.baseCode) } == ["zh", "ja", "zh"])
        #expect(CaptionLanguageSpanDetector.isMixed(spans))
    }

    @Test("PQL2 an uncertain unpunctuated Chinese Japanese boundary stays whole")
    func pql2UncertainAsianBoundary() {
        let text = "这是中文请先检查发票これは日本語の説明です"
        let spans = CaptionLanguageSpanDetector.analyze(text, fallbackLanguage: "zh")
        #expect(spans.map(\.text) == [text])
        #expect(spans.map(\.language) == [nil])
    }

    @Test("PQL2 genuine English Japanese clauses preserve whitespace and repetition")
    func pql2EnglishJapaneseSwitch() {
        let text = "Please check the invoice. 日本語の字幕を確認してください。 Then continue the meeting."
        let spans = CaptionLanguageSpanDetector.analyze(text, fallbackLanguage: "en")
        #expect(spans.map(\.text).joined() == text)
        #expect(spans.map { $0.language.map(TranslationLanguage.baseCode) } == ["en", "ja", "en"])
        #expect(CaptionLanguageSpanDetector.isMixed(spans))
    }

    @Test("PQL2 joining preserves complete Unicode graphemes and disjoint repetition")
    func pql2UnicodeJoining() {
        #expect(CaptionTextMerger.concatenate("はい、", "はい。") == "はい、はい。")
        #expect(CaptionTextMerger.concatenate("e\u{301}", "e\u{301}") == "e\u{301} e\u{301}")
        #expect(CaptionTextMerger.concatenate("👩🏽‍💻", "👩🏽‍💻") == "👩🏽‍💻 👩🏽‍💻")
        #expect(CaptionTextMerger.concatenate("𠮷", "野家") == "𠮷野家")
    }

    @Test("Latin clauses receive one boundary space")
    func latinSpacing() {
        #expect(CaptionTextMerger.join(["Hallo", "world"]) == "Hallo world")
    }

    @Test("CJK clauses do not receive an invented space")
    func cjkSpacing() {
        #expect(CaptionTextMerger.join(["你好", "世界"]) == "你好世界")
    }

    @Test("Mixed script boundaries stay readable without duplicating punctuation")
    func mixedScriptJoining() {
        #expect(CaptionTextMerger.join(["Hallo", "world", "你好", "世界"]) == "Hallo world 你好世界")
        #expect(CaptionTextMerger.join(["hello world", "world again"]) == "hello world again")
        #expect(CaptionTextMerger.join(["你好", "can you"]) == "你好 can you")
    }

    @Test("Mixed Latin language spans are detected without a dominant-language overwrite")
    func mixedLatinLanguageSpans() {
        let spans = CaptionLanguageSpanDetector.analyze(
            "Ich denke we should ship this today.",
            fallbackLanguage: "de")

        #expect(CaptionLanguageSpanDetector.isMixed(spans))
        #expect(spans.map(\.language) == ["de", "en"])
        #expect(spans.map(\.text) == ["Ich denke ", "we should ship this today."])
        #expect(spans.map(\.text).joined() == "Ich denke we should ship this today.")
    }

    @Test("Short mixed Latin spans retain their language metadata")
    func shortLatinSpansKeepLanguage() {
        let spans = CaptionLanguageSpanDetector.analyze(
            "Can you send mir bitte die Rechnung?",
            fallbackLanguage: "en")

        #expect(spans.map(\.language) == ["en", "de"])
    }

    @Test("A boundary late in a long sentence is still found")
    func longSentenceBoundaryIsFound() {
        // `splitLatin` now checks the 8-character minimum against precomputed
        // offsets before building a candidate string, and stops at a
        // near-certain boundary. Both changes are invisible unless a boundary
        // that sits well past the first few words is still detected — which is
        // exactly the arithmetic the offsets replaced.
        let spans = CaptionLanguageSpanDetector.analyze(
            "We were discussing the roadmap for a while and then "
            + "wollten wir das Budget verdoppeln",
            fallbackLanguage: "en")

        #expect(CaptionLanguageSpanDetector.isMixed(spans))
        #expect(spans.last?.language == "de")
        #expect(spans.last?.text.contains("Budget") == true)
        // Nothing is dropped in the process.
        #expect(spans.map(\.text).joined(separator: " ")
            .contains("roadmap for a while"))
    }

    @Test("A single-language sentence is not split by a passing non-Latin word")
    func singleLanguageSentenceStaysWhole() {
        // The early exit must not fire on a confident pair of halves that are
        // both the same language.
        let spans = CaptionLanguageSpanDetector.analyze(
            "This is an ordinary English sentence with no other language in it",
            fallbackLanguage: "en")

        #expect(!CaptionLanguageSpanDetector.isMixed(spans))
    }

    @Test("Mixed script spans retain a readable boundary")
    func mixedScriptLanguageSpans() {
        let spans = CaptionLanguageSpanDetector.analyze(
            "你好，can you check das nochmal",
            fallbackLanguage: "de")

        #expect(CaptionLanguageSpanDetector.isMixed(spans))
        #expect(spans.first?.language == "zh")
        #expect(spans.map(\.text).joined().contains("can you check"))
    }

    @Test("Caption timing uses the audio clock without inventing word precision")
    func captionTiming() {
        let first = CaptionTiming.range(for: "hello", audioEnd: 2, previousEnd: 0)
        #expect(first.end == 2)
        #expect(first.start > 0)

        let second = CaptionTiming.range(for: "world", audioEnd: 1.5, previousEnd: 2)
        #expect(second.start == 1.5)
        #expect(second.end == 1.5)
    }

    @Test("Cumulative punctuation becomes final and leaves a volatile tail")
    func cumulativePunctuation() {
        let start = Date(timeIntervalSince1970: 100)
        var reconciler = CaptionTranscriptReconciler(now: start)

        let first = reconciler.update(cumulativeText: "Ich denke we should", now: start)
        #expect(first.finalText == nil)
        #expect(first.volatileText == "Ich denke we should")

        let second = reconciler.update(cumulativeText: "Ich denke we should ship.",
                                       now: start.addingTimeInterval(1))
        #expect(second.finalText == "Ich denke we should ship.")
        #expect(second.volatileText == nil)
    }

    @Test("A shorter cumulative callback cannot replay a committed prefix")
    func staleShorterCallbackIsIgnored() {
        let start = Date(timeIntervalSince1970: 100)
        var reconciler = CaptionTranscriptReconciler(now: start)
        _ = reconciler.update(cumulativeText: "This sentence is complete.", now: start)

        let stale = reconciler.update(cumulativeText: "This sentence", now: start.addingTimeInterval(1))
        #expect(stale == .none)
        #expect(reconciler.committedText == "This sentence is complete.")
    }

    @Test("The volatile tail can be corrected without changing settled text")
    func volatileCorrection() {
        let start = Date(timeIntervalSince1970: 100)
        var reconciler = CaptionTranscriptReconciler(now: start)
        _ = reconciler.update(cumulativeText: "Please open the calender", now: start)

        let corrected = reconciler.update(cumulativeText: "Please open the calendar", now: start.addingTimeInterval(0.2))
        #expect(corrected.finalText == nil)
        #expect(corrected.volatileText == "Please open the calendar")
    }

    @Test("Repeated stable partials can finalize an unpunctuated clause")
    func stablePartialsFinalize() {
        let start = Date(timeIntervalSince1970: 100)
        var reconciler = CaptionTranscriptReconciler(now: start)
        let text = "This is a long unpunctuated caption clause"
        _ = reconciler.update(cumulativeText: text, now: start)
        _ = reconciler.update(cumulativeText: text, now: start.addingTimeInterval(0.5))
        let result = reconciler.update(cumulativeText: text, now: start.addingTimeInterval(1))
        #expect(result.finalText != nil)
        #expect(result.finalText?.hasPrefix("This is") == true)
    }

    @Test("Speech activity uses onset hysteresis, pre-roll, and a single gap")
    func activityBoundariesAndConservation() {
        var configuration = SpeechActivityDetector.Configuration()
        configuration.minimumSpeechMs = 100
        configuration.preRollMs = 200
        configuration.postRollMs = 300
        configuration.holdMs = 300
        var detector = SpeechActivityDetector(configuration: configuration)
        var events: [SpeechActivityEvent] = []
        let rate: Float = 1_000

        for _ in 0..<5 { if let event = detector.process(rms: 0.001, frames: 100, sampleRate: rate) { events.append(event) } }
        for _ in 0..<2 { if let event = detector.process(rms: 0.05, frames: 100, sampleRate: rate) { events.append(event) } }
        for _ in 0..<4 { if let event = detector.process(rms: 0.001, frames: 100, sampleRate: rate) { events.append(event) } }

        #expect(detector.observedSampleCount == 1_100)
        #expect(events.count == 2)
        guard events.count == 2 else { return }
        if case .speechStarted(let range) = events[0] {
            #expect(range.lowerBound < 500, "pre-roll should include audio before onset")
        } else {
            Issue.record("expected speech onset")
        }
        if case .gap = events[1] {
            // expected
        } else {
            Issue.record("expected one speech gap")
        }
    }

    @Test("Endpoint policy combines punctuation, age, and stable partials")
    func endpointEvidence() {
        #expect(CaptionEndpointPolicy.decide(text: "Hallo.", age: 0,
                                             repeatedPartials: 1,
                                             hasSentenceTerminator: true,
                                             maximumAge: 3.5,
                                             minimumCharacters: 28,
                                             maximumCharacters: 110) == .finalize)
        #expect(CaptionEndpointPolicy.decide(text: "short", age: 10,
                                             repeatedPartials: 4,
                                             hasSentenceTerminator: false,
                                             maximumAge: 3.5,
                                             minimumCharacters: 28,
                                             maximumCharacters: 110) == .wait)
        #expect(CaptionEndpointPolicy.decide(text: "This is a sufficiently long stable caption",
                                             age: 1,
                                             repeatedPartials: 3,
                                             hasSentenceTerminator: false,
                                             maximumAge: 3.5,
                                             minimumCharacters: 28,
                                             maximumCharacters: 110) == .finalize)
    }
}
