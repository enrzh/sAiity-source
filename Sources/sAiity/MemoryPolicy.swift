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
        let s = DispatchSource.makeMemoryPressureSource(
            eventMask: [.warning, .critical], queue: .main)
        s.setEventHandler {
            let level: Pressure = s.mask.contains(.critical) ? .critical : .warning
            NSLog("sAiity memory: system pressure \(level) — \(describeFootprint())")
            MainActor.assumeIsolated { handler(level) }
        }
        s.resume()
        source = s
    }
}
