import Foundation
import Testing

@testable import sAiity

/// When a caption becomes final decides when it gets translated. Too eager and
/// the translator sees fragments; too lazy and nothing is translated until the
/// audio stops — which is what actually happened, because the multilingual model
/// often emits no punctuation and only silence produced a final.
struct CommitTests {

    private let longAgo = Date(timeIntervalSinceNow: -60)
    private let justNow = Date()

    @Test("A short phrase is left alone")
    func shortPhrasesWait() {
        // Committing two words would give the translator no context at all.
        #expect(StreamingASRBackend.rollingCommitPoint("und dann", since: longAgo) == nil)
        #expect(StreamingASRBackend.rollingCommitPoint("", since: longAgo) == nil)
    }

    @Test("A phrase that has been waiting is committed")
    func overduePhrasesCommit() {
        let text = "der Zug nach München faehrt heute leider zwanzig Minuten spaeter als geplant"
        let cut = StreamingASRBackend.rollingCommitPoint(text, since: longAgo)
        #expect(cut != nil, "a long, overdue phrase should be committed")
        if let cut { #expect(!String(text[..<cut]).isEmpty) }
    }

    @Test("A fresh phrase is not committed early")
    func recentPhrasesWait() {
        // Still within the window: give punctuation a chance to arrive first,
        // since a whole sentence is the better unit.
        let text = "der Zug nach München faehrt heute leider zwanzig Minuten"
        #expect(StreamingASRBackend.rollingCommitPoint(text, since: justNow) == nil)
    }

    @Test("Speech that runs on is committed on length alone")
    func veryLongPhrasesCommitEvenIfRecent() {
        // Someone talking without pausing must not accumulate an unbounded
        // volatile line — the bubble would grow without ever translating.
        let text = String(repeating: "und dann noch etwas mehr Text ", count: 8)
        #expect(StreamingASRBackend.rollingCommitPoint(text, since: justNow) != nil)
    }

    @Test("The cut is always at a word boundary")
    func neverSplitsAWord() {
        let text = "der Zug nach München faehrt heute leider zwanzig Minuten spaeter als geplant"
        guard let cut = StreamingASRBackend.rollingCommitPoint(text, since: longAgo) else {
            Issue.record("expected a commit point"); return
        }
        let head = String(text[..<cut])
        // A fragment like "spaet" is not a word in any language, and a
        // translator will confidently invent something from it.
        #expect(head.hasSuffix(" "), "commit point must fall after a space")
        #expect(text.hasPrefix(head))
    }

    @Test("The most recent words stay volatile")
    func leavesATailForTheEngineToRevise() {
        // The engine is likeliest to revise its newest tokens. Committing them
        // means the user sees a correction to text already treated as final.
        let text = "der Zug nach München faehrt heute leider zwanzig Minuten spaeter als geplant"
        guard let cut = StreamingASRBackend.rollingCommitPoint(text, since: longAgo) else {
            Issue.record("expected a commit point"); return
        }
        #expect(String(text[cut...]).count >= 8, "too little left volatile to absorb a revision")
    }

    @Test("Japanese commits without waiting for silence")
    func spacelessScriptsStillCommit() {
        // The bug: this required `lastIndex(of: " ")`, and Japanese, Chinese and
        // Thai are written without spaces — so it returned nil forever, nothing
        // was committed, and nothing was translated until the speaker stopped.
        // Reported as "translation takes really long for Japanese"; it was not
        // the model, it was that the caption never became final.
        let ja = "最近新人が入ったり新しいプロジェクトが始まったりしてちょっとごたごたしている"
        let cut = StreamingASRBackend.rollingCommitPoint(ja, since: longAgo)
        #expect(cut != nil, "Japanese never reaches a commit point")
        if let cut {
            #expect(!String(ja[..<cut]).isEmpty)
            #expect(!String(ja[cut...]).isEmpty, "nothing left volatile")
        }
    }

    @Test("A clause break is preferred to an arbitrary character")
    func clauseBreaksWin() {
        // 、 is the natural place to split a Japanese line; cutting mid-phrase
        // hands the translator a fragment.
        let ja = "それでちょっと早く会社に行って、準備したいんだけどそれでいいと思うんだけどね"
        guard let cut = StreamingASRBackend.rollingCommitPoint(ja, since: longAgo) else {
            Issue.record("expected a commit point"); return
        }
        #expect(String(ja[..<cut]).hasSuffix("、"), "did not cut at the clause break")
    }

    @Test("A Japanese full stop ends a sentence")
    func cjkSentenceEnd() {
        // The sentence regex demanded a space or end-of-string after the stop,
        // which Latin text has and CJK does not — so 。 never counted and the
        // punctuation path was dead for those languages too.
        let pattern = "(?:[.!?](?:\\s|$))|[。！？…]"
        for text in ["これはテストです。次の文もあります", "本当ですか？そうですね", "すごい！とても"] {
            #expect(text.range(of: pattern, options: .regularExpression) != nil,
                    "no sentence boundary found in \(text)")
        }
        // And a decimal point still must not end one.
        #expect("The price is 3.50 today".range(
            of: pattern, options: .regularExpression) == nil)
    }

    @Test("A single unbroken run with nothing to cut on is left alone")
    func noBoundaryMeansNoCommit() {
        // Latin text with no space and no punctuation is a URL or a token, not
        // speech — splitting it mid-word would give the translator nonsense.
        // (Spaceless SCRIPTS are handled above; this is one long "word".)
        #expect(StreamingASRBackend.rollingCommitPoint(
            String(repeating: "a", count: 8), since: longAgo) == nil)
    }
}
