import Foundation

/// Parsed transcript lines, kept so searching does not re-read the disk.
///
/// Cross-session search calls `TranscriptStore.segments(of:)` for every saved
/// session on every keystroke. Each call was a full file read plus a JSON
/// decode per line — imperceptible with five sessions, and a growing stall
/// once there are hundreds, on the main actor, while the user is typing.
///
/// The key is the file's path *and* its modification date and size, so a
/// session still being written, or one whose file changed underneath us (a
/// re-translation rewrites it), is re-read rather than served from a stale
/// entry. That is cheaper than being clever: an `attributesOfItem` stat is
/// microseconds against a read-and-decode of the whole file.
final class SegmentCache: @unchecked Sendable {
    static let shared = SegmentCache()

    struct Stamp: Equatable {
        let modified: Date
        let size: Int
    }

    private struct Entry {
        let stamp: Stamp
        let segments: [Segment]
    }

    private let lock = NSLock()
    private var entries: [String: Entry] = [:]
    /// Bounded so a library of thousands cannot pin every transcript in RAM.
    /// Evicting everything at the ceiling — rather than tracking an LRU — is
    /// deliberate: a search sweeps all sessions in one pass, so the useful
    /// working set is "this pass", and the next keystroke refills what it
    /// needs. Simple, and it cannot leak.
    private static let maxEntries = 400

    func value(for path: String, stamp: Stamp) -> [Segment]? {
        lock.withLock {
            guard let e = entries[path], e.stamp == stamp else { return nil }
            return e.segments
        }
    }

    func store(_ segments: [Segment], for path: String, stamp: Stamp) {
        lock.withLock {
            if entries.count >= Self.maxEntries { entries.removeAll(keepingCapacity: true) }
            entries[path] = Entry(stamp: stamp, segments: segments)
        }
    }

    func invalidate() {
        lock.withLock { entries.removeAll(keepingCapacity: true) }
    }
}

/// How long transcripts are kept.
///
/// The app records durable records of conversations other people were part of
/// and, until this existed, never expired one. Off by default — deleting a
/// user's data on a schedule they did not ask for would be its own kind of
/// wrong — but one setting away.
enum TranscriptRetention {
    static let choices = [0, 7, 30, 90]

    /// Days to keep; 0 means keep everything.
    static var days: Int {
        get { UserDefaults.standard.integer(forKey: "transcriptRetentionDays") }
        set { UserDefaults.standard.set(newValue, forKey: "transcriptRetentionDays") }
    }

    static func label(_ days: Int) -> String {
        days == 0 ? String(localized: "Keep everything")
                  : String(localized: "Delete after \(days) days")
    }

    /// Apply the policy. Called at launch and whenever the setting changes.
    ///
    /// Main-actor because `SessionCatalog` is: the catalogue backs the UI, and
    /// invalidating it from a background context would race the list the
    /// Transcripts page is reading.
    @MainActor
    @discardableResult
    static func sweep() -> Int {
        let d = days
        guard d > 0 else { return 0 }
        let n = TranscriptStore.deleteOlderThan(days: d)
        if n > 0 {
            SessionCatalog.invalidate()
            SegmentCache.shared.invalidate()
        }
        return n
    }
}
