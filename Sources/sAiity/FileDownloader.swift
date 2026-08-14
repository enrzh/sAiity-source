import Foundation

/// A single-file download with real byte-level progress, resume for
/// interrupted transfers, and a replace that cannot leave the user with
/// nothing.
///
/// The previous Qwen download used `URLSession.shared.download(from:)`, which
/// reports no progress at all — so a 2.7 GB fetch showed an indeterminate
/// spinner — and then did `removeItem(existing)` followed by `moveItem(new)`,
/// which destroys a working model if the move fails.
///
/// Counting bytes via `URLSession.bytes(for:)` would give progress but at the
/// cost of one `await` iteration per byte; at these sizes the loop, not the
/// network, becomes the bottleneck. A data-task delegate keeps the transfer
/// chunked and streams straight into `<destination>.part`.
///
/// ## Resume
///
/// The `.part` file, together with the HTTP validator stored beside it, IS the
/// resume state: it survives cancellation, a dropped connection, and a quit.
/// The next attempt asks the server for `bytes=<size>-` with `If-Range`, so a
/// Wi-Fi drop at 95% of a multi-GB GGUF costs the remaining 5%, not a restart
/// from byte zero — which is exactly the download class where starting over
/// hurts most. A server that answers 200 anyway (file changed, or no range
/// support) restarts cleanly; a partial with no validator is never resumed,
/// because nothing proves which bytes it holds.
enum FileDownloader {

    /// ASCII "GGUF" — the four bytes every llama.cpp model file starts with.
    /// Callers fetching GGUFs pass this so an HTML page saved by a pasted
    /// model-page URL fails at download time with a usable message, instead of
    /// minutes later as an opaque llama.cpp load error.
    static let ggufMagic = Data("GGUF".utf8)

    static func download(from url: URL,
                         to destination: URL,
                         expectedBytes: Int64? = nil,
                         requireMagic: Data? = nil,
                         progress: @escaping ProgressSink) async throws {
        try await attempt(from: url, to: destination, expectedBytes: expectedBytes,
                          requireMagic: requireMagic, retried: false,
                          progress: progress)
    }

    private static func attempt(from url: URL,
                                to destination: URL,
                                expectedBytes: Int64?,
                                requireMagic: Data?,
                                retried: Bool,
                                progress: @escaping ProgressSink) async throws {
        let fm = FileManager.default
        try fm.createDirectory(at: destination.deletingLastPathComponent(),
                               withIntermediateDirectories: true)

        let part = destination.appendingPathExtension("part")
        let marker = validatorMarker(for: part)

        // Resume only with a validator: a `.part` with no record of WHICH
        // file's bytes it holds could be silently glued to a newer file's
        // tail. `If-Range` makes the server the judge — validator still
        // current gets 206 and the remainder, anything else gets 200 and a
        // clean restart.
        var request = URLRequest(url: url)
        var offset: Int64 = 0
        if let size = (try? fm.attributesOfItem(atPath: part.path)[.size]) as? Int64,
           size > 0,
           let validator = try? String(contentsOf: marker, encoding: .utf8),
           !validator.isEmpty {
            offset = size
            request.setValue("bytes=\(size)-", forHTTPHeaderField: "Range")
            request.setValue(validator, forHTTPHeaderField: "If-Range")
        } else {
            try? fm.removeItem(at: part)
            try? fm.removeItem(at: marker)
        }
        if !fm.fileExists(atPath: part.path) {
            fm.createFile(atPath: part.path, contents: nil)
        }

        let session = URLSession(configuration: .default)
        defer { session.finishTasksAndInvalidate() }

        let writer = RangeWriter(part: part, marker: marker, resumeOffset: offset,
                                 sink: progress, expected: expectedBytes)
        do {
            try await writer.run(request, in: session)
        } catch RangeWriter.Failure.rangeNotSatisfiable {
            // The stored offset no longer makes sense to the server. Wipe the
            // partial and start over — once. A server that 416s a fresh
            // no-range request is broken in a way retrying will not fix.
            try? fm.removeItem(at: part)
            try? fm.removeItem(at: marker)
            guard !retried else {
                throw TranslationEngineError.notAvailable(
                    String(localized: "Download failed (HTTP \(416)) for \(destination.lastPathComponent)."))
            }
            return try await attempt(from: url, to: destination,
                                     expectedBytes: expectedBytes,
                                     requireMagic: requireMagic, retried: true,
                                     progress: progress)
        } catch RangeWriter.Failure.io(let underlying) {
            // A local write failure (disk full, most likely) does not make the
            // bytes already fetched wrong — keep the partial so the retry
            // after freeing space resumes instead of re-paying for them.
            throw underlying
        } catch let e as RangeWriter.Failure {
            // Protocol-level failures: whatever landed in the partial is not
            // trustworthy state.
            try? fm.removeItem(at: part)
            try? fm.removeItem(at: marker)
            throw e.userError(for: destination)
        }
        // Network errors and cancellation propagate above — deliberately
        // KEEPING the partial and its validator. That is the resume state.

        // The staged bytes must be the whole file before installing. Without
        // this, a truncated transfer whose connection closed "cleanly" would
        // install and then read as a complete model everywhere isDownloaded
        // checks only existence.
        let size = (try? fm.attributesOfItem(atPath: part.path)[.size]) as? Int64 ?? 0
        if let want = writer.knownTotal ?? expectedBytes, want > 0, size != want {
            try? fm.removeItem(at: part)
            try? fm.removeItem(at: marker)
            throw TranslationEngineError.notAvailable(
                String(localized: "Download of \(destination.lastPathComponent) ended incomplete. Try again."))
        }
        if let magic = requireMagic {
            var head: Data?
            if let h = try? FileHandle(forReadingFrom: part) {
                head = try? h.read(upToCount: magic.count)
                try? h.close()
            }
            if head != magic {
                try? fm.removeItem(at: part)
                try? fm.removeItem(at: marker)
                throw TranslationEngineError.notAvailable(
                    String(localized: "\(destination.lastPathComponent) is not a GGUF model file. Use the direct download link from the model page."))
            }
        }

        do {
            if fm.fileExists(atPath: destination.path) {
                // Atomic swap: the old file stays intact until the new one is in
                // place, so an interrupted replace still leaves a usable model.
                _ = try fm.replaceItemAt(destination, withItemAt: part)
            } else {
                try fm.moveItem(at: part, to: destination)
            }
        } catch {
            try? fm.removeItem(at: part)
            try? fm.removeItem(at: marker)
            throw error
        }
        try? fm.removeItem(at: marker)
        progress(DownloadProgress(fraction: 1, note: String(localized: "Done.")))
    }

