import Foundation

/// A single-file download with real byte-level progress and a replace that
/// cannot leave the user with nothing.
///
/// The previous Qwen download used `URLSession.shared.download(from:)`, which
/// reports no progress at all — so a 2.7 GB fetch showed an indeterminate
/// spinner — and then did `removeItem(existing)` followed by `moveItem(new)`,
/// which destroys a working model if the move fails.
///
/// Counting bytes via `URLSession.bytes(for:)` would give progress but at the
/// cost of one `await` iteration per byte; at these sizes the loop, not the
/// network, becomes the bottleneck. A download delegate keeps the efficient
/// file-backed transfer and reports progress from the transfer itself.
enum FileDownloader {

    static func download(from url: URL,
                         to destination: URL,
                         expectedBytes: Int64? = nil,
                         progress: @escaping ProgressSink) async throws {
        let fm = FileManager.default
        try fm.createDirectory(at: destination.deletingLastPathComponent(),
                               withIntermediateDirectories: true)

        let part = destination.appendingPathExtension("part")
        try? fm.removeItem(at: part)

        let delegate = ProgressDelegate(sink: progress, expected: expectedBytes)
        let session = URLSession(configuration: .default)
        defer { session.finishTasksAndInvalidate() }

        let (tmp, response) = try await session.download(from: url, delegate: delegate)

        // Validate BEFORE touching the destination. The old code checked the
        // status only after the body was already on disk.
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            try? fm.removeItem(at: tmp)
            throw TranslationEngineError.notAvailable(
                String(localized: "Download failed (HTTP \(http.statusCode)) for \(destination.lastPathComponent)."))
        }

        do {
            try fm.moveItem(at: tmp, to: part)
            if fm.fileExists(atPath: destination.path) {
                // Atomic swap: the old file stays intact until the new one is in
                // place, so an interrupted replace still leaves a usable model.
                _ = try fm.replaceItemAt(destination, withItemAt: part)
            } else {
                try fm.moveItem(at: part, to: destination)
            }
        } catch {
            try? fm.removeItem(at: part)
            throw error
        }
        progress(DownloadProgress(fraction: 1, note: String(localized: "Done.")))
    }

    /// Remove leftovers from an interrupted download. Called at launch, because
    /// nothing else ever cleans these up.
    static func sweepPartials(in root: URL) {
        guard let e = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else {
            return
        }
        for case let f as URL in e where f.pathExtension == "part" {
            try? FileManager.default.removeItem(at: f)
        }
    }
}

/// Delegate callbacks arrive on the session queue, not the main actor, so the
/// sink must be `@Sendable` and is throttled here rather than flooding whatever
/// it hops to — these fire per packet.
private final class ProgressDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let sink: ProgressSink
    private let expected: Int64?
    private let lock = NSLock()
    private var lastEmit = Date.distantPast
    private var lastBytes: Int64 = 0

    init(sink: @escaping ProgressSink, expected: Int64?) {
        self.sink = sink
        self.expected = expected
    }

    func urlSession(_ session: URLSession,
                    downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        let now = Date()
        let shouldEmit: Bool = lock.withLock {
            guard now.timeIntervalSince(lastEmit) >= 0.2 || totalBytesWritten - lastBytes >= 4 << 20 else {
                return false
            }
            lastEmit = now
            lastBytes = totalBytesWritten
            return true
        }
        guard shouldEmit else { return }

        // A server that sends no Content-Length reports -1 here; fall back to
        // the size we already know from the catalogue rather than showing a bar
        // that never moves.
        let total = totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite : (expected ?? -1)
        let fraction = total > 0 ? min(1, Double(totalBytesWritten) / Double(total)) : nil
        sink(DownloadProgress(fraction: fraction,
                              note: String(localized: "Downloading…"),
                              completed: totalBytesWritten,
                              total: total > 0 ? total : nil))
    }

    func urlSession(_ session: URLSession,
                    downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        // The async `download(from:delegate:)` hands us the file; nothing to do.
    }
}
