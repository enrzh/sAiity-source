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
        // A boundary between a spaceless script and Latin still runs on: the
        // clause break came from inside one sentence, not between two.
        #expect(AppDelegate.joinClauses(["这是", "Mac"]) == "这是Mac")
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
    }
}
