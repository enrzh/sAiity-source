import AppKit
import Foundation

extension Notification.Name {
    /// Posted after the saved-session catalog changes so an open Settings
    /// window can refresh only the transcript list, without coupling the
    /// transcript store to a particular view.
    static let saiityTranscriptLibraryChanged = Notification.Name("sAiityTranscriptLibraryChanged")
}

private struct TranscriptFileStamp: Equatable {
    let modified: Date
    let size: Int
}

#if SAIITY_TEST_HOOKS
/// A disposable library for one test, addressed per task.
///
/// The retention policy deletes real directories and takes its age from each
/// session's own start date, so a test that wants to prove the policy deletes
/// an old session has to *make* an old one — which against the real library
/// means calling the sweep on a developer's or a user's actual transcripts. That
/// is not a risk a test may take: the oldest thing in someone's library is
/// usually the only record of a conversation nobody else kept.
///
/// A task local rather than a stored property, because several suites write
/// transcripts and they run in parallel: a process-wide switch hands whichever
/// suite set it last the *other* suite's directory, and the failures that
/// produces look like transcript corruption.
enum TranscriptTestLibrary {
    private static let scopedDirectory = TaskLocal<URL?>(wrappedValue: nil)

    /// The library this task is using, or nil for the real one.
    static var sessionsDir: URL? { scopedDirectory.wrappedValue }

    /// Create a throwaway library, run `body` against it, and remove it.
    static func withTemporaryDirectory<T>(
        _ body: (URL) async throws -> T) async throws -> T {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("saiity-transcript-tests-\(UUID().uuidString)",
                                    isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        return try await scopedDirectory.withValue(dir) { try await body(dir) }
    }
}
#endif

/// Metadata decoding is cheap for a small library, but the settings window can
/// ask for the same catalog repeatedly while a recording is being closed. Keep
/// decoded `meta.json` values keyed by a file stamp so a forced refresh still
/// notices edits without rereading unchanged files.
private final class TranscriptListCache: @unchecked Sendable {
    struct Entry {
        let stamp: TranscriptFileStamp
        let session: SessionRef
    }

    private let lock = NSLock()
    private var entries: [String: Entry] = [:]

    func snapshot(names: [String], load: (String) -> SessionRef?) -> [SessionRef] {
        lock.lock()
        defer { lock.unlock() }

        var result: [SessionRef] = []
        var currentKeys = Set<String>()
        result.reserveCapacity(names.count)
        for name in names {
            let url = TranscriptStore.sessionsDir.appendingPathComponent(name, isDirectory: true)
                .appendingPathComponent("meta.json")
            let key = url.deletingLastPathComponent().path
            currentKeys.insert(key)
            let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
            guard let attributes,
                  let modified = attributes[.modificationDate] as? Date else {
                entries.removeValue(forKey: key)
                continue
            }
            let size = (attributes[.size] as? NSNumber)?.intValue ?? 0
            let stamp = TranscriptFileStamp(modified: modified, size: size)
            if let cached = entries[key], cached.stamp == stamp {
                result.append(cached.session)
            } else if let session = load(name) {
                entries[key] = Entry(stamp: stamp, session: session)
                result.append(session)
            } else {
                entries.removeValue(forKey: key)
            }
        }

        entries = entries.filter { currentKeys.contains($0.key) }
        return result
    }

    func remove(_ name: String) {
        lock.lock()
        entries.removeValue(forKey: TranscriptStore.sessionsDir.appendingPathComponent(name).path)
        lock.unlock()
    }

    func removeAll() {
        lock.lock()
        entries.removeAll(keepingCapacity: true)
        lock.unlock()
    }
}

/// One committed line of a meeting.
struct Segment: Codable, Sendable {
    var i: Int
    var t0: Double            // seconds from session start
    var t1: Double
    var text: String
    var loc: String           // BCP-47 source locale
    var tr: String?           // translation, when enabled
    var trLoc: String?
    var words: [TimedWord]?
    /// A turn break in the audio clock. Optional so sessions written before
    /// the field decode unchanged.
    var turn: Bool? = nil
    /// Anonymous session-local voice id. Old speaker-* metadata still round-
    /// trips, but only new voice-* evidence is displayed as speaker labels.
    var speaker: String? = nil
    var overlappingSpeech: Bool? = nil

