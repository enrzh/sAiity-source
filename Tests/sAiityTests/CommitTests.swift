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

    @Test("A word with no spaces at all is never cut")
    func noBoundaryMeansNoCommit() {
        #expect(StreamingASRBackend.rollingCommitPoint(
            String(repeating: "a", count: 200), since: longAgo) == nil)
    }
}
