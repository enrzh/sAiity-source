import AppKit
import Foundation

/// Translate a transcript that was already recorded.
///
/// Until now a translation could only ever happen live: whatever language you
/// had set while the session ran was the only one you would ever get, and a
/// session recorded with translation off stayed monolingual forever. The lines
/// are on disk and the translator is on the machine, so the only thing missing
/// was somewhere to ask.
///
/// Three rules make this safe to run against a user's records:
///
/// - **It refuses while captions are running.** Loading a second translator
///   next to a live session is how a 16 GB Mac gets pushed into swap, and the
///   live session has first claim on the models.
/// - **Every native call goes through the shared inference gate.** This work
///   loads and decodes the same model the live path and dictation's own
///   translation use, and those run whether or not captions are on. Running it
///   outside the gate was how a re-translation and a dictation press ended up
///   decoding on one Metal runtime at once.
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

    /// Injected by tests; production resolves the app's one gate at run time,
    /// when the delegate is reachable and the actor is safe to touch.
    private let gateOverride: TranslationInferenceGate?

    private var task: Task<Void, Never>?
    private(set) var running = false

    init(gate: TranslationInferenceGate? = nil) {
        self.gateOverride = gate
    }

    /// The gate this run must enter for every native call. Falls back to the
    /// app's own, and to no gate at all only if there is no delegate — which
    /// cannot happen in the shipping app, and is better than refusing to
    /// translate because a test forgot to install a delegate.
    private var gate: TranslationInferenceGate? {
        gateOverride ?? (NSApp.delegate as? AppDelegate)?.translationInferenceGate
    }

    #if SAIITY_TEST_HOOKS
    /// Stand-in translator, so the gate, the cancellation and the atomic write
    /// can be exercised without 1.86 GB of weights on disk. The production
    /// checks — an engine chosen, its files present — stay in force for every
    /// real run; only the engine itself is substituted.
    var engineOverrideForTests: (any Translating)?
    #endif

    func cancel() {
        task?.cancel()
        task = nil
    }

    /// Cancel and wait until the run has actually unwound.
    ///
    /// `cancel()` alone returns while the translator is still loaded, which is
    /// exactly the window in which a caller about to delete model files would
    /// unlink bytes a decoding thread is still reading. This is the door for
    /// that caller.
    func cancelAndWait() async {
        let running = task
        cancel()
        await running?.value
    }

    /// One native call, through the gate when there is one. Cancellation is the
    /// gate's own answer and must not be swallowed into a "could not translate".
    private func infer<T: Sendable>(_ operation: @escaping @Sendable () async throws -> T) async throws -> T {
        if let gate { return try await gate.run(operation) }
        return try await operation()
    }

    /// Hand the model back and return its memory to the system. This loaded a
    /// multi-gigabyte translator outside a caption session, and nothing else
    /// will release it — so every exit, including cancellation, goes through
    /// here rather than only the successful one.
    private func stopAndRelease(_ engine: any Translating) async {
        await engine.stop()
        MemoryPolicy.releaseCaches()
    }

    /// Translate every line of `session` into `target`, replacing whatever
    /// translation was there. `onProgress` is called on the main actor.
    func run(session: SessionRef,
             target: String,
             onProgress: @escaping @MainActor (Progress) -> Void,
             onFinish: @escaping @MainActor (String?) -> Void) async {
        guard !running else { return }
        guard !CaptionSession.shared.isSummarizing else {
            onFinish(String(localized: CaptionSession.shared.transcriptWorkMessage))
            return
        }
        guard !CaptionSession.shared.isRunning else {
            onFinish(String(localized: "Stop the captions first — the translator is busy with the live session."))
            return
        }
        #if SAIITY_TEST_HOOKS
        if let engine = engineOverrideForTests {
            await beginRun(engine: engine, session: session, target: target,
                           onProgress: onProgress, onFinish: onFinish)
            return
        }
        #endif
        // `makeTranslator()` never returns nil today — both cases construct
        // one — so the old `guard let` here was unreachable and the real
        // failure went unhandled: with no weights on disk, prepare() quietly
        // starts a 1.86 GB download from a menu item that said "Translate",
        // with the progress sink thrown away. Ask the two questions that can
        // actually be answered before committing to anything.
        guard let chosen = TranslationEngine.visibleSelection(TranslationEngine.selected) else {
            onFinish(String(localized: "No translator chosen. Pick one under Settings → Captions."))
            return
        }
        let installed = chosen.activeAssetID.map { id in
            ModelRegistry.snapshot().first { $0.asset.id == id }?.isInstalled == true
        } ?? false
        guard installed else {
            onFinish(String(localized: "\(chosen.displayName) is not downloaded yet. Fetch it under Settings → Models first."))
            return
        }
        guard let engine = chosen.makeTranslator() else {
            onFinish(String(localized: "No translator chosen. Pick one under Settings → Captions."))
            return
        }
        await beginRun(engine: engine, session: session, target: target,
                      onProgress: onProgress, onFinish: onFinish)
    }

    /// The run itself, once an engine exists. Split out so the test seam above
    /// shares the exact production path — a second copy of the loop would be a
    /// second thing to keep correct.
    private func beginRun(engine: any Translating,
                          session: SessionRef,
                          target: String,
                          onProgress: @escaping @MainActor (Progress) -> Void,
                          onFinish: @escaping @MainActor (String?) -> Void) async {
        running = true
        CaptionSession.shared.beginRetranslation()
        // The read is a full-file parse that scales with the session's length.
        // It happens before the main-actor work, so a multi-hour transcript
        // costs a detached read rather than a frozen window. Repeat reads are
        // served by SegmentCache; this is the first one.
        let segments = await Task.detached {
            await TranscriptStore.segments(of: session)
        }.value
        task = Task { @MainActor [weak self] in
            defer {
                CaptionSession.shared.endRetranslation()
                self?.running = false
                self?.task = nil
            }
            guard !segments.isEmpty else {
                onFinish(String(localized: "That transcript has no lines."))
                return
            }
            // The source language is the session's own, recorded when it ran.
            let source = session.meta.locale
            onProgress(Progress(done: 0, total: segments.count,
                                note: String(localized: "Loading the translator…")))
            do {
                // The sink was discarded before, so loading a multi-gigabyte
                // model looked identical to a hang. Loading is native work too,
                // so it enters the same gate as the decoding below.
                try await infer {
                    try await engine.prepare(from: source, to: target) { msg in
                        Task { @MainActor in
                            onProgress(Progress(done: 0, total: segments.count, note: msg))
                        }
                    }
                }
            } catch is CancellationError {
                await stopAndRelease(engine)
                onFinish(String(localized: "Cancelled — the transcript was not changed."))
                return
            } catch {
                await stopAndRelease(engine)
                onFinish(error.localizedDescription)
                return
            }

            var out = segments
            var translated = 0, skipped = 0, failed = 0
            var aborted = false
            for (i, seg) in segments.enumerated() {
                if Task.isCancelled { break }
                // Empty and punctuation-only lines cost a model round trip and
                // return nothing useful.
                guard seg.text.rangeOfCharacter(from: .alphanumerics) != nil else {
                    skipped += 1
                    onProgress(Progress(done: i + 1, total: segments.count,
                                        note: String(localized: "Translating…")))
                    continue
                }
                // The gate is what makes this safe to run beside a live
                // session; a cancelled wait here is a cancel, not a line the
                // translator declined. A throw from the engine is now also a
                // genuine failure rather than a decline, and aborts the run
                // instead of being counted as one declined line.
                let result: String?
                do {
                    result = try await infer {
                        try await engine.translate(seg.text, from: source, to: target)
                    }
                } catch {
                    // Cancelled at the gate, the gate itself failed, or the
                    // engine failed. Either way this run owes the user a whole
                    // transcript, not a half-translated one.
                    aborted = true
                    break
                }
                if let tr = result, !tr.isEmpty {
                    out[i].tr = tr
                    // Beside `tr`, never without it — the same rule the live
                    // path follows, so trLoc stays a record of outcome.
                    out[i].trLoc = target
                    translated += 1
                } else {
                    // The translator declined this line. Leave whatever was
                    // there rather than half-replacing it, and count it: a run
                    // that silently produced a mixed-language transcript used
                    // to report plain success.
                    failed += 1
                }
                onProgress(Progress(done: i + 1, total: segments.count,
                                    note: String(localized: "Translating…")))
            }
            await stopAndRelease(engine)

            if aborted || Task.isCancelled {
                onFinish(String(localized: "Cancelled — the transcript was not changed."))
                return
            }
            if let err = Self.write(out, to: session) {
                onFinish(err)
                return
            }
            // The session's own record of what language it holds. Without
            // this the Markdown export keeps printing the language from the
            // original recording — a document that states the wrong thing
            // about its own contents.
            Self.updateMeta(of: session, translateTo: target)
            SegmentCache.shared.invalidate()
            SessionCatalog.invalidate()
            // Say what actually happened. "Done" over a transcript where the
            // translator declined half the lines is the kind of report that
            // costs someone an hour later.
            if failed > 0 {
                onFinish(String(localized: "Translated \(translated) lines; \(failed) could not be translated and kept what they had."))
            } else {
                onFinish(nil)
            }
        }
    }

    /// Record the transcript's new translation language in its own meta.json.
    /// Best-effort: the lines are already written and correct, so a failure
    /// here is a stale header, not lost work.
    private static func updateMeta(of session: SessionRef, translateTo: String) {
        var meta = session.meta
        meta.translateTo = translateTo
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        enc.dateEncodingStrategy = .iso8601
        guard let data = try? enc.encode(meta) else { return }
        try? data.write(to: session.url.appendingPathComponent("meta.json"), options: .atomic)
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
