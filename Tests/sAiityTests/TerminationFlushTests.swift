import AppKit
import Foundation
import Testing

@testable import sAiity

/// Quitting used to drop the sentence in progress.
///
/// A caption session only ever learns about a sentence when something closes
/// it — punctuation, a speech gap, the length cap, or teardown. None of those
/// is guaranteed to have happened by the time the user hits ⌘Q, so the last
/// thing anybody said in every session that ended with the app was recognised,
/// displayed, and then thrown away: it was still sitting in `sentenceParts`,
/// which nothing on the quit path read. The append it needed was queued in the
/// same breath, and the store drops anything that arrives after `end()`.
///
/// `.serialized` because each case snapshots and restores the same preferences.
@MainActor
@Suite(.serialized) struct TerminationFlushTests {

    /// Preferences the quit path reads. Restored so a test cannot leave the
    /// developer's own settings changed.
    private func snapshottingPreferences(_ work: () async -> Void) async {
        let keys = ["announceCaptions", "translateTo", "saveTranscript", CaptionStyle.key]
        let snapshot = keys.map { ($0, UserDefaults.standard.object(forKey: $0)) }
        defer {
            snapshot.forEach { key, value in
                if let value { UserDefaults.standard.set(value, forKey: key) }
                else { UserDefaults.standard.removeObject(forKey: key) }
            }
        }
        await work()
    }

    @Test("quitting closes the sentence that was still being assembled",
          .timeLimit(.minutes(1)))
    func quitClosesTheOpenSentence() async {
        await snapshottingPreferences {
            let app = AppDelegate()
            app.openSentenceForTests(["the last thing", "anybody said"])

            await app.flushOnQuit()

            #expect(app.pendingSentenceForTests.isEmpty,
                    "the open sentence survived the quit")
            #expect(app.sessionLinesForTests.map(\.text) == ["the last thing anybody said"])
            // One close, one line: a second quit must not duplicate it.
            await app.flushOnQuit()
            #expect(app.sessionLinesForTests.count == 1)
        }
    }

    @Test("quitting with nothing open is a no-op for the transcript",
          .timeLimit(.minutes(1)))
    func quitWithoutAnOpenSentenceAddsNoLine() async {
        await snapshottingPreferences {
            let app = AppDelegate()

            await app.flushOnQuit()

            #expect(app.sessionLinesForTests.isEmpty)
            #expect(app.pendingTranscriptWritesForTests == 0)
        }
    }

    @Test("the quit drain lets a queued transcript write reach the store",
          .timeLimit(.minutes(1)))
    func drainLetsAQueuedWriteLand() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("saiity-terminate-drain-\(UUID().uuidString)")
        TranscriptStore.sessionsDirOverride = root
        defer {
            TranscriptStore.sessionsDirOverride = nil
            try? FileManager.default.removeItem(at: root)
        }
        try await TranscriptStore.shared.begin(locale: "en-US", translateTo: nil)

        let app = AppDelegate()
        app.openSentenceForTests(["written before quit"])
        app.closeSentenceForTests()
        #expect(app.pendingTranscriptWritesForTests == 1,
                "closing a sentence queued no transcript write to wait for")

        await app.drainTranscriptWrites(within: .seconds(5))

        #expect(app.pendingTranscriptWritesForTests == 0,
                "the drain did not let the queued write run")
        #expect(await TranscriptStore.shared.currentLineCount == 1)
        // Captured before `end()`, which closes the session and forgets its
        // directory. The store knows which session it opened; a directory
        // listing is only the filesystem's view of it, and indexing `[0]` reads
        // a different session's file the moment anything else writes here.
        let session = try #require(await TranscriptStore.shared.currentSessionRefForTests)
        try await TranscriptStore.shared.end()

        let lines = try String(contentsOf: session.appendingPathComponent("segments.jsonl"),
                               encoding: .utf8)
        #expect(lines.contains("written before quit"),
                "the line closed at quit is not in the transcript: \(lines)")
    }

    @Test("the quit drain is bounded and does not wait when nothing is owed",
          .timeLimit(.minutes(1)))
    func drainReturnsWhenNothingIsPending() async {
        let app = AppDelegate()
        let started = ContinuousClock.now
        await app.drainTranscriptWrites(within: .seconds(5))
        let elapsed = ContinuousClock.now.duration(to: started)

        #expect(app.pendingTranscriptWritesForTests == 0)
        #expect(elapsed < .seconds(1),
                "the drain waited for a deadline it had no reason to wait for")
    }

    @Test("a quit is held open until the transcript is flushed")
    func quitIsDeferredUntilTheFlushFinishes() async {
        await snapshottingPreferences {
            let app = AppDelegate()
            app.openSentenceForTests(["deferred quit"])

            let reply = app.applicationShouldTerminate(NSApp)

            #expect(reply == .terminateLater)
            // The reply comes from the flush, so the process stays alive until
            // the sentence it just closed has been written. Polled with real
            // sleeps: the flush waits on the write chain, so yielding alone
            // would never give it the time it needs.
            let deadline = ContinuousClock.now + .seconds(2)
            while !app.pendingSentenceForTests.isEmpty, ContinuousClock.now < deadline {
                try? await Task.sleep(for: .milliseconds(10))
            }
            #expect(app.pendingSentenceForTests.isEmpty)
            #expect(app.sessionLinesForTests.map(\.text) == ["deferred quit"])
        }
    }
}
