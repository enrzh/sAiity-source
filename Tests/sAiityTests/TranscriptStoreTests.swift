import Foundation
import Testing

@testable import sAiity

/// The store is the only thing standing between a meeting and the disk, and
/// every way it can be wrong is silent: a lost line is a sentence nobody has
/// any record of, and a wrong count or a stale cache entry shows up as a
/// transcript list that quietly lies.
///
/// Isolation comes from a task-local library directory rather than
/// `.serialized`: these tests are hermetic, and another suite writing
/// transcripts in parallel must not be able to see — or delete — this one's.
@MainActor
struct TranscriptStoreTests {

    /// Run `body` against a throwaway library.
    ///
    /// A test must not be able to delete somebody's real transcripts, and the
    /// retention policy can only be tested with sessions old enough to match.
    private func withTemporaryLibrary<T>(
        _ body: (URL) async throws -> T) async throws -> T {
        try await TranscriptTestLibrary.withTemporaryDirectory(body)
    }

    private func chunk(_ text: String, _ start: Double, _ end: Double,
                       words: [TimedWord] = []) -> TranscriptChunk {
        TranscriptChunk(text: text, isFinal: true, start: start, end: end, words: words)
    }

    @Test("bubble saves a complete transcript as a library session")
    func saveSessionRoundTrip() throws {
        let segments = [
            Segment(i: 0, t0: 0, t1: 1.2, text: "Hallo world", loc: "de",
                    tr: "Hello world", trLoc: "en", words: nil),
            Segment(i: 1, t0: 1.3, t1: 2.4, text: "你好", loc: "zh",
                    tr: "Hello", trLoc: "en", words: nil,
                    speaker: "speaker-1")
        ]
        let session = try TranscriptStore.saveSession(segments, locale: "de-DE",
                                                       translateTo: "en",
                                                       startedAt: Date(timeIntervalSince1970: 1_800_000_000))
        defer { TranscriptStore.delete(session) }

        #expect(session.meta.lineCount == 2)
        #expect(session.meta.locale == "de-DE")
        #expect(session.meta.translateTo == "en")
        #expect(TranscriptStore.segments(of: session).map(\.text) == ["Hallo world", "你好"])
        #expect(TranscriptStore.segments(of: session).map(\.tr) == ["Hello world", "Hello"])
        #expect(TranscriptStore.segments(of: session).map(\.speaker) == [nil, "speaker-1"])
    }