    private static func validatorMarker(for part: URL) -> URL {
        part.appendingPathExtension("etag")
    }

    /// Remove ORPHANED leftovers at launch. A `.part` beside its validator
    /// marker is resume state, not garbage — deleting it here is what used to
    /// turn every quit during a multi-GB fetch into a restart from byte zero.
    /// Only partials that cannot be resumed (no validator, so no proof of
    /// which bytes they hold) are swept, plus markers whose partial is gone.
    static func sweepPartials(in root: URL) {
        let fm = FileManager.default
        guard let e = fm.enumerator(at: root, includingPropertiesForKeys: nil) else {
            return
        }
        for case let f as URL in e {
            if f.pathExtension == "part",
               !fm.fileExists(atPath: validatorMarker(for: f).path) {
                try? fm.removeItem(at: f)
            } else if f.lastPathComponent.hasSuffix(".part.etag"),
                      !fm.fileExists(atPath: f.deletingPathExtension().path) {
                try? fm.removeItem(at: f)
            }
        }
    }
}

/// Streams the response body into the `.part` file from the session's serial
/// delegate queue — per chunk, not per byte — and stores the server's
/// validator beside it so the next attempt can prove the partial still
/// matches. Progress is throttled here rather than flooding whatever the sink
/// hops to; the callbacks fire per packet.
private final class RangeWriter: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    enum Failure: Error {
        case badStatus(Int)
        case rangeNotSatisfiable
        case notAFile
        case io(Error)

