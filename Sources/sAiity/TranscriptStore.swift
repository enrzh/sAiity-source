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
struct SessionRef: Sendable {
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
                translation: String?, translateTo: String?) {
        guard let handle else { return }
        let seg = Segment(i: index, t0: chunk.start, t1: chunk.end,
                          text: chunk.text, loc: locale,
                          tr: translation, trLoc: translateTo,
                          words: chunk.words.isEmpty ? nil : chunk.words)
        guard var data = try? JSONEncoder().encode(seg) else { return }
        data.append(0x0A)
        try? handle.write(contentsOf: data)
        index += 1
        meta?.lineCount = index
        // Keep the session listing roughly honest even if the app never gets a
        // clean shutdown; a full rewrite per line would be wasteful.
        if index % 20 == 0 { try? writeMeta() }
    }

    func end() throws {
        guard handle != nil else { return }
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
        guard let text = try? String(contentsOf: session.url.appendingPathComponent("segments.jsonl"),
                                     encoding: .utf8) else { return [] }
        let dec = JSONDecoder()
        return text.split(separator: "\n").compactMap {
            guard let d = $0.data(using: .utf8) else { return nil }
            return try? dec.decode(Segment.self, from: d)
        }
    }

    /// Deletion is real: the directory goes, no tombstone, nothing else refers
    /// to it.
    nonisolated static func delete(_ session: SessionRef) {
        try? FileManager.default.removeItem(at: session.url)
    }

    nonisolated static func deleteAll() {
        for s in list() { delete(s) }
    }
}
