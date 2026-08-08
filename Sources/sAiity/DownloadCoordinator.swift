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
/// ## What this does, and what it deliberately does not
///
/// Single-flight **per asset**: the second caller joins the transfer already
/// running instead of starting a second one. That is the whole fix for the
/// defect above.
///
/// There is deliberately **no global one-at-a-time queue**. A single slot reads
/// as the obvious next step — Settings already has one — but it turns two
/// independent fetches into a dependency, and this app has paths that can want
/// two at once: a translator swap fired from a notification and a recognition
/// engine restart are separate untracked tasks, so a queue lets the first hold
/// the slot while the second waits on a session start that is waiting on it.
/// Concurrent transfers of *different* models are wasteful on one connection;
/// they are not incorrect. Deadlock is.
///
/// ## Cancellation
///
/// The shared work runs in an unstructured `Task` this actor owns and never
/// hands out. A caller that goes away — a cancelled session start — stops
/// awaiting and leaves the transfer running for whoever else wanted it; the
/// bytes are not thrown away. Only `cancel(_:)` stops the work itself, which is
/// what Settings' Cancel button calls, and it stops it for every joiner because
/// they are all waiting on the same bytes.
actor DownloadCoordinator {
    static let shared = DownloadCoordinator()

    private var inFlight: [String: Task<Void, Error>] = [:]

    /// Run `work` for `id`, or join the run already in progress.
    ///
    /// `work` must be self-contained: it may outlive the caller that supplied
    /// it, so it must not capture per-session state. Every caller passes a
    /// download, which is exactly that.
    func run(_ id: String, _ work: @escaping @Sendable () async throws -> Void) async throws {
        if let existing = inFlight[id] {
            // Awaiting another task's value is cancellation-aware for *us* — if
            // this caller is cancelled the await throws — without cancelling the
            // shared task. That asymmetry is the point.
            try await existing.value
            return
        }
        let task = Task<Void, Error> { [weak self] in
            defer { Task { await self?.finish(id) } }
            try await work()
        }
        inFlight[id] = task
        try await task.value
    }

    /// Stop the transfer for `id`, if one is running. Every joiner sees it.
    func cancel(_ id: String) {
        inFlight[id]?.cancel()
    }

    var activeIDs: [String] { Array(inFlight.keys) }

    private func finish(_ id: String) {
        inFlight[id] = nil
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
    static let madlad = "mt.madlad"
    static func llm(file: String) -> String { "mt.llm.\(file)" }
}
