import Dispatch
import Foundation
import MLX

/// What the app is allowed to keep in RAM, and when it has to give it back.
///
/// This exists because of a real failure: on a 16 GB MacBook Air, a captioning
/// session with translation on drove the machine into macOS's out-of-application
/// memory condition. None of it was a leak in the ordinary sense — every model
/// was released correctly at the Swift level — but "released" and "returned to
/// the operating system" are not the same thing, and nothing in the app had an
/// opinion about the difference.
///
/// Three separate mechanisms were each holding gigabytes:
///
///   - **MLX's buffer cache.** MLX does not hand freed GPU buffers back to the
///     system; it pools them for reuse, and the pool's default ceiling is a
///     fraction of physical RAM (~15 GB on a 16 GB machine). MADLAD's decoder
///     allocates a fresh key/value concatenation and a 256k-vocabulary logits
///     tensor *per generated token*, so the pool ratchets upward across a
///     session and never comes back down. Dropping the model then frees a
///     reference and moves ~1.9 GB into the cache, where it stays for the life
///     of the process — including while a second translator loads on top of it.
///   - **Eager loading.** Choosing a translation target loaded the model
///     immediately, whether or not captions were running.
///   - **No idle release.** An app left open overnight held everything it had
///     ever loaded.
///
/// The policy here is: keep the pool small, hand memory back at every point the
/// user is not actively using it, and shed aggressively when the system says it
/// is under pressure — before the kernel starts choosing victims for us.
///
/// ## Known residual: ~10 MB per MADLAD load, and it is not ours to fix
///
/// Everything above works, and with translation off the app is flat across
/// sessions. With MADLAD on, roughly 10 MB per start/stop cycle survives Stop.
/// It was chased to the end in August 2026; recording the answer here so nobody
/// spends that day twice.
///
/// It is **inside MLX**, not in this app and not in speech-swift. Measured on a
/// standalone load/release loop, one `MADLADTranslator.fromLocal` at a time and
/// nothing else running:
///
///   - 13,279 live `mlx::core::array::ArrayDesc` (448 bytes each) plus ~2,300
///     `AGXG16GFamilyBuffer` are retained per load, exactly linear: 26,559 after
///     two loads, 66,396 after five. That is the ~10 MB.
///   - `leaks` reports 80 bytes total, so none of it is orphaned — it is all
///     still referenced.
///   - `leaks --traceTree` puts the root, across every sampled block, in a
///     static inside MLX's C++ core: `mlx::core::io::thread_pool()::pool_`,
///     the pool `Load::eval_cpu` enqueues one read task into per tensor. MADLAD
///     is 1,898 tensors. What is *proven* is that the blocks are live and that
///     the reference chain ends there; the exact mechanism inside MLX (queued
///     task, worker-held `std::function`, or stale words in the deque's buffer
///     fooling a conservative scanner) was not pinned down, and an upstream
///     report should say so rather than assert one.
///   - The Swift objects all die correctly — translator, tokenizer and the
///     whole module tree deallocate on `stop()`, confirmed with weak references.
///
/// Two things made this hard to see, and both are worth knowing:
///
///   - MLX's own accounting stays clean (`active 0 MB, cached 0 MB` after every
///     release), because an array that has never been evaluated owns a
///     descriptor and no buffer. That is also why `vmmap` blames *Malloc Small*
///     rather than anything GPU-shaped, and why `releaseCaches()` cannot help:
///     there is nothing pooled to hand back.
///   - **RSS lies here.** Under any memory pressure the kernel compresses these
///     pages out and RSS falls while the leak grows. Measure `phys_footprint`
///     (`TASK_VM_INFO`) — what Activity Monitor calls Memory — or count the
///     objects with `heap <pid> | grep ArrayDesc`, which is exact.
///
/// Ruled out by measurement, so do not re-try them: scoping the load to its own
/// `MLXRandom.RandomState`, and reseeding the global PRNG after loading. Both
/// fix a real but much smaller retention (~2,800 descriptors per *model
/// construction*, MLX's PRNG state being a lazy array whose every split holds
/// the one before it) — and both leave the count on the real load path
/// bit-for-bit unchanged, because the weights path retains the same graph
/// anyway. There is no API on `mlx-swift` 0.31.6 to drain or reset that pool.
///
/// The cost is bounded and small: ~10 MB per captioning session that uses
/// MADLAD, released when the app quits. Fixing it means an upstream change in
/// `ml-explore/mlx`; until then this is a known, documented residual and not
/// something to work around here.
enum MemoryPolicy {

