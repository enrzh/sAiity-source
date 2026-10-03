import Foundation
import Testing

@testable import sAiity

/// The recogniser commits a clause every few seconds so that continuous speech
/// still produces captions. Shown one at a time those clauses replace each
/// other, so a sentence arrives as a series of two-word flashes — and each
/// fragment is translated without the rest of its sentence.
///
/// Measured before this was fixed: speaking "Untertitel für alles, was der Mac
/// abspielt" left `Mac abspielt` on screen, translated as `Mac plays.`
@MainActor
struct SentenceAssemblyTests {
    @Test("cross-chunk dictionary corrections are applied once and survive timed subtitle export")
    func correctedSentenceExport() throws {
        let old = DictationVocabulary.corrections
        defer { DictationVocabulary.corrections = old }
        DictationVocabulary.corrections = [
            .init(heard: "Ube Eats", replacement: "Uber Eats"),
            .init(heard: "Uber Eats", replacement: "Another company")
        ]
        let app = AppDelegate()
        app.openSentenceForTests(["Please call Ube", "Eats today."], words: [
            .init(start: 0, end: 0.5, text: "Please call Ube "),
            .init(start: 0.5, end: 1, text: "Eats today.")
        ])
        #expect(AppDelegate.joinClauses(app.pendingSentenceForTests) == "Please call Uber Eats today.")
        app.closeSentenceForTests()
        let saved = try #require(app.sessionLinesForTests.first)
        #expect(saved.text == "Please call Uber Eats today.")
        #expect(saved.words == nil)
        #expect(Export.srt([saved]).contains("Uber Eats"))
        #expect(!Export.srt([saved]).contains("Another company"))
    }

    @Test("caption latency diagnostics distinguish a warm model from a cold start")
    func temperatureLabelsMatchModelState() {
        let app = AppDelegate()
        for warm in [false, true] {
            app.recordCaptionTimingForTests(warmStart: warm)
            let entries = Diagnostics.recentTimings.filter {
                ["captions.first-text", "captions.first-final", "captions.visible-lag"].contains($0.operation)
            }.prefix(3)
            #expect(entries.count == 3)
            #expect(entries.allSatisfy { $0.cold == !warm })
        }
    }

    @Test("Clauses are joined into one readable line")
    func joinsWithSpaces() {
        let parts = ["Untertitel für alles,", "was der", "Mac abspielt."]
        #expect(AppDelegate.joinClauses(parts) == "Untertitel für alles, was der Mac abspielt.")
    }

    @Test("A single clause is unchanged")
    func singleClause() {
        #expect(AppDelegate.joinClauses(["Hello."]) == "Hello.")
        #expect(AppDelegate.joinClauses([]) == "")
    }

    /// Chinese, Japanese and Thai are written without spaces between words.
    /// Inserting one produces text a native reader sees as broken — and gives a
    /// translator two tokens where the language has one.
    @Test("Spaceless scripts are joined without spaces")
    func spacelessScripts() {
        #expect(AppDelegate.joinClauses(["这是一个", "测试。"]) == "这是一个测试。")
        #expect(AppDelegate.joinClauses(["これは", "テストです。"]) == "これはテストです。")
        // A boundary between a spaceless script and Latin gets one readable
        // separator; only two spaceless-script runs stay tight.
        #expect(AppDelegate.joinClauses(["这是", "Mac"]) == "这是 Mac")
    }

    /// Korean uses Hangul but writes with spaces, so it must not be lumped in
    /// with the scripts that do not.
    @Test("Korean keeps its spaces")
    func koreanIsSpaced() {
        #expect(AppDelegate.joinClauses(["안녕하세요", "반갑습니다."]) == "안녕하세요 반갑습니다.")
    }

    @Test("Every terminator that ends a sentence is recognised")
    func terminators() {
        for end in [".", "!", "?", "…", "。", "！", "？"] {
            let last = Character(end)
            #expect(AppDelegate.sentenceTerminatorsForTests.contains(last),
                    "\(end) should close a sentence")
        }
        // A comma must NOT close one — it is exactly where the engine breaks a
        // clause, and closing there is the bug this whole file is about.
        for mid in [",", "、", "，", ";", ":"] {
            #expect(!AppDelegate.sentenceTerminatorsForTests.contains(Character(mid)),
                    "\(mid) is a clause break, not a sentence end")
        }
    }

    /// Without a cap, speech that never pauses and never gets punctuation would
    /// accumulate for the whole session and never be translated at all.
    @Test("The length cap is large enough for a real sentence and small enough to bound")
    func lengthCap() {
        #expect(AppDelegate.maxSentenceCharsForTests >= 180,
                "a long spoken sentence must fit without being chopped")
        #expect(AppDelegate.maxSentenceCharsForTests <= 400,
                "past this the bubble cannot show it anyway")

        // The cap is a capacity bound — what the four-line bubble can show — and
        // it is not a readability target. Those disagree, and the disagreement
        // is the known live-caption weakness rather than an oversight:
        //
        //   220 characters at CaptionTiming's 14/second needs ~15.7s to read,
        //   and arrives in roughly the 3s the sentence took to speak.
        //
        // Lowering it to Export.cueCharacterBudget (84) makes each caption
        // readable and costs nothing to implement, but chops a long sentence in
        // half to do it. The export spends *time* instead — several cues in
        // sequence — which the one-row live bubble cannot do without deferring
        // the paint behind the display advance.
        let readingSeconds = Double(AppDelegate.maxSentenceCharsForTests) / 14.0
        #expect(readingSeconds > 10,
                "if this ever drops below ~10s the cap and the export budget should be unified")
        #expect(Export.cueCharacterBudget < AppDelegate.maxSentenceCharsForTests,
                "the export splits a caption the live bubble shows whole")
    }
}
