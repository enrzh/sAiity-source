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
    @Test("DUP7 legacy metadata decodes an absent optional title without changing its fields")
    func dup7LegacyMetadataHasOptionalTitle() async throws {
        try await TranscriptTestLibrary.withTemporaryDirectory { _ in
            let raw = Data(#"{"v":1,"id":"legacy","startedAt":"2026-10-09T12:00:00Z","endedAt":"2026-10-09T12:05:00Z","locale":"ja-JP","translateTo":"de","lineCount":42}"#.utf8)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let meta = try decoder.decode(SessionMeta.self, from: raw)
            #expect(Mirror(reflecting: meta).children.contains { $0.label == "title" },
                    "SessionMeta must expose an optional title even for pre-title metadata")
            #expect(meta.id == "legacy" && meta.locale == "ja-JP" && meta.translateTo == "de")
            #expect(meta.lineCount == 42 && meta.endedAt != nil && meta.v == 1)
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            let original = try #require(JSONSerialization.jsonObject(with: raw) as? NSDictionary)
            let encoded = try #require(JSONSerialization.jsonObject(with: encoder.encode(meta)) as? NSDictionary)
            #expect(encoded == original, "decoding old metadata must not invent or rewrite any field")
        }
    }

    @Test("DUP7 Unicode titles survive metadata decode, encode and a scoped library listing")
    func dup7MetadataTitleRoundTrip() async throws {
        try await TranscriptTestLibrary.withTemporaryDirectory { root in
            let session = try TranscriptStore.saveSession(
                [Segment(i: 0, t0: 0, t1: 1, text: "原文", loc: "ja", tr: "Original", trLoc: "en", words: nil)],
                locale: "ja", translateTo: "en", in: root)
            let metadata = session.url.appendingPathComponent("meta.json")
            let spoken = session.url.appendingPathComponent("segments.jsonl")
            let spokenBefore = try Data(contentsOf: spoken)
            let originalMetadata = try Data(contentsOf: metadata)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let stored = try decoder.decode(SessionMeta.self, from: originalMetadata)
            var fields = try #require(JSONSerialization.jsonObject(with: originalMetadata) as? [String: Any])
            let title = "製品レビュー — Café 👩🏽‍💻 / Q4"
            fields["title"] = title
            let raw = try JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys])
            try raw.write(to: metadata, options: .atomic)
            let listed = try #require(TranscriptStore.list(in: root).first)
            #expect(listed.id == session.id && listed.url == session.url)
            #expect(listed.meta.lineCount == session.meta.lineCount)
            #expect(listed.meta.startedAt == stored.startedAt && listed.meta.endedAt == stored.endedAt)
            #expect(listed.meta.locale == "ja" && listed.meta.translateTo == "en")
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            let encoded = try #require(JSONSerialization.jsonObject(with: encoder.encode(listed.meta)) as? [String: Any])
            #expect(encoded["title"] as? String == title, "the optional user title was silently discarded")
            #expect(NSDictionary(dictionary: encoded) == NSDictionary(dictionary: fields))
            #expect(try Data(contentsOf: spoken) == spokenBefore)
        }
    }

    @Test("DUP7 rename changes only latest metadata title and keeps private permissions")
    func dup7RenamePreservesLatestMetadataAndArtifacts() async throws {
        try await TranscriptTestLibrary.withTemporaryDirectory { root in
            let store = TranscriptStore()
            let session = try TranscriptStore.saveSession(
                [Segment(i: 0, t0: 0, t1: 2, text: "原文", loc: "ja", tr: "Original", trLoc: "en", words: nil,
                         turn: true, speaker: "voice-2", overlappingSpeech: true)],
                locale: "ja", translateTo: "en")
            let segments = TranscriptStore.segments(of: session)
            let srtBefore = Export.srt(segments)
            let vttBefore = Export.vtt(segments)
            let artifacts = ["segments.jsonl", "summary.json", "existing.txt", "existing.md", "existing.srt", "existing.vtt"]
            for name in artifacts.dropFirst() {
                try Data("existing \(name)\n原文\n".utf8).write(to: session.url.appendingPathComponent(name))
            }
            let bytesBefore = try artifacts.map { try Data(contentsOf: session.url.appendingPathComponent($0)) }
            let namesBefore = try FileManager.default.contentsOfDirectory(atPath: session.url.path).sorted()
            var latest = session.meta
            latest.lineCount = 42
            latest.startedAt = Date(timeIntervalSince1970: 1_700_000_000)
            latest.endedAt = Date(timeIntervalSince1970: 1_700_000_120)
            latest.locale = "ja-JP"
            latest.translateTo = "de"
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            let metadata = session.url.appendingPathComponent("meta.json")
            try encoder.encode(latest).write(to: metadata, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: metadata.path)
            let before = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: metadata)) as? [String: Any])
            _ = TranscriptStore.list(in: root)
            let title = "製品レビュー — Café 👩🏽‍💻 / Q4"
            try await store.renameSession(session, title: "  \(title)  ")
            let renamed = try #require(TranscriptStore.list(in: root).first)
            #expect(renamed.id == session.id && renamed.url == session.url && renamed.meta.title == title)
            var after = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: metadata)) as? [String: Any])
            #expect(after.removeValue(forKey: "title") as? String == title)
            #expect(NSDictionary(dictionary: before) == NSDictionary(dictionary: after), "stale SessionRef overwrote newer metadata")
            let permissions = try FileManager.default.attributesOfItem(atPath: metadata.path)[.posixPermissions] as? NSNumber
            #expect(permissions?.intValue == 0o600)
            #expect(try artifacts.map { try Data(contentsOf: session.url.appendingPathComponent($0)) } == bytesBefore)
            #expect(try FileManager.default.contentsOfDirectory(atPath: session.url.path).sorted() == namesBefore)
            let lines = TranscriptStore.segments(of: renamed)
            #expect(Export.srt(lines) == srtBefore && Export.vtt(lines) == vttBefore)
            #expect(Export.txt(lines, meta: renamed.meta) == title + "\n\n" + Export.txt(segments))
            #expect(Export.markdown(lines, meta: renamed.meta, localized: false).hasPrefix("# \(title)\n\n"))
        }
    }

    @Test("DUP7 rename counts Unicode Characters, clears blank titles and refreshes same-size metadata")
    func dup7RenameTitleBoundariesAndCache() async throws {
        try await TranscriptTestLibrary.withTemporaryDirectory { root in
            let store = TranscriptStore()
            let session = try TranscriptStore.saveSession([], locale: "en", translateTo: nil)
            let metadata = session.url.appendingPathComponent("meta.json")
            let title = String(repeating: "e\u{301}👩🏽‍💻", count: 40)
            #expect(title.count == 80)
            try await store.renameSession(session, title: title)
            #expect(TranscriptStore.list(in: root).first?.meta.title == title)
            try await store.renameSession(session, title: "AAAA")
            let attributes = try FileManager.default.attributesOfItem(atPath: metadata.path)
            let stamp = try #require(attributes[.modificationDate] as? Date)
            #expect(TranscriptStore.list(in: root).first?.meta.title == "AAAA")
            try await store.renameSession(session, title: "BBBB")
            try FileManager.default.setAttributes([.modificationDate: stamp], ofItemAtPath: metadata.path)
            #expect(TranscriptStore.list(in: root).first?.meta.title == "BBBB", "rename must evict the specific catalog entry")
            for cleared in [Optional("   \u{00a0}  "), nil] {
                try await store.renameSession(session, title: cleared)
                let renamed = try #require(TranscriptStore.list(in: root).first)
                #expect(renamed.meta.title == nil)
                #expect(Export.txt([], meta: renamed.meta).isEmpty)
                #expect(Export.markdown([], meta: renamed.meta, localized: false).hasPrefix("# Transcript — "))
                let fields = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: metadata)) as? [String: Any])
                #expect(fields["title"] == nil)
                try await store.renameSession(session, title: "Reset again")
            }
        }
    }

    @Test("DUP7 invalid title input leaves every saved file byte-identical")
    func dup7RenameRejectsInvalidTitlesWithoutWrites() async throws {
        try await TranscriptTestLibrary.withTemporaryDirectory { _ in
            let store = TranscriptStore()
            let session = try TranscriptStore.saveSession(
                [Segment(i: 0, t0: 0, t1: 1, text: "keep", loc: "en", tr: nil, trLoc: nil, words: nil)],
                locale: "en", translateTo: nil)
            for name in ["summary.json", "existing.md", "existing.txt", "existing.srt", "existing.vtt"] {
                try Data("unchanged \(name)".utf8).write(to: session.url.appendingPathComponent(name))
            }
            let names = try FileManager.default.contentsOfDirectory(atPath: session.url.path).sorted()
            let before = try names.map { try Data(contentsOf: session.url.appendingPathComponent($0)) }
            let invalid = [String(repeating: "界", count: 81), "line\nnext", "\n", "line\rnext", "tab\ttext",
                           "null\u{0000}text", "del\u{007f}text", "next\u{0085}line", "line\u{2028}next", "line\u{2029}next"]
            for title in invalid {
                await #expect(throws: (any Error).self) { try await store.renameSession(session, title: title) }
                #expect(try names.map { try Data(contentsOf: session.url.appendingPathComponent($0)) } == before)
                #expect(try FileManager.default.contentsOfDirectory(atPath: session.url.path).sorted() == names)
            }
        }
    }

    @Test("DUP7 rename rejects missing, outside, nested, root and symlink session paths")
    func dup7RenameRejectsUnsafeSessionPaths() async throws {
        try await TranscriptTestLibrary.withTemporaryDirectory { outside in
            let external = try TranscriptStore.saveSession([], locale: "en", translateTo: nil, in: outside)
            let externalMeta = try Data(contentsOf: external.url.appendingPathComponent("meta.json"))
            try await TranscriptTestLibrary.withTemporaryDirectory { root in
                let store = TranscriptStore()
                let session = try TranscriptStore.saveSession([], locale: "en", translateTo: nil)
                let original = try Data(contentsOf: session.url.appendingPathComponent("meta.json"))
                let nested = try TranscriptStore.saveSession([], locale: "en", translateTo: nil,
                                                             in: root.appendingPathComponent("nested", isDirectory: true))
                let nestedMeta = try Data(contentsOf: nested.url.appendingPathComponent("meta.json"))
                let link = root.appendingPathComponent("alias", isDirectory: true)
                try FileManager.default.createSymbolicLink(at: link, withDestinationURL: session.url)
                let missing = root.appendingPathComponent("deleted", isDirectory: true)
                let targets = [external, nested,
                               SessionRef(id: root.lastPathComponent, url: root, meta: session.meta),
                               SessionRef(id: link.lastPathComponent, url: link, meta: session.meta),
                               SessionRef(id: missing.lastPathComponent, url: missing, meta: session.meta),
                               SessionRef(id: "wrong-id", url: session.url, meta: session.meta)]
                let names = try FileManager.default.contentsOfDirectory(atPath: root.path).sorted()
                for target in targets {
                    await #expect(throws: (any Error).self) { try await store.renameSession(target, title: "Rejected") }
                }
                #expect(!FileManager.default.fileExists(atPath: missing.path))
                #expect(try Data(contentsOf: session.url.appendingPathComponent("meta.json")) == original)
                #expect(try Data(contentsOf: external.url.appendingPathComponent("meta.json")) == externalMeta)
                #expect(try Data(contentsOf: nested.url.appendingPathComponent("meta.json")) == nestedMeta)
                #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).sorted() == names)
                #expect(TranscriptStore.delete(session))
                await #expect(throws: (any Error).self) { try await store.renameSession(session, title: "Deleted") }
                #expect(!FileManager.default.fileExists(atPath: session.url.path))
            }
        }
    }

    @Test("DUP7 rename rejects symlink files, missing files and malformed or mismatched metadata")
    func dup7RenameRejectsUnsafeMetadataAndSpokenFiles() async throws {
        try await TranscriptTestLibrary.withTemporaryDirectory { root in
            let store = TranscriptStore()
            for name in ["meta.json", "segments.jsonl"] {
                let session = try TranscriptStore.saveSession([], locale: "en", translateTo: nil)
                let metadata = session.url.appendingPathComponent("meta.json")
                let file = session.url.appendingPathComponent(name)
                let originalMeta = try Data(contentsOf: metadata)
                let original = try Data(contentsOf: file)
                let destination = root.appendingPathComponent("protected-\(name)")
                try original.write(to: destination)
                try FileManager.default.removeItem(at: file)
                try FileManager.default.createSymbolicLink(at: file, withDestinationURL: destination)
                await #expect(throws: (any Error).self) { try await store.renameSession(session, title: "Symlink") }
                #expect(try Data(contentsOf: destination) == original)
                #expect(try Data(contentsOf: metadata) == originalMeta)
                #expect(try file.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == true)
                try FileManager.default.removeItem(at: file)
                await #expect(throws: (any Error).self) { try await store.renameSession(session, title: "Missing") }
                #expect(!FileManager.default.fileExists(atPath: file.path))
                try FileManager.default.createDirectory(at: file, withIntermediateDirectories: false)
                await #expect(throws: (any Error).self) { try await store.renameSession(session, title: "Nonregular") }
                #expect(try FileManager.default.contentsOfDirectory(atPath: file.path).isEmpty)
            }
            let session = try TranscriptStore.saveSession([], locale: "en", translateTo: nil)
            let metadata = session.url.appendingPathComponent("meta.json")
            let spoken = try Data(contentsOf: session.url.appendingPathComponent("segments.jsonl"))
            var wrong = session.meta
            wrong.id = "another-session"
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            for contents in [Data("not JSON".utf8), try encoder.encode(wrong)] {
                try contents.write(to: metadata, options: .atomic)
                await #expect(throws: (any Error).self) { try await store.renameSession(session, title: "Malformed") }
                #expect(try Data(contentsOf: metadata) == contents)
                #expect(try Data(contentsOf: session.url.appendingPathComponent("segments.jsonl")) == spoken)
            }
            let readable = try encoder.encode(session.meta)
            try readable.write(to: metadata, options: .atomic)
            do {
                try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: metadata.path)
                defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: metadata.path) }
                await #expect(throws: (any Error).self) { try await store.renameSession(session, title: "Unreadable") }
            }
            #expect(try Data(contentsOf: metadata) == readable)
            try FileManager.default.removeItem(at: metadata)
            try FileManager.default.createDirectory(at: metadata, withIntermediateDirectories: false)
            await #expect(throws: (any Error).self) { try await store.renameSession(session, title: "Directory") }
            #expect(try FileManager.default.contentsOfDirectory(atPath: metadata.path).isEmpty)
            #expect(try FileManager.default.contentsOfDirectory(atPath: session.url.path).sorted() == ["meta.json", "segments.jsonl"])
        }
    }

    @Test("DUP7 rename rejects active recording without changing or closing it")
    func dup7RenameRejectsActiveRecording() async throws {
        try await TranscriptTestLibrary.withTemporaryDirectory { root in
            let store = TranscriptStore()
            try await store.begin(locale: "en", translateTo: nil)
            try await store.append(chunk("keep recording", 0, 1), locale: "en", translation: nil, translateTo: nil)
            let session = try #require(TranscriptStore.list(in: root).first)
            let metadata = try Data(contentsOf: session.url.appendingPathComponent("meta.json"))
            let spoken = try Data(contentsOf: session.url.appendingPathComponent("segments.jsonl"))
            await #expect(throws: (any Error).self) { try await store.renameSession(session, title: "Active") }
            #expect(await store.isRecording)
            #expect(try Data(contentsOf: session.url.appendingPathComponent("meta.json")) == metadata)
            #expect(try Data(contentsOf: session.url.appendingPathComponent("segments.jsonl")) == spoken)
            try await store.append(chunk("next", 1, 2), locale: "en", translation: nil, translateTo: nil)
            try await store.end()
            try await store.renameSession(session, title: "Closed")
            #expect(TranscriptStore.list(in: root).first?.meta.title == "Closed")
            #expect(TranscriptStore.list(in: root).first?.meta.lineCount == 2)
        }
    }

    @Test("DUP7 rename and retranslation preserve each other's latest metadata")
    func dup7RenameAndRetranslationShareActorOrdering() async throws {
        try await TranscriptTestLibrary.withTemporaryDirectory { root in
            let store = TranscriptStore()
            let segment = Segment(i: 0, t0: 0, t1: 1, text: "hello", loc: "en", tr: nil, trLoc: nil, words: nil)
            let session = try TranscriptStore.saveSession([segment], locale: "en", translateTo: nil)
            let source = try Data(contentsOf: session.url.appendingPathComponent("segments.jsonl"))
            var translated = segment
            translated.tr = "hallo"
            translated.trLoc = "de"
            let rename = Task { try await store.renameSession(session, title: "Meeting") }
            let translation = Task { try await store.publishRetranslation([translated], to: session, source: source, target: "de") }
            let renameResult = await rename.result
            let translationResult = await translation.result
            try renameResult.get()
            try translationResult.get()
            let current = try #require(TranscriptStore.list(in: root).first)
            #expect(current.meta.title == "Meeting" && current.meta.translateTo == "de")
            #expect(current.meta.lineCount == 1)
            #expect(TranscriptStore.segments(of: current).first?.tr == "hallo")
        }
    }

    @Test("DUP7 rename publication failure preserves metadata and all artifacts")
    func dup7RenameWriteFailureLeavesNoStagingFiles() async throws {
        try await TranscriptTestLibrary.withTemporaryDirectory { _ in
            let store = TranscriptStore()
            let session = try TranscriptStore.saveSession([], locale: "en", translateTo: nil)
            for name in ["summary.json", "existing.txt", "existing.md", "existing.srt", "existing.vtt"] {
                try Data("unchanged \(name)".utf8).write(to: session.url.appendingPathComponent(name))
            }
            let names = try FileManager.default.contentsOfDirectory(atPath: session.url.path).sorted()
            let before = try names.map { try Data(contentsOf: session.url.appendingPathComponent($0)) }
            try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: session.url.path)
            defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: session.url.path) }
            await #expect(throws: (any Error).self) { try await store.renameSession(session, title: "Cannot publish") }
            #expect(try names.map { try Data(contentsOf: session.url.appendingPathComponent($0)) } == before)
            #expect(try FileManager.default.contentsOfDirectory(atPath: session.url.path).sorted() == names)
        }
    }

    @Test("an unscoped detached test cannot resolve the person's transcript library")
    func unscopedTestsStayOutsideUserLibrary() async {
        let directory = await Task.detached { TranscriptStore.sessionsDir }.value
        #expect(directory.path.hasPrefix(FileManager.default.temporaryDirectory.path))
        #expect(directory != TranscriptStore.root.appendingPathComponent("Sessions"))
    }
    @Test("library cache keys include the session path, not just its timestamp name")
    func libraryRootsDoNotShareCachedSessions() async throws {
        try await withTemporaryLibrary { _ in
            let segments = [Segment(i: 0, t0: 0, t1: 1, text: "Hello", loc: "en", tr: nil, trLoc: nil, words: nil)]
            let started = Date(timeIntervalSince1970: 1_000)
            let first = try TranscriptStore.saveSession(segments, locale: "en", translateTo: nil, startedAt: started)
            let firstMeta = first.url.appendingPathComponent("meta.json")
            try FileManager.default.setAttributes([.modificationDate: started], ofItemAtPath: firstMeta.path)
            #expect(TranscriptStore.list().first?.url == first.url)
            try await withTemporaryLibrary { _ in
                let second = try TranscriptStore.saveSession(segments, locale: "en", translateTo: nil, startedAt: started)
                let secondMeta = second.url.appendingPathComponent("meta.json")
                try Data(contentsOf: firstMeta).write(to: secondMeta)
                try FileManager.default.setAttributes([.modificationDate: started], ofItemAtPath: secondMeta.path)
                #expect(TranscriptStore.list().first?.url == second.url)
            }
            #expect(TranscriptStore.list().first?.url == first.url)
        }
    }
    @Test("late speaker labels patch their original session and survive export/reopening")
    func lateSpeakerPatches() async throws {
        try await withTemporaryLibrary { _ in
            let store = TranscriptStore()
            try await store.begin(locale: "en", translateTo: "de")
            let recorded = try #require(try await store.append(chunk("Hello", 0, 1), locale: "en", translation: nil, translateTo: nil))
            try await store.end()
            let first = try #require(TranscriptStore.list().first { $0.url == recorded.session })
            try await store.begin(locale: "en", translateTo: nil)
            try await store.append(chunk("New session", 0, 1), locale: "en", translation: nil, translateTo: nil)
            try await store.appendSpeaker(.init(speaker: "voice-2", overlapping: false), to: recorded)
            try await store.appendTranslation("Hallo", to: recorded, target: "de")
            let lines = TranscriptStore.segments(of: first)
            #expect(lines.first?.speaker == "voice-2")
            #expect(lines.first?.tr == "Hallo")
            #expect(Export.txt(lines).contains("[Speaker 2] Hello"))
            #expect(first.meta.lineCount == 1)
            try await store.appendSpeaker(.init(speaker: nil, overlapping: true), to: recorded)
            #expect(TranscriptStore.segments(of: first).first?.overlappingSpeech == true)
            #expect(TranscriptStore.segments(of: first).first?.speaker == nil)
            try await store.end()
            let second = try #require(TranscriptStore.list().first { $0.url != recorded.session })
            #expect(TranscriptStore.segments(of: second).first?.speaker == nil)
        }
    }
    @Test("original rows survive pending translation and patches target the original closed session")
    func independentTranslationPatches() async throws {
        try await withTemporaryLibrary { _ in
            let store = TranscriptStore()
            try await store.begin(locale: "de", translateTo: "en")
            let first = try #require(try await store.append(chunk("Erste Zeile", 0, 1), locale: "de", translation: nil, translateTo: nil))
            try await store.end()
            let old = try #require(TranscriptStore.list().first { $0.url == first.session })
            #expect(TranscriptStore.segments(of: old).map(\.text) == ["Erste Zeile"])
            try await store.begin(locale: "de", translateTo: "fr")
            let next = try #require(try await store.append(chunk("Neue Sitzung", 0, 1), locale: "de", translation: nil, translateTo: nil))
            try await store.appendTranslation("First line", to: first, target: "en")
            #expect(TranscriptStore.segments(of: old).map(\.tr) == ["First line"])
            try await store.end()
            let latest = try #require(TranscriptStore.list().first { $0.url == next.session })
            #expect(TranscriptStore.segments(of: latest).map(\.tr) == [nil])
            #expect(latest.meta.lineCount == 1)
            #expect(Export.srt(TranscriptStore.segments(of: old)).contains("First line"))
        }
    }

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
    func saveSessionRoundTrip() async throws {
        try await TranscriptTestLibrary.withTemporaryDirectory { _ in
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
            let disabled = TranscriptStore.deleteOlderThan(days: 0)
            #expect(disabled.deleted == 0 && disabled.failed == 0)
            #expect(TranscriptStore.list().count == 3)

            #expect(TranscriptStore.sessionsOlderThan(days: 30).map(\.id) == [old.id])
            #expect(TranscriptStore.isExpired(old, days: 30))
            #expect(!TranscriptStore.isExpired(recent, days: 30))
            #expect(TranscriptStore.isExpired(old, days: 0) == false)

            // Age from the session's own start date, not the directory's mtime.
            let export = old.url.appendingPathComponent("sAiity-export.srt")
            try Data().write(to: export)
            #expect(TranscriptStore.sessionsOlderThan(days: 30).map(\.id) == [old.id])

            let expired = TranscriptStore.deleteOlderThan(days: 30)
            #expect(expired.deleted == 1 && expired.failed == 0)
            #expect(!FileManager.default.fileExists(atPath: old.url.path))
            #expect(TranscriptStore.list().map(\.id) == [future.id, recent.id].sorted(by: >))
            // And it is idempotent: the second sweep finds nothing to do.
            let repeated = TranscriptStore.deleteOlderThan(days: 30)
            #expect(repeated.deleted == 0 && repeated.failed == 0)

            let remaining = TranscriptStore.deleteAll()
            #expect(remaining.deleted == 2 && remaining.failed == 0)
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

            #expect(TranscriptStore.delete(session))
            #expect(TranscriptStore.list().isEmpty, "a deleted session stayed in the listing")
            #expect(!FileManager.default.fileExists(atPath: session.url.path))
            #expect(TranscriptStore.segments(of: session).isEmpty)
        }
    }

    @Test("failed session removal preserves the cached transcript")
    func failedDeletionKeepsCachedTranscript() async throws {
        try await withTemporaryLibrary { _ in
            let session = try TranscriptStore.saveSession([Segment(i: 0, t0: 0, t1: 1, text: "keep this", loc: "en", tr: nil, trLoc: nil, words: nil)], locale: "en", translateTo: nil)
            let file = session.url.appendingPathComponent("segments.jsonl")
            let original = try Data(contentsOf: file)
            let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
            let stamp = SegmentCache.Stamp(modified: try #require(attributes[.modificationDate] as? Date), size: original.count)
            #expect(TranscriptStore.segments(of: session).first?.text == "keep this")
            try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: session.url.path)
            defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: session.url.path) }
            #expect(!TranscriptStore.delete(session))
            #expect(try Data(contentsOf: file) == original)
            #expect(SegmentCache.shared.value(for: file.path, stamp: stamp)?.first?.text == "keep this")
        }
    }

    @Test("aggregate deletion reports actual successes and failures")
    func deletionCountsOnlySuccessfulRemovals() async throws {
        try await withTemporaryLibrary { _ in
            let segments = [Segment(i: 0, t0: 0, t1: 1, text: "keep this", loc: "en", tr: nil, trLoc: nil, words: nil)]
            let protected = try TranscriptStore.saveSession(segments, locale: "en", translateTo: nil)
            let removable = try TranscriptStore.saveSession(segments, locale: "en", translateTo: nil)
            let file = protected.url.appendingPathComponent("segments.jsonl")
            let original = try Data(contentsOf: file)
            try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: protected.url.path)
            defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: protected.url.path) }
            let result = TranscriptStore.deleteAll()
            #expect(result.deleted == 1 && result.failed == 1)
            #expect(!FileManager.default.fileExists(atPath: removable.url.path))
            #expect(try Data(contentsOf: file) == original)
            #expect(!TranscriptStore.delete(removable), "an absent session is not a successful removal")
        }
    }

    @Test("publication preserves latest metadata, summaries, exports and private permissions")
    func publicationPreservesSessionFiles() async throws {
        try await withTemporaryLibrary { _ in
            let originalSegment = Segment(i: 0, t0: 0, t1: 1, text: "hello", loc: "en", tr: nil, trLoc: nil, words: nil,
                                          turn: true, speaker: "voice-2", overlappingSpeech: true)
            let session = try TranscriptStore.saveSession([originalSegment], locale: "en", translateTo: nil)
            let file = session.url.appendingPathComponent("segments.jsonl")
            let source = try Data(contentsOf: file)
            let summary = session.url.appendingPathComponent("summary.json")
            let export = session.url.appendingPathComponent("transcript.md")
            let kept = Data("unchanged artifact".utf8)
            try kept.write(to: summary)
            try kept.write(to: export)
            var latest = session.meta
            latest.lineCount = 42
            latest.endedAt = Date(timeIntervalSince1970: 1_700_000_000)
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            try encoder.encode(latest).write(to: session.url.appendingPathComponent("meta.json"), options: .atomic)
            var translated = originalSegment
            translated.tr = "hallo"
            translated.trLoc = "de"
            try await TranscriptStore.shared.publishRetranslation([translated], to: session, source: source, target: "de")
            let stored = try #require(TranscriptStore.segments(of: session).first)
            #expect(stored.text == "hello" && stored.tr == "hallo" && stored.trLoc == "de")
            #expect(stored.turn == true && stored.speaker == "voice-2" && stored.overlappingSpeech == true)
            let metadata = try #require(TranscriptStore.list().first).meta
            #expect(metadata.lineCount == 42 && metadata.endedAt == latest.endedAt && metadata.translateTo == "de")
            #expect(try Data(contentsOf: summary) == kept)
            #expect(try Data(contentsOf: export) == kept)
            for url in [file, session.url.appendingPathComponent("meta.json")] {
                let permissions = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber
                #expect(permissions?.intValue == 0o600)
            }
        }
    }

    @Test("publication and deletion reject missing, nested and symlinked library targets")
    func mutationIsConfinedToLibrary() async throws {
        try await withTemporaryLibrary { root in
            let segments = [Segment(i: 0, t0: 0, t1: 1, text: "private", loc: "en", tr: nil, trLoc: nil, words: nil)]
            let saved = try TranscriptStore.saveSession(segments, locale: "en", translateTo: nil)
            let source = try Data(contentsOf: saved.url.appendingPathComponent("segments.jsonl"))
            let nested = root.appendingPathComponent("outside/nested", isDirectory: true)
            try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
            try source.write(to: nested.appendingPathComponent("segments.jsonl"))
            try Data(contentsOf: saved.url.appendingPathComponent("meta.json")).write(to: nested.appendingPathComponent("meta.json"))
            let link = root.appendingPathComponent("alias", isDirectory: true)
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: nested)
            let missing = root.appendingPathComponent("missing", isDirectory: true)
            for url in [nested, link, missing] {
                let invalid = SessionRef(id: url.lastPathComponent, url: url, meta: saved.meta)
                await #expect(throws: (any Error).self) {
                    try await TranscriptStore.shared.publishRetranslation(segments, to: invalid, source: source, target: "de")
                }
                #expect(!TranscriptStore.delete(invalid))
            }
            #expect(try Data(contentsOf: nested.appendingPathComponent("segments.jsonl")) == source)
            #expect(try Data(contentsOf: saved.url.appendingPathComponent("segments.jsonl")) == source)
            // A direct session with a symlinked spoken file is unsafe too.
            let spoken = saved.url.appendingPathComponent("segments.jsonl")
            try FileManager.default.removeItem(at: spoken)
            try FileManager.default.createSymbolicLink(at: spoken, withDestinationURL: nested.appendingPathComponent("segments.jsonl"))
            await #expect(throws: (any Error).self) {
                try await TranscriptStore.shared.publishRetranslation(segments, to: saved, source: source, target: "de")
            }
            #expect(try Data(contentsOf: nested.appendingPathComponent("segments.jsonl")) == source)
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
            let result = TranscriptStore.deleteOlderThan(days: 1)
            #expect(result.deleted == 0 && result.failed == 0)
            #expect(FileManager.default.fileExists(atPath: broken.path))
            #expect(TranscriptStore.list().map(\.id) == [good.id])
        }
    }
}