    /// Ceiling for MLX's reuse pool.
    ///
    /// MLX's own guidance is that caches in the low megabytes often perform as
    /// well as unbounded ones. This is deliberately more generous than that:
    /// MADLAD's per-token allocations are large (a 256k-vocabulary logits tensor
    /// alone is ~1 MB, and the growing KV tensors are re-allocated each step),
    /// and a pool too small to hold one decode step turns every step into a
    /// round trip to the Metal allocator. 256 MB comfortably covers a
    /// caption-length decode while being ~1.5% of the machine — against a
    /// default ceiling of roughly 15 GB.
    static let mlxCacheLimit = 256 << 20

    /// Whether anything has actually engaged MLX yet.
    ///
    /// Touching any of these APIs constructs the Metal device and its allocator,
    /// so applying the limit at launch would make every user pay for a GPU
    /// context — including the ones who only ever run the llama.cpp translator,
    /// or no translator at all. Nothing here fires until an MLX model is about
    /// to load.
    private static let engagedLock = NSLock()
    nonisolated(unsafe) private static var engaged = false

    /// Call immediately before loading an MLX model.
    static func prepareForMLX() {
        let first = engagedLock.withLock { () -> Bool in
            defer { engaged = true }
            return !engaged
        }
        guard first else { return }
        // `memoryLimit` is deliberately left alone. It does not cap anything —
        // it makes allocations *wait* on scheduled work once exceeded, which
        // turns a memory problem into a stall, and a stalled decode inside a
        // live captioning session is worse than a large one.
        MLX.Memory.cacheLimit = mlxCacheLimit
        NSLog("sAiity memory: MLX cache limited to \(mlxCacheLimit / (1 << 20)) MB")
    }

    private static var isEngaged: Bool { engagedLock.withLock { engaged } }

    /// Return pooled buffers to the operating system. A no-op until an MLX model
    /// has been loaded, so it is safe on every teardown path.
    static func releaseCaches() {
        guard isEngaged else { return }
        MLX.Memory.clearCache()
    }

    /// Live figures, for the log line after a release. `active` is what models
    /// and live tensors hold; `cache` is what is pooled and reclaimable.
    static func footprint() -> (active: Int, cache: Int, peak: Int)? {
        guard isEngaged else { return nil }
        return (MLX.Memory.activeMemory, MLX.Memory.cacheMemory, MLX.Memory.peakMemory)
    }

    static func describeFootprint() -> String {
        guard let f = footprint() else { return "MLX not loaded" }
        func mb(_ b: Int) -> String { "\(b / (1 << 20)) MB" }
        return "active \(mb(f.active)), cached \(mb(f.cache)), peak \(mb(f.peak))"
    }

    // MARK: - System memory pressure

    /// How urgently the system wants memory back.
    enum Pressure {
        /// Pressure has passed. Whatever was shed can come back.
        case normal
        /// Shed what is free to shed. Nothing the user notices.
        case warning
        /// Shed everything not needed for captions to keep running. The user
        /// notices, so the caller says so in the status line — silently
        /// switching translation off would read as a bug.
        case critical
    }

    private static var source: DispatchSourceMemoryPressure?

    /// Start listening. `handler` runs on the main actor.
    ///
    /// Reacting at all is the point: macOS raises these well before it starts
    /// killing processes, and an app that ignores them contributes to a
    /// system-wide out-of-memory condition it could have prevented by giving
    /// back a cache it was not using.
    static func startMonitoring(handler: @escaping @MainActor (Pressure) -> Void) {
        guard source == nil else { return }
        // .normal is listened for too, and that is the whole difference between
        // shedding and breaking: without it a single transient spike turned
        // translation off for the rest of the session with no way back.
        let s = DispatchSource.makeMemoryPressureSource(
            eventMask: [.normal, .warning, .critical], queue: .main)
        s.setEventHandler {
            // `data`, not `mask`. `mask` is the mask we REGISTERED — with all
            // three levels requested it reads 7 forever, so `mask.contains(.critical)`
            // was unconditionally true: every event, including the one that says
            // pressure has passed, arrived as .critical. That made the .normal
            // recovery branch dead code, so translation shed under pressure and
            // never came back, while the status line promised it would.
            let event = DispatchSource.MemoryPressureEvent(rawValue: s.data)
            let level: Pressure = event.contains(.critical) ? .critical
                                : event.contains(.warning) ? .warning : .normal
            NSLog("sAiity memory: system pressure \(level) — \(describeFootprint())")
            MainActor.assumeIsolated { handler(level) }
        }
        s.resume()
        source = s
    }
}
