import AppKit
import Foundation

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
    /// A turn BREAK, not a speaker id — the honest subset of diarization.
    /// True when ≥2 s of audio-clock silence preceded this line: a gap that
    /// long usually means the floor changed hands, and saying "a new turn
    /// starts here" is defensible where naming who took it would be
    /// invention. Optional so sessions written before the field decode
    /// unchanged.
    var turn: Bool? = nil
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
    static let shared = TranscriptStore()

    /// `~/Library/Application Support/de.aiity.saiity`
    static var root: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask)[0]
        return base.appendingPathComponent("de.aiity.saiity", isDirectory: true)
    }
    static var sessionsDir: URL { root.appendingPathComponent("Sessions", isDirectory: true) }

    private var handle: FileHandle?
    private var dir: URL?
    private var meta: SessionMeta?
    private var index = 0

    var isRecording: Bool { handle != nil }
    var currentLineCount: Int { index }

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
    func append(_ chunk: TranscriptChunk, locale: String,
                translation: String?, translateTo: String?,
                turn: Bool = false) throws {
        guard let handle else { return }
        let seg = Segment(i: index, t0: chunk.start, t1: chunk.end,
                          text: chunk.text, loc: locale,
                          tr: translation, trLoc: translateTo,
                          words: chunk.words.isEmpty ? nil : chunk.words,
                          turn: turn ? true : nil)
        var data = try JSONEncoder().encode(seg)
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
        guard let names = try? fm.contentsOfDirectory(atPath: sessionsDir.path) else { return [] }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        return names.sorted(by: >).compactMap { name in
            let d = sessionsDir.appendingPathComponent(name, isDirectory: true)
            guard let data = try? Data(contentsOf: d.appendingPathComponent("meta.json")),
                  let m = try? dec.decode(SessionMeta.self, from: data) else { return nil }
            return SessionRef(id: name, url: d, meta: m)
        }
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
        let segs: [Segment] = text.split(separator: "\n").compactMap {
            guard let d = $0.data(using: .utf8) else { return nil }
            return try? dec.decode(Segment.self, from: d)
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

    /// Deletion is real: the directory goes, no tombstone, nothing else refers
    /// to it.
    nonisolated static func delete(_ session: SessionRef) {
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

/// The session list, remembered.
///
/// `TranscriptStore.list()` is one `contentsOfDirectory` plus a read and a JSON
/// decode per session, and the status menu was rebuilding from it on every
/// status change — which during a model download means several times a second,
/// synchronously, on the main actor, for as many sessions as the user has ever
/// recorded.
///
/// The cache slots are `Optional` rather than counts on purpose: `Sessions/`
/// does not exist until the first recording and `list()` returns `[]` for a
/// missing directory, so a cache that read "empty" as "not computed yet" would
/// re-scan forever — on exactly the fresh install where the flood is worst.
///
/// Invalidation only ever assigns nil; it never re-scans. Two of the four
/// invalidation points sit inside the teardown that `stopAsync()` awaits, and a
/// directory scan there would be trading one stall for another.
///
/// Not invalidated on `append`: it rewrites `meta.json` only every twentieth
/// line, so the in-progress session's line count in this list was already
/// approximate before the cache existed. The live counter the user actually
/// reads is `recordingLine`, which is computed fresh on every rebuild.
@MainActor
enum SessionCatalog {
    /// A menu row with its title already rendered, so a rebuild is object
    /// construction and nothing else — no I/O, no DateFormatter.
    struct Row: Sendable { let id: String; let title: String }

    private static var cachedSessions: [SessionRef]?
    private static var cachedRows: [Row]?
    private static var formatter: DateFormatter?

    static func sessions() -> [SessionRef] {
        if let cachedSessions { return cachedSessions }
        let s = TranscriptStore.list()
        cachedSessions = s
        return s
    }

    static func rows(limit: Int) -> [Row] {
        if let cachedRows { return cachedRows }
        let df = formatter ?? {
            let f = DateFormatter()
            f.dateStyle = .medium
            f.timeStyle = .short
            formatter = f
            return f
        }()
        let r = sessions().prefix(limit).map { s -> Row in
            let mins = Int((s.meta.endedAt ?? s.meta.startedAt)
                .timeIntervalSince(s.meta.startedAt) / 60)
            return Row(id: s.id,
                       title: String(localized: "\(df.string(from: s.meta.startedAt)) · \(s.meta.lineCount) lines · \(mins) min"))
        }
        cachedRows = r
        return r
    }

    /// Call after anything that adds, removes or closes a session.
    static func invalidate() {
        cachedSessions = nil
        cachedRows = nil
    }

    /// The rendered titles are locale-dependent; the scan behind them is not.
    static func invalidateRendering() {
        cachedRows = nil
        formatter = nil
    }
}