    var speakerLabel: String? {
        CaptionSpeakerAnnotation.label(speaker: speaker, overlapping: overlappingSpeech == true)
    }
}

struct SessionMeta: Codable, Sendable {
    var v = 1                 // schema version — cheap now, priceless later
    var id: String
    var startedAt: Date
    var endedAt: Date?
    var locale: String
    var translateTo: String?
    var lineCount: Int = 0
}

/// A saved session on disk, as listed in the menu.
struct SessionRef: Sendable, Identifiable {
    let id: String
    let url: URL
    let meta: SessionMeta
}

/// Writes meeting transcripts to disk, one directory per Start→Stop cycle.
///
/// Two decisions worth stating:
///   - **Finals only.** Volatile results are cumulative *since the last final* —
///     one observed volatile spanned four sentences and 15 seconds. Persisting
///     them would duplicate whole paragraphs. Consecutive finals are already
///     non-overlapping and monotonic, so appending them needs no de-duplication.
///   - **One session per Start→Stop.** The analyzer's audio clock restarts at
///     zero each time, so carrying an offset across restarts would be a silent
///     correctness tax for very little gain.
///
/// Recording is opt-in and off by default: live captions are ephemeral, a
/// transcript is a durable record of a conversation other people were part of.
actor TranscriptStore {
    struct RecordedSegment: Sendable {
        let session: URL
        let index: Int
    }

    private struct TranslationUpdate: Codable {
        let translationFor: Int
        let tr: String
        let trLoc: String
    }
    private struct SpeakerUpdate: Codable {
        let speakerFor: Int
        let speaker: String?
        let overlappingSpeech: Bool
    }
    static let shared = TranscriptStore()
    private static let listCache = TranscriptListCache()

    /// `~/Library/Application Support/de.aiity.saiity`
    static var root: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask)[0]
        return base.appendingPathComponent("de.aiity.saiity", isDirectory: true)
    }

    #if SAIITY_TEST_HOOKS
    /// Process-wide variant of `TranscriptTestLibrary.sessionsDir`, for a test
    /// that cannot wrap its work in the task-local form. A stored switch shared
    /// by suites that run in parallel is a race, so prefer the task local; this
    /// exists because the quiet-shutdown suite needs the switch to cover work it
    /// dispatches itself.
    nonisolated(unsafe) static var sessionsDirOverride: URL?
    #endif
    static var sessionsDir: URL {
        #if SAIITY_TEST_HOOKS
        if let scoped = TranscriptTestLibrary.sessionsDir { return scoped }
        if let processWide = sessionsDirOverride { return processWide }
        #endif
        return root.appendingPathComponent("Sessions", isDirectory: true)
    }

    private var handle: FileHandle?
    private var dir: URL?
    private var meta: SessionMeta?
    private var index = 0
    /// One encoder for the life of the store. An actor-isolated stored property
    /// is the only kind that is safe to reuse: no other thread can touch it.
    private let encoder = JSONEncoder()

    var isRecording: Bool { handle != nil }
    var currentLineCount: Int { index }

    #if SAIITY_TEST_HOOKS
    /// The directory of the session being written, straight from the store. A
    /// test must not reach this by listing `sessionsDir` and taking `[0]` — that
    /// is a different answer the moment anything else writes into the same
    /// directory.
    var currentSessionRefForTests: URL? { dir }
    #endif

    // MARK: - Lifecycle

    func begin(locale: String, translateTo: String?) throws {
        try end()

        // POSIX locale is mandatory: otherwise a user on a non-Gregorian
        // calendar gets directory names that do not sort chronologically.
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.dateFormat = "yyyy-MM-dd'T'HHmmss"
        let started = Date()
        var id = fmt.string(from: started)

        var d = Self.sessionsDir.appendingPathComponent(id, isDirectory: true)
        var n = 2
        while FileManager.default.fileExists(atPath: d.path) {
            id = "\(fmt.string(from: started))-\(n)"
            d = Self.sessionsDir.appendingPathComponent(id, isDirectory: true)
            n += 1
        }
        // 0700 applies to every level created, not just the leaf.
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])

        let segs = d.appendingPathComponent("segments.jsonl")
        FileManager.default.createFile(atPath: segs.path, contents: nil,
                                       attributes: [.posixPermissions: 0o600])
        handle = try FileHandle(forWritingTo: segs)
        dir = d
        index = 0
        meta = SessionMeta(id: id, startedAt: started, endedAt: nil,
                           locale: locale, translateTo: translateTo)
        try writeMeta()
    }

    /// Appends one committed line. O(1) — a single write to a long-lived handle,
    /// so a two-hour meeting costs nothing per line.
    @discardableResult
    func append(_ chunk: TranscriptChunk, locale: String,
                translation: String?, translateTo: String?,
                turn: Bool = false) throws -> RecordedSegment? {
        guard let handle, let directory = dir else { return nil }
        let recorded = RecordedSegment(session: directory, index: index)
        let seg = Segment(i: index, t0: chunk.start, t1: chunk.end,
                          text: chunk.text, loc: locale,
                          tr: translation, trLoc: translateTo,
                          words: chunk.words.isEmpty ? nil : chunk.words,
                          turn: turn ? true : nil)
        var data = try encoder.encode(seg)
        data.append(0x0A)
        do {
            try handle.write(contentsOf: data)
        } catch {
            failRecording()
            throw error
        }
        index += 1
        meta?.lineCount = index
        // Keep the session listing roughly honest even if the app never gets a
        // clean shutdown; a full rewrite per line would be wasteful.
        if index % 20 == 0 {
            do {
                try writeMeta()
            } catch {
                failRecording()
                throw error
            }
        }
        return recorded
    }

    /// Source rows are already durable. A late translation only appends a patch
    /// for that exact session and row, including after recording has closed.
    func appendTranslation(_ text: String, to recorded: RecordedSegment, target: String) throws {
        try appendUpdate(TranslationUpdate(translationFor: recorded.index, tr: text, trLoc: target), to: recorded)
    }

    func appendSpeaker(_ annotation: CaptionSpeakerAnnotation, to recorded: RecordedSegment) throws {
        try appendUpdate(SpeakerUpdate(speakerFor: recorded.index, speaker: annotation.speaker,
                                      overlappingSpeech: annotation.overlapping), to: recorded)
    }

    private func appendUpdate<T: Encodable>(_ update: T, to recorded: RecordedSegment) throws {
        let file = recorded.session.appendingPathComponent("segments.jsonl")
        guard recorded.session.deletingLastPathComponent().standardizedFileURL == Self.sessionsDir.standardizedFileURL,
              FileManager.default.fileExists(atPath: file.path) else { return }
        var data = try encoder.encode(update)
        data.append(0x0A)
        if dir == recorded.session, let handle {
            try handle.write(contentsOf: data)
        } else {
            let patch = try FileHandle(forWritingTo: file)
            defer { try? patch.close() }
            try patch.seekToEnd()
            try patch.write(contentsOf: data)
        }
        NotificationCenter.default.post(name: .saiityTranscriptLibraryChanged, object: nil)
    }

    func end() throws {
        guard let activeHandle = handle else { return }
        handle = nil
        var failure: Error?
        do { try activeHandle.close() } catch { failure = error }
        handle = nil
        meta?.endedAt = Date()
        do { try writeMeta() } catch { failure = failure ?? error }
        dir = nil
        meta = nil
        if let failure { throw failure }
    }

    /// A failed append must not leave the UI believing recording continues.
    /// Close the handle and finish the metadata best-effort so the lines that
    /// did reach disk remain a readable, bounded session.
    private func failRecording() {
        try? handle?.close()
        handle = nil
        meta?.endedAt = Date()
        try? writeMeta()
        dir = nil
        meta = nil
    }

    /// meta.json is small and rewritten rarely, so an atomic replace is cheap —
    /// and a torn write here would cost the whole session listing.
    private func writeMeta() throws {
        guard let dir, let meta else { return }
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        enc.dateEncodingStrategy = .iso8601
        let data = try enc.encode(meta)
        try data.write(to: dir.appendingPathComponent("meta.json"), options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600],
                                               ofItemAtPath: dir.appendingPathComponent("meta.json").path)
    }

    // MARK: - Reading back

    nonisolated static func list() -> [SessionRef] {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: sessionsDir.path) else {
            listCache.removeAll()
            return []
        }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        let sessionsDirectory = sessionsDir
        return listCache.snapshot(names: names.sorted(by: >)) { name in
            let d = sessionsDirectory.appendingPathComponent(name, isDirectory: true)
            guard let data = try? Data(contentsOf: d.appendingPathComponent("meta.json")),
                  let m = try? dec.decode(SessionMeta.self, from: data) else { return nil }
            return SessionRef(id: name, url: d, meta: m)
        }
    }

    /// Save an in-memory transcript as a normal library session. This is used
    /// by the subtitle bubble's Save action, so saving does not create an
    /// export file or require persistent recording to have been enabled.
    nonisolated static func saveSession(_ segments: [Segment], locale: String,
                                        translateTo: String?, startedAt: Date = Date()) throws -> SessionRef {
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.dateFormat = "yyyy-MM-dd'T'HHmmss"
        let stamp = fmt.string(from: startedAt)
        var id = stamp
        var directory = sessionsDir.appendingPathComponent(id, isDirectory: true)
        var suffix = 2
        while FileManager.default.fileExists(atPath: directory.path) {
            id = "\(stamp)-\(suffix)"
            directory = sessionsDir.appendingPathComponent(id, isDirectory: true)
            suffix += 1
        }

        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let meta = SessionMeta(id: id, startedAt: startedAt, endedAt: Date(),
                               locale: locale, translateTo: translateTo,
                               lineCount: segments.count)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(meta).write(to: directory.appendingPathComponent("meta.json"),
                                       options: .atomic)

        var lines = Data()
        let segmentEncoder = JSONEncoder()
        for segment in segments {
            lines.append(try segmentEncoder.encode(segment))
            lines.append(0x0A)
        }
        try lines.write(to: directory.appendingPathComponent("segments.jsonl"), options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600],
                                               ofItemAtPath: directory.appendingPathComponent("meta.json").path)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600],
                                               ofItemAtPath: directory.appendingPathComponent("segments.jsonl").path)
        listCache.removeAll()
        return SessionRef(id: id, url: directory, meta: meta)
    }



    nonisolated static func segments(of session: SessionRef) -> [Segment] {
        let url = session.url.appendingPathComponent("segments.jsonl")
        // Cached on (path, mtime, size). Searching across sessions calls this
        // for every session on every keystroke, and each call was a full file
        // read plus a JSON decode per line — fine for a handful of sessions,
        // quadratic-feeling by a few hundred. The stamp means an edited or
        // still-recording file is re-read rather than served stale.
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        let stamp = SegmentCache.Stamp(
            modified: (attrs?[.modificationDate] as? Date) ?? .distantPast,
            size: (attrs?[.size] as? Int) ?? 0)
        if let hit = SegmentCache.shared.value(for: url.path, stamp: stamp) { return hit }

        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        let dec = JSONDecoder()
        var segs: [Segment] = []
        var positions: [Int: Int] = [:]
        for line in text.split(separator: "\n") {
            guard let data = line.data(using: .utf8) else { continue }
            if let segment = try? dec.decode(Segment.self, from: data) {
                positions[segment.i] = segs.count
                segs.append(segment)
            } else if let update = try? dec.decode(TranslationUpdate.self, from: data),
                      let position = positions[update.translationFor] {
                segs[position].tr = update.tr
                segs[position].trLoc = update.trLoc
            } else if let update = try? dec.decode(SpeakerUpdate.self, from: data),
                      let position = positions[update.speakerFor] {
                segs[position].speaker = update.speaker
                segs[position].overlappingSpeech = update.overlappingSpeech ? true : nil
            }
        }
        SegmentCache.shared.store(segs, for: url.path, stamp: stamp)
        return segs
    }

    /// Delete sessions older than `days`. Returns how many went.
    ///
    /// A transcript is a durable record of a conversation other people were
    /// part of, and until now nothing ever expired one. Age is taken from the
    /// session's own start date rather than the file's mtime, which an export
    /// written into the session directory would otherwise reset.
    @discardableResult
    nonisolated static func deleteOlderThan(days: Int) -> Int {
        let doomed = sessionsOlderThan(days: days)
        for s in doomed { delete(s) }
        if !doomed.isEmpty {
            NSLog("sAiity retention: removed \(doomed.count) session(s) older than \(days) days")
        }
        return doomed.count
    }

    /// What a retention setting WOULD delete. Separated from the deletion so
    /// the UI can name the number before doing it — a count after the fact is
    /// no use for a decision that cannot be undone.
    nonisolated static func sessionsOlderThan(days: Int) -> [SessionRef] {
        guard days > 0 else { return [] }
        let cutoff = Date().addingTimeInterval(-Double(days) * 86_400)
        return list().filter { $0.meta.startedAt < cutoff }
    }

    /// Whether the policy would take this session, on its own dates.
    ///
    /// The predicate `sessionsOlderThan` applies, named once so a caller
    /// checking one session — the settings page counting what "Delete after 30
    /// days" means for the session in front of the user — cannot disagree with
    /// the sweep about it.
    nonisolated static func isExpired(_ session: SessionRef, days: Int) -> Bool {
        guard days > 0 else { return false }
        return session.meta.startedAt < Date().addingTimeInterval(-Double(days) * 86_400)
    }

    /// Deletion is real: the directory goes, no tombstone, nothing else refers
    /// to it.
    nonisolated static func delete(_ session: SessionRef) {
        listCache.remove(session.id)
        // Drop the cached lines with the file. Nothing else would: the stamp
        // check only catches a file that still EXISTS and changed, so a
        // deleted session's text would otherwise sit in memory until the app
        // quit — and be served if a new session ever reused the path.
        SegmentCache.shared.invalidate(
            path: session.url.appendingPathComponent("segments.jsonl").path)
        try? FileManager.default.removeItem(at: session.url)
    }

    nonisolated static func deleteAll() {
        for s in list() { delete(s) }
    }
}

/// Broadcasts "the set of stored sessions changed".
///
/// This used to also be a memo of `TranscriptStore.list()`. The menu no longer
/// lists sessions, so nothing reads the cache and the only work left here is
/// the notification — which matters, because the transcripts page and the
/// retention sweep both listen for it. The name is kept because it reads
/// correctly at every call site and because renaming it would churn four files
/// to say the same thing.
@MainActor
enum SessionCatalog {
    /// Call after anything that adds, removes or closes a session.
    static func invalidate() {
        NotificationCenter.default.post(name: .saiityTranscriptLibraryChanged, object: nil)
    }
}