        func userError(for destination: URL) -> Error {
            switch self {
            case .badStatus(let code):
                return TranslationEngineError.notAvailable(
                    String(localized: "Download failed (HTTP \(code)) for \(destination.lastPathComponent)."))
            case .rangeNotSatisfiable:
                return TranslationEngineError.notAvailable(
                    String(localized: "Download failed (HTTP \(416)) for \(destination.lastPathComponent)."))
            case .notAFile:
                return TranslationEngineError.notAvailable(
                    String(localized: "That URL answers with a web page, not a model file. Use the direct download link."))
            case .io(let e):
                return e
            }
        }
    }

    private let part: URL
    private let marker: URL
    private let resumeOffset: Int64
    private let sink: ProgressSink
    private let expected: Int64?

    // Only touched on the session's serial delegate queue — no lock needed.
    private var handle: FileHandle?
    private var received: Int64 = 0
    private(set) var knownTotal: Int64?
    private var failure: Failure?
    private var lastEmit = Date.distantPast
    private var lastBytes: Int64 = 0

    // The continuation/task pair IS raced: the awaiting task's cancellation
    // handler runs on whatever thread cancelled it.
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Error>?
    private var task: URLSessionDataTask?
    private var cancelled = false

    init(part: URL, marker: URL, resumeOffset: Int64,
         sink: @escaping ProgressSink, expected: Int64?) {
        self.part = part
        self.marker = marker
        self.resumeOffset = resumeOffset
        self.sink = sink
        self.expected = expected
    }

    func run(_ request: URLRequest, in session: URLSession) async throws {
        do {
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
                    let t = session.dataTask(with: request)
                    t.delegate = self
                    let wasCancelled: Bool = lock.withLock {
                        continuation = c
                        task = t
                        return cancelled
                    }
                    // Cancelled before the task existed: cancel it now — the
                    // completion callback still fires and resumes us.
                    if wasCancelled { t.cancel() } else { t.resume() }
                }
            } onCancel: {
                let t: URLSessionDataTask? = lock.withLock {
                    cancelled = true
                    return task
                }
                t?.cancel()
            }
        } catch let e as URLError where e.code == .cancelled && Task.isCancelled {
            // Callers distinguish "the user left" from "the network failed";
            // hand them the type Swift concurrency uses for the former.
            throw CancellationError()
        }
    }

    // MARK: - URLSessionDataDelegate

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask,
                    didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let http = response as? HTTPURLResponse else {
            completionHandler(.allow)
            return
        }
        // HTML masquerading as a model file — the classic pasted-model-page
        // URL. Failing here costs no bytes; failing at llama.cpp load time
        // costs the whole download and points nowhere near the mistake.
        //
        // Only on a body that claims to BE the file (200/206). An error
        // status serves an error page: nginx answers 416 with text/html, and
        // sniffing that first turned "your resume offset is stale" — which
        // the 416 branch below fixes silently by restarting once — into
        // "that URL answers with a web page", shown for a perfectly good
        // model URL whose partial happened to be complete.
        if [200, 206].contains(http.statusCode),
           let type = http.value(forHTTPHeaderField: "Content-Type"),
           type.lowercased().contains("text/html") {
            failure = .notAFile
            completionHandler(.cancel)
            return
        }
        switch http.statusCode {
        case 206:
            // "bytes <start>-<end>/<total>"
            var start = resumeOffset
            if let cr = http.value(forHTTPHeaderField: "Content-Range") {
                let core = cr.dropFirst("bytes ".count)
                if let dash = core.firstIndex(of: "-"),
                   let s = Int64(core[..<dash]) { start = s }
                if let slash = core.firstIndex(of: "/"),
                   let t = Int64(core[core.index(after: slash)...]) { knownTotal = t }
            }
            // A 206 from anywhere but our offset cannot be appended.
            guard start == resumeOffset else {
                failure = .rangeNotSatisfiable
                completionHandler(.cancel)
                return
            }
            received = resumeOffset
            open(truncate: false)
        case 200:
            // Full body: no range asked, range unsupported, or If-Range said
            // the file changed. Either way, start clean.
            received = 0
            knownTotal = http.expectedContentLength > 0 ? http.expectedContentLength : nil
            open(truncate: true)
            // Only once the file is actually open and truncated. If open()
            // failed, the OLD partial's bytes are still on disk, and the .io
            // path deliberately keeps them — pairing them with the NEW file's
            // validator would make the next attempt resume from the wrong
            // offset against the wrong file and install a spliced result.
            if failure == nil { storeValidator(from: http) }
        case 416:
            failure = .rangeNotSatisfiable
            completionHandler(.cancel)
            return
        default:
            failure = .badStatus(http.statusCode)
            completionHandler(.cancel)
            return
        }
        completionHandler(failure == nil ? .allow : .cancel)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask,
                    didReceive data: Data) {
        guard failure == nil, let handle else { return }
        do {
            try handle.write(contentsOf: data)
        } catch {
            failure = .io(error)
            dataTask.cancel()
            return
        }
        received += Int64(data.count)

        let now = Date()
        guard now.timeIntervalSince(lastEmit) >= 0.2 || received - lastBytes >= 4 << 20 else {
            return
        }
        lastEmit = now
        lastBytes = received
        // A server that sends no Content-Length reports nothing here; fall
        // back to the size we already know from the catalogue rather than
        // showing a bar that never moves.
        let total = knownTotal ?? expected ?? -1
        let fraction = total > 0 ? min(1, Double(received) / Double(total)) : nil
        sink(DownloadProgress(fraction: fraction,
                              note: String(localized: "Downloading…"),
                              completed: received,
                              total: total > 0 ? total : nil))
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    didCompleteWithError error: Error?) {
        try? handle?.close()
        handle = nil
        let c: CheckedContinuation<Void, Error>? = lock.withLock {
            let c = continuation
            continuation = nil
            return c
        }
        if let failure {
            c?.resume(throwing: failure)
        } else if let error {
            c?.resume(throwing: error)
        } else {
            c?.resume(returning: ())
        }
    }

    private func open(truncate: Bool) {
        do {
            let h = try FileHandle(forWritingTo: part)
            if truncate {
                try h.truncate(atOffset: 0)
            } else {
                try h.seekToEnd()
            }
            handle = h
        } catch {
            failure = .io(error)
        }
    }

    /// `If-Range` needs a strong validator: a strong ETag, else the
    /// Last-Modified date. With neither, no marker is written — and without a
    /// marker the next attempt starts clean rather than trusting bytes nothing
    /// can vouch for.
    private func storeValidator(from http: HTTPURLResponse) {
        let etag = http.value(forHTTPHeaderField: "ETag")
        let strong = etag.flatMap { $0.hasPrefix("W/") ? nil : $0 }
        if let v = strong ?? http.value(forHTTPHeaderField: "Last-Modified") {
            try? v.write(to: marker, atomically: true, encoding: .utf8)
        } else {
            try? FileManager.default.removeItem(at: marker)
        }
    }
}
