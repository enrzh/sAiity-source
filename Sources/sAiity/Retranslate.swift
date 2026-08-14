import Foundation

/// Translate a transcript that was already recorded.
///
/// Until now a translation could only ever happen live: whatever language you
/// had set while the session ran was the only one you would ever get, and a
/// session recorded with translation off stayed monolingual forever. The lines
/// are on disk and the translator is on the machine, so the only thing missing
/// was somewhere to ask.
///
/// Two rules make this safe to run against a user's records:
///
/// - **It refuses while captions are running.** Loading a second translator
///   next to a live session is how a 16 GB Mac gets pushed into swap, and the
///   live session has first claim on the models.
/// - **It writes through a temporary file and replaces atomically.** A crash or
///   a quit mid-run leaves the original transcript exactly as it was, rather
///   than half-rewritten.
@MainActor
final class Retranslator {
    struct Progress {
        var done: Int
        var total: Int
        var note: String
    }

    private var task: Task<Void, Never>?
    private(set) var running = false

    func cancel() {
        task?.cancel()
        task = nil
    }

    /// Translate every line of `session` into `target`, replacing whatever
    /// translation was there. `onProgress` is called on the main actor.
    func run(session: SessionRef,
             target: String,
             onProgress: @escaping @MainActor (Progress) -> Void,
             onFinish: @escaping @MainActor (String?) -> Void) {
        guard !running else { return }
        guard !CaptionSession.shared.isRunning else {
            onFinish(String(localized: "Stop the captions first — the translator is busy with the live session."))
            return
        }
        guard let engine = TranslationEngine.effective.makeTranslator() else {
            onFinish(String(localized: "No translator chosen. Pick one under Settings → Captions."))
            return
        }

        running = true
        task = Task { @MainActor [weak self] in
            defer {
                self?.running = false
                self?.task = nil
            }
            let segments = TranscriptStore.segments(of: session)
            guard !segments.isEmpty else {
                onFinish(String(localized: "That transcript has no lines."))
                return
            }
            // The source language is the session's own, recorded when it ran.
            let source = session.meta.locale
            onProgress(Progress(done: 0, total: segments.count,
                                note: String(localized: "Loading the translator…")))
            do {
                try await engine.prepare(from: source, to: target) { _ in }
            } catch {
                await engine.stop()
                onFinish(error.localizedDescription)
                return
            }

            var out = segments
            for (i, seg) in segments.enumerated() {
                if Task.isCancelled { break }
                // Empty and punctuation-only lines cost a model round trip and
                // return nothing useful.
                if seg.text.rangeOfCharacter(from: .alphanumerics) != nil,
                   let tr = await engine.translate(seg.text, from: source, to: target),
                   !tr.isEmpty {
                    out[i].tr = tr
                    // Beside `tr`, never without it — the same rule the live
                    // path follows, so trLoc stays a record of outcome.
                    out[i].trLoc = target
                }
                onProgress(Progress(done: i + 1, total: segments.count,
                                    note: String(localized: "Translating…")))
            }
            await engine.stop()
            // Memory back to the system: this loaded a multi-gigabyte model
            // outside a caption session, and nothing else will release it.
            MemoryPolicy.releaseCaches()

            if Task.isCancelled {
                onFinish(String(localized: "Cancelled — the transcript was not changed."))
                return
            }
            if let err = Self.write(out, to: session) {
                onFinish(err)
                return
            }
            SegmentCache.shared.invalidate()
            onFinish(nil)
        }
    }

    /// Rewrite segments.jsonl atomically. Returns a message on failure.
    private static func write(_ segments: [Segment], to session: SessionRef) -> String? {
        let dest = session.url.appendingPathComponent("segments.jsonl")
        let tmp = session.url.appendingPathComponent("segments.jsonl.new")
        let enc = JSONEncoder()
        var blob = Data()
        for s in segments {
            guard var line = try? enc.encode(s) else { continue }
            line.append(0x0A)
            blob.append(line)
        }
        do {
            try blob.write(to: tmp, options: .atomic)
            _ = try FileManager.default.replaceItemAt(dest, withItemAt: tmp)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600],
                                                   ofItemAtPath: dest.path)
            return nil
        } catch {
            try? FileManager.default.removeItem(at: tmp)
            NSLog("sAiity retranslate write failed: \(error.localizedDescription)")
            return error.localizedDescription
        }
    }
}