    /// The store is a long-lived handle plus an index. Both have to be right:
    /// a lost `i` corrupts every later line, and an index that does not advance
    /// silently overwrites the line before it.
    @Test("appended lines land in order, numbered once, and end closes the session")
    func appendKeepsOrderAndEndCloses() async throws {
        try await withTemporaryLibrary { _ in
            let store = TranscriptStore()
            #expect(await store.isRecording == false)
            try await store.begin(locale: "de-DE", translateTo: "en")

            #expect(await store.isRecording)
            let words = [TimedWord(start: 1, end: 1.4, text: "Hallo ")]
            for i in 0..<25 {
                try await store.append(chunk("Zeile \(i)", Double(i), Double(i) + 0.5,
                                             words: i == 0 ? words : []),
                                        locale: "de-DE",
                                        translation: i.isMultiple(of: 2) ? "Line \(i)" : nil,
                                        translateTo: "en",
                                        turn: i == 24)
                #expect(await store.currentLineCount == i + 1)
            }

            let session = try #require(TranscriptStore.list().first)
            // Still open: the in-progress session is listed, but not finished.
            #expect(session.meta.endedAt == nil)
            // The count on disk lags by design — meta.json is rewritten every
            // twentieth line, so 20 is the truth on disk after 25 appends, not
            // 25. Pinning the lag is the point: it is what makes a crash
            // recoverable rather than losing the session.
            #expect(session.meta.lineCount == 20)

            try await store.end()
            #expect(await store.isRecording == false)

            let lines = TranscriptStore.segments(of: session)
            #expect(lines.count == 25)
            #expect(lines.map(\.i) == Array(0..<25), "line indices were \(lines.map(\.i))")
            #expect(lines.map(\.text) == (0..<25).map { "Zeile \($0)" })
            #expect(lines.map(\.t0) == (0..<25).map(Double.init))
            #expect(lines.filter { $0.turn == true }.map(\.i) == [24])
            #expect(lines.first?.words?.map(\.text) == ["Hallo "])
            #expect(lines[0].tr == "Line 0")
            #expect(lines[1].tr == nil)

            let closed = try #require(TranscriptStore.list().first)
            #expect(closed.meta.endedAt != nil, "end() must stamp the finish time")
            #expect(closed.meta.lineCount == 25,
                    "end() is the one place the exact count has to be written")
        }
    }

    /// An app that quits mid-meeting leaves a session with no `end()`. The lines
    /// that reached disk are still a transcript, and the listing has to show one
    /// — the alternative is a session the user can see but not read.
    @Test("a session that never ended is still listed and still readable")
    func unfinishedSessionRemainsReadable() async throws {
        try await withTemporaryLibrary { _ in
            let store = TranscriptStore()
            try await store.begin(locale: "en-US", translateTo: nil)
            for i in 0..<3 {
                try await store.append(chunk("line \(i)", Double(i), Double(i) + 1),
                                       locale: "en-US", translation: nil, translateTo: nil)
            }
            // No end(): this is the crash, the force-quit, the killed process.
            let session = try #require(TranscriptStore.list().first)
            #expect(session.meta.lineCount == 0,
                    "the counter is only flushed every twentieth line, so the file on disk lags")
            #expect(session.meta.endedAt == nil)
            // The lines themselves are complete and ordered, which is what the
            // user is actually reading.
            let lines = TranscriptStore.segments(of: session)
            #expect(lines.count == 3)
            #expect(lines.map(\.i) == [0, 1, 2])
        }
    }

    /// Metadata is a small JSON file rewritten in place. If a write fails, the
    /// session must still be listed and still readable — the lines are the
    /// record, and losing them because a counter could not be written down is
    /// the worst possible trade.
    @Test("a session whose metadata cannot be rewritten keeps its lines")
    func metadataFailureDoesNotLoseLines() async throws {
        try await withTemporaryLibrary { dir in
            let store = TranscriptStore()
            try await store.begin(locale: "en-US", translateTo: nil)
            for i in 0..<19 {
                try await store.append(chunk("line \(i)", Double(i), Double(i) + 1),
                                       locale: "en-US", translation: nil, translateTo: nil)
            }
            let session = try #require(TranscriptStore.list().first)

            // Make meta.json undeletable and unwritable by turning it into a
            // directory: the atomic replace then has nowhere to go, which is
            // the same shape of failure as a full disk or a read-only volume.
            let metaURL = session.url.appendingPathComponent("meta.json")
            let saved = try Data(contentsOf: metaURL)
            try FileManager.default.removeItem(at: metaURL)
            try FileManager.default.createDirectory(at: metaURL, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: metaURL) }

            // Line 20 triggers the every-twentieth metadata rewrite, which fails.
            await #expect(throws: (any Error).self) {
                try await store.append(chunk("line 19", 19, 20),
                                       locale: "en-US", translation: nil, translateTo: nil)
            }
            // A failed append must not leave the UI believing recording continues.
            #expect(await store.isRecording == false)
            #expect(TranscriptStore.list().isEmpty,
                    "a session whose meta.json is not a file cannot be listed")

            // The lines are still on disk, complete and in order, and the last
            // metadata written successfully still reads back.
            let raw = try String(contentsOf: session.url.appendingPathComponent("segments.jsonl"),
                                 encoding: .utf8)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let decoded = try raw.split(separator: "\n").map {
                try decoder.decode(Segment.self, from: Data($0.utf8))
            }
            #expect(decoded.map(\.i) == Array(0..<20), "the failed line corrupted the file")
            #expect(decoded.map(\.text) == (0..<20).map { "line \($0)" })
            // The counter on disk lags until the twentieth line, so the file
            // still reads as the empty session it was at `begin`. The lines are
            // the record; the counter is a convenience.
            let lastGood = try decoder.decode(SessionMeta.self, from: saved)
            #expect(lastGood.lineCount == 0)
        }
    }

    @Test("appending without a session is a no-op, not a crash")
    func appendWithoutBeginDoesNothing() async throws {
        try await withTemporaryLibrary { dir in
            let store = TranscriptStore()
            try await store.append(chunk("orphan", 0, 1), locale: "en-US",
                                   translation: nil, translateTo: nil)
            try await store.end()
            #expect(await store.currentLineCount == 0)
            #expect(TranscriptStore.list().isEmpty)
            #expect(dir.path.hasPrefix(NSTemporaryDirectory()),
                    "the test library has to be somewhere disposable")
        }
    }

    /// The app's real write path is not a call from the caller's task: a
    /// sentence is closed on the main actor and the transcript write is queued
    /// behind the translation in a task of its own. A test that only ever
    /// appends from its own task would pass against a mechanism that any queued
    /// write escaped.
    @Test("a write queued onto another task still lands in the scoped library")
    func queuedWritesSeeTheScopedLibrary() async throws {
        try await withTemporaryLibrary { dir in
            let store = TranscriptStore()
            try await store.begin(locale: "en-US", translateTo: nil)
            Task { @MainActor in
                try? await store.append(chunk("queued", 0, 1), locale: "en-US",
                                        translation: nil, translateTo: nil)
            }
            for _ in 0..<200 where await store.currentLineCount == 0 {
                try await Task.sleep(for: .milliseconds(5))
            }
            #expect(await store.currentLineCount == 1, "the queued write never ran")

            let session = try #require(TranscriptStore.list().first)
            #expect(TranscriptStore.segments(of: session).map(\.text) == ["queued"])
            // And it went here: a library scoped per task that a detached write
            // could not see would leave a stray session in the real one.
            let written = try FileManager.default.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: nil)
            #expect(written.count == 1, "sessions landed outside the scoped library: \(written)")
            #expect(try String(contentsOf: written[0].appendingPathComponent("segments.jsonl"),
                               encoding: .utf8).contains("queued"))
            try await store.end()
        }
    }

    /// A second recording inside the same second must not overwrite the first.
    /// The `-2` suffix is the only thing standing between two meetings and one
    /// silently truncated transcript.
    @Test("two sessions in the same second do not collide")
    func sameSecondSessionsDoNotCollide() async throws {
        try await withTemporaryLibrary { _ in
            let started = Date()
            let first = try TranscriptStore.saveSession(
                [Segment(i: 0, t0: 0, t1: 1, text: "first", loc: "en", tr: nil, trLoc: nil, words: nil)],
                locale: "en-US", translateTo: nil, startedAt: started)
            let second = try TranscriptStore.saveSession(
                [Segment(i: 0, t0: 0, t1: 1, text: "second", loc: "en", tr: nil, trLoc: nil, words: nil)],
                locale: "en-US", translateTo: nil, startedAt: started)
            #expect(first.id != second.id)
            #expect(TranscriptStore.segments(of: first).map(\.text) == ["first"])
            #expect(TranscriptStore.segments(of: second).map(\.text) == ["second"])
        }
    }

    /// Retention deletes real directories. The age has to come from the
    /// session's own start date — an export written into the session directory
    /// updates its mtime, and mtime would make an old meeting look brand new
    /// forever, which is the direction that silently never deletes anything.
    @Test("retention deletes sessions past the age and keeps the rest")
    func retentionDeletesOnlyExpiredSessions() async throws {
        try await withTemporaryLibrary { _ in
            let now = Date()
            func session(daysOld: Int, text: String) throws -> SessionRef {
                try TranscriptStore.saveSession(
                    [Segment(i: 0, t0: 0, t1: 1, text: text, loc: "en",
                             tr: nil, trLoc: nil, words: nil)],
                    locale: "en-US", translateTo: nil,
                    startedAt: now.addingTimeInterval(-Double(daysOld) * 86_400))
            }
            let old = try session(daysOld: 400, text: "ancient")
            let recent = try session(daysOld: 2, text: "yesterday")
            let future = try session(daysOld: -1, text: "clock skew")

            // The sweep is a no-op when retention is off, which is the default:
            // deleting a user's data on a schedule they did not ask for is its
            // own kind of wrong.
            #expect(TranscriptStore.sessionsOlderThan(days: 0).isEmpty)
            #expect(TranscriptStore.deleteOlderThan(days: 0) == 0)
            #expect(TranscriptStore.list().count == 3)

            #expect(TranscriptStore.sessionsOlderThan(days: 30).map(\.id) == [old.id])
            #expect(TranscriptStore.isExpired(old, days: 30))
            #expect(!TranscriptStore.isExpired(recent, days: 30))
            #expect(TranscriptStore.isExpired(old, days: 0) == false)

            // Age from the session's own start date, not the directory's mtime.
            let export = old.url.appendingPathComponent("sAiity-export.srt")
            try Data().write(to: export)
            #expect(TranscriptStore.sessionsOlderThan(days: 30).map(\.id) == [old.id])

            #expect(TranscriptStore.deleteOlderThan(days: 30) == 1)
            #expect(!FileManager.default.fileExists(atPath: old.url.path))
            #expect(TranscriptStore.list().map(\.id) == [future.id, recent.id].sorted(by: >))
            // And it is idempotent: the second sweep finds nothing to do.
            #expect(TranscriptStore.deleteOlderThan(days: 30) == 0)

            TranscriptStore.deleteAll()
            #expect(TranscriptStore.list().isEmpty)
        }
    }

    /// The listing is cached on a file stamp, and the cached lines on their own
    /// stamp. Both caches have to notice a change: a transcript list that keeps
    /// showing a deleted meeting, or a viewer that keeps showing the words of a
    /// file that no longer exists, is worse than no cache.
    @Test("the listing cache notices an edit and a deletion")
    func listCacheFollowsEditsAndDeletions() async throws {
        try await withTemporaryLibrary { _ in
            let session = try TranscriptStore.saveSession(
                [Segment(i: 0, t0: 0, t1: 1, text: "original", loc: "en",
                         tr: nil, trLoc: nil, words: nil)],
                locale: "en-US", translateTo: nil, startedAt: Date())
            // Warm both caches.
            #expect(TranscriptStore.list().map(\.meta.lineCount) == [1])
            #expect(TranscriptStore.segments(of: session).map(\.text) == ["original"])

            // An edit outside the store — a re-translation rewrites the files,
            // and a restore from a backup replaces them. The size changes, so
            // the stamp changes, so the cache must re-read.
            var meta = try #require(TranscriptStore.list().first).meta
            meta.lineCount = 42
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            try encoder.encode(meta).write(to: session.url.appendingPathComponent("meta.json"),
                                           options: .atomic)
            var lines = try String(contentsOf: session.url.appendingPathComponent("segments.jsonl"),
                                   encoding: .utf8)
            lines += "{\"i\":1,\"t0\":1,\"t1\":2,\"text\":\"added\",\"loc\":\"en\"}\n"
            try Data(lines.utf8).write(to: session.url.appendingPathComponent("segments.jsonl"))

            #expect(TranscriptStore.list().map(\.meta.lineCount) == [42],
                    "the listing served a stale meta.json")
            #expect(TranscriptStore.segments(of: session).map(\.text) == ["original", "added"],
                    "the segment cache served stale lines")

            TranscriptStore.delete(session)
            #expect(TranscriptStore.list().isEmpty, "a deleted session stayed in the listing")
            #expect(!FileManager.default.fileExists(atPath: session.url.path))
            #expect(TranscriptStore.segments(of: session).isEmpty)
        }
    }

    /// A directory with no readable metadata is not a session, and must not be
    /// listed as one — an empty row in a transcript list is a support ticket.
    @Test("a session directory without readable metadata is not listed")
    func unreadableMetadataIsNotListed() async throws {
        try await withTemporaryLibrary { dir in
            let broken = dir.appendingPathComponent("2020-01-01T000000", isDirectory: true)
            try FileManager.default.createDirectory(at: broken, withIntermediateDirectories: true)
            try Data(repeating: 0, count: 8).write(to: broken.appendingPathComponent("meta.json"))
            let good = try TranscriptStore.saveSession(
                [Segment(i: 0, t0: 0, t1: 1, text: "readable", loc: "en",
                         tr: nil, trLoc: nil, words: nil)],
                locale: "en-US", translateTo: nil, startedAt: Date())

            #expect(TranscriptStore.list().map(\.id) == [good.id])
            // And the good one survives a sweep: unreadable is not "expired".
            #expect(TranscriptStore.deleteOlderThan(days: 1) == 0)
            #expect(FileManager.default.fileExists(atPath: broken.path))
            #expect(TranscriptStore.list().map(\.id) == [good.id])
        }
    }
}
