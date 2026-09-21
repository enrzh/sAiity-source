import Foundation

/// One fetch per model, however many callers want it.
///
/// Four places pull model bytes, and only one of them — `AppState.download`,
/// behind Settings' `activeDownload == nil` guard — knew about any of the
/// others: `NemotronEngine.load`, `ParakeetEouEngine.load`,
/// `MADLADTranslator.prepare` and `LocalLLMTranslator.prepare` all fetch on the
/// caption path, where a session start is what triggers them.
///
/// That is not merely wasteful. `FileDownloader.download` stages into
/// `<destination>.part` and begins with an unconditional `try? removeItem(at:)`
/// of it, so two transfers of the same GGUF delete each other's staged bytes:
/// press Start with a translation target set, then press Download on the same
/// row in Settings — which is still offered, because `activeDownload` is nil —
/// and the two races end with one throwing, the other's `catch` removing what
/// is left, and up to twice the bytes pulled to install nothing. The three
/// directory-tree assets collide the same way inside their own downloaders.
///
/// ## Single-flight per asset, and nothing more
///
/// The second caller joins the transfer already running instead of starting a
/// second one. There is deliberately **no** global one-at-a-time queue, though
/// Settings has one and it reads as the obvious next step: a single slot turns
/// two independent fetches into a dependency, and this app has paths that can
/// want two at once — a translator swap and a recognition-engine restart are
/// separate untracked tasks — so a queue lets the first hold the slot while the
/// second waits on a session start that is waiting on it. Two transfers on one
/// connection are wasteful; a deadlock is not.
///
/// ## Cancellation, and why this is not just `await task.value`
///
/// The obvious shape is to keep a `Task` per asset and join it with
/// `try await task.value`. That is wrong in a way worth spelling out, because
/// it reads as correct and shipped here once: **awaiting an unstructured task's
/// value is not a cancellation point for the awaiting task.** Measured — a
/// caller cancelled 0.5 s into a 3 s transfer returned *normally* at 3.25 s.
///
/// The consequence was a wedge. `stopAsync()` cancels the session task and then
/// awaits it, so pressing Stop during the first Nemotron or MADLAD download
/// would have hung on "Stopping…" for the length of the whole transfer, with
/// Start answering "Still stopping" and no way out. Before the coordinator
/// existed, the session task awaited FluidAudio's downloader directly and
/// cancellation reached its `withTaskCancellationHandler`, so this would have
/// been a regression against 1.0.1.
///
/// So each caller waits on its own continuation rather than on the task, and a
/// cancelled caller is resumed at once. The shared transfer is cancelled when
/// the *last* waiter leaves — a caller going away should not abort a download
/// somebody else is still waiting for, and the last one going away should not
/// leave bytes being paid for that nobody wants.
actor DownloadCoordinator {
    static let shared = DownloadCoordinator()

    private final class Transfer {
        var task: Task<Void, Error>?
        var waiters: [UUID: CheckedContinuation<Void, Error>] = [:]
    }

    private var transfers: [String: Transfer] = [:]

    /// Run `work` for `id`, or join the run already in progress.
    ///
    /// `work` may outlive the caller that supplied it, so it must be
    /// self-contained — every caller passes a download, which is exactly that.
    func run(_ id: String, _ work: @escaping @Sendable () async throws -> Void) async throws {
        // Checked before registering. `withTaskCancellationHandler` fires its
        // handler immediately when the task is already cancelled, which would
        // run `leave` before the continuation exists — and then the continuation
        // registers with nobody left to resume it, which is a permanent hang.
        try Task.checkCancellation()

        let transfer: Transfer
        if let existing = transfers[id] {
            transfer = existing
        } else {
            let t = Transfer()
            transfers[id] = t
            t.task = Task { [weak self] in
                do {
                    try await work()
                    await self?.complete(id, .success(()))
                } catch {
                    await self?.complete(id, .failure(error))
                    throw error
                }
            }
            transfer = t
        }

        let ticket = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                // Runs synchronously in actor isolation, so `complete` cannot
                // interleave between the lookup above and this registration.
                transfer.waiters[ticket] = continuation
            }
        } onCancel: {
            Task { await self.leave(id, ticket) }
        }
    }

    /// Stop the transfer for `id` outright, for every joiner. Settings' Cancel
    /// button, where the user is cancelling the bytes rather than their own
    /// interest in them.
    func cancel(_ id: String) {
        transfers[id]?.task?.cancel()
    }

    var activeIDs: [String] { Array(transfers.keys) }

    private func complete(_ id: String, _ result: Result<Void, Error>) {
        guard let t = transfers.removeValue(forKey: id) else { return }
        for (_, continuation) in t.waiters { continuation.resume(with: result) }
        t.waiters.removeAll()
    }

    private func leave(_ id: String, _ ticket: UUID) {
        guard let t = transfers[id],
              let continuation = t.waiters.removeValue(forKey: ticket) else { return }
        continuation.resume(throwing: CancellationError())
        // Nobody is waiting for these bytes any more, so stop paying for them.
        // FileDownloader keeps its `.part` and validator on cancellation and
        // resumes from them next attempt; the FluidAudio-backed assets manage
        // their own per-file cache directories.
        if t.waiters.isEmpty { t.task?.cancel() }
    }
}

/// The registry id for each downloadable asset, constructible from what the
/// engines actually hold.
///
/// The ids existed only as string literals inside the descriptors, so an engine
/// that wanted to name its own asset had to retype one — which is why none of
/// them did, and why four download paths grew up outside the registry. The
/// descriptors now build their ids from here, so there is one spelling each and
/// `ModelRegistryTests` still pins the literals from outside.
enum AssetID {
    static func nemotron(chunkMs: Int) -> String {
        chunkMs < NemotronEngine.chunkMs ? "asr.nemotron.fast" : "asr.nemotron"
    }
    static let parakeetEou = "asr.parakeetEou"
    static let speakerDiarization = "diarization.lseend.dihard3.100ms"
    static let madlad = "mt.madlad"
    static let hyMT2 = "mt.hymt2.1.8b.q4"
    static func llm(file: String) -> String { "mt.llm.\(file)" }
}
