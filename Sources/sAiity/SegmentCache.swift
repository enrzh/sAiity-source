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
    /// Insertion order, oldest first — a plain LRU queue.
    private var order: [String] = []
    /// Bounded by BYTES, not entries.
    ///
    /// The first version capped entry count and flushed everything at the
    /// ceiling. That is worse than no cache for exactly the library it was
    /// built for: a search sweeps every session in one pass, so at 401
    /// sessions the pass evicts the whole cache before it finishes and the
    /// next keystroke starts from nothing — a provable 0% hit rate. Evicting
    /// oldest-first keeps most of the pass. A byte budget rather than a count
    /// is because transcripts differ by orders of magnitude: 400 two-line
    /// sessions are nothing, 400 three-hour ones are not.
    private static let maxBytes = 32 << 20     // 32 MB of transcript text
    private var bytes = 0

    /// Rough cost of an entry. Character count is the dominant term and is far
    /// cheaper to compute than anything exact.
    private static func cost(_ segments: [Segment]) -> Int {
        segments.reduce(0) { $0 + $1.text.utf8.count + ($1.tr?.utf8.count ?? 0) + 64 }
    }

    func value(for path: String, stamp: Stamp) -> [Segment]? {
        lock.withLock {
            guard let e = entries[path], e.stamp == stamp else { return nil }
            return e.segments
        }
    }

    func store(_ segments: [Segment], for path: String, stamp: Stamp) {
        let c = Self.cost(segments)
        lock.withLock {
            if let old = entries[path] {
                bytes -= Self.cost(old.segments)
                order.removeAll { $0 == path }
            }
            entries[path] = Entry(stamp: stamp, segments: segments)
            order.append(path)
            bytes += c
            while bytes > Self.maxBytes, let oldest = order.first {
                order.removeFirst()
                if let e = entries.removeValue(forKey: oldest) { bytes -= Self.cost(e.segments) }
            }
        }
    }

    /// Drop one session's entry — used when a specific transcript is deleted
    /// or rewritten, so the whole cache does not have to be thrown away.
    func invalidate(path: String) {
        lock.withLock {
            if let e = entries.removeValue(forKey: path) { bytes -= Self.cost(e.segments) }
            order.removeAll { $0 == path }
        }
    }

    func invalidate() {
        lock.withLock {
            entries.removeAll(keepingCapacity: true)
            order.removeAll(keepingCapacity: true)
            bytes = 0
        }
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

    /// Keep applying the policy while the app runs.
    ///
    /// Sweeping only at launch and on change is a policy that quietly stops
    /// being true: this is a menu-bar app that people leave running for weeks,
    /// and "delete after 7 days" that only acts when you happen to relaunch is
    /// not the promise the setting makes. Six hours is frequent enough that
    /// nothing outlives its age by a meaningful margin, and rare enough to be
    /// free.
    @MainActor
    static func startPeriodicSweep() {
        guard timer == nil else { return }
        let t = Timer.scheduledTimer(withTimeInterval: 6 * 3600, repeats: true) { _ in
            Task { await sweep() }
        }
        t.tolerance = 600      // let the OS coalesce it; nothing here is urgent
        timer = t
    }
    @MainActor private static var timer: Timer?

    /// Apply the policy. Called at launch, on change, and every six hours.
    ///
    /// The listing, the per-session `meta.json` reads, and the `removeItem` per
    /// expired session are file I/O that scales with library size, so they run in
    /// a detached task. Only the cache invalidation afterwards is
    /// main-actor-shaped, and that is a posted notification plus a lock — both
    /// safe from any context. The main actor is suspended, not blocked, while
    /// the detached work runs.
    @MainActor
    @discardableResult
    static func sweep() async -> Int {
        let d = days
        guard d > 0 else { return 0 }
        let n = await Task.detached {
            await TranscriptStore.deleteOlderThan(days: d)
        }.value
        if n > 0 {
            SessionCatalog.invalidate()
            SegmentCache.shared.invalidate()
        }
        return n
    }
}
