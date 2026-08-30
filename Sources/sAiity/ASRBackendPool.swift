import AVFoundation
import Foundation

@MainActor
protocol ASRBackendProvider: AnyObject {
    func prepare(locale: Locale,
                 progress: @escaping @Sendable (String) -> Void) async throws
    func acquire(locale: Locale,
                 progress: @escaping @Sendable (String) -> Void) async throws -> TranscriptionBackend
    func release(_ backend: TranscriptionBackend, discard: Bool) async
    func invalidate() async
}

/// Owns the one ASR backend that captions and dictation are allowed to share.
///
/// Preparation is single-flight, active use is exclusive, and a returned model
/// stays warm for a short grace period. The pool is deliberately main-actor
/// isolated because both callers already own their UI/session state there; the
/// backend's expensive work remains asynchronous behind its protocol.
@MainActor
final class ASRBackendPool: ASRBackendProvider {
    enum Error: LocalizedError, Equatable {
        case busy

        var errorDescription: String? {
            switch self {
            case .busy:
                return String(localized: "Speech recognition is already in use.")
            }
        }
    }

    private let makeBackend: () -> TranscriptionBackend
    private let idleEvictionDelay: Duration
    private let idleEviction = IdleEviction()

    private var cachedBackend: TranscriptionBackend?
    private var unpreparedBackend: TranscriptionBackend?
    private var preparationTask: Task<Void, any Swift.Error>?
    private var preparationGeneration = 0
    private var prepared = false
    private var activeBackend: TranscriptionBackend?

    #if SAIITY_TEST_HOOKS
    var preparedForTests: Bool { prepared }
    var hasActiveLeaseForTests: Bool { activeBackend != nil }
    #endif

    init(makeBackend: @escaping () -> TranscriptionBackend,
         idleEvictionDelay: Duration = .seconds(45)) {
        self.makeBackend = makeBackend
        self.idleEvictionDelay = idleEvictionDelay
    }

    /// The current object for synchronous callers that need to inspect its
    /// name. This can create an unprepared, model-free backend; loaded weights
    /// remain owned only by `cachedBackend` and are therefore evictable.
    var currentBackend: TranscriptionBackend {
        if let activeBackend { return activeBackend }
        if let cachedBackend { return cachedBackend }
        if let unpreparedBackend { return unpreparedBackend }
        let backend = makeBackend()
        unpreparedBackend = backend
        return backend
    }

    func prepare(locale: Locale,
                 progress: @escaping @Sendable (String) -> Void) async throws {
        idleEviction.cancel()
        if prepared {
            if let cachedBackend, activeBackend == nil {
                scheduleIdleEviction(for: cachedBackend)
            }
            return
        }
        if let task = preparationTask {
            try await task.value
            if let cachedBackend, activeBackend == nil {
                scheduleIdleEviction(for: cachedBackend)
            }
            return
        }

        preparationGeneration += 1
        let generation = preparationGeneration
        let candidate = unpreparedBackend ?? makeBackend()
        unpreparedBackend = nil
        let task = Task { @MainActor [weak self] in
            do {
                try await candidate.prepare(locale: locale, progress: progress)
            } catch {
                await candidate.release()
                throw error
            }
            guard !Task.isCancelled,
                  let self,
                  self.preparationGeneration == generation,
                  self.preparationTask != nil else {
                await candidate.release()
                throw CancellationError()
            }
            self.cachedBackend = candidate
            self.prepared = true
            self.preparationTask = nil
        }
        preparationTask = task
        do {
            try await task.value
            if let cachedBackend, activeBackend == nil {
                scheduleIdleEviction(for: cachedBackend)
            }
        } catch {
            if preparationGeneration == generation {
                preparationTask = nil
            }
            throw error
        }
    }

    func acquire(locale: Locale,
                 progress: @escaping @Sendable (String) -> Void) async throws -> TranscriptionBackend {
        guard activeBackend == nil else { throw Error.busy }
        try await prepare(locale: locale, progress: progress)
        guard let cachedBackend, prepared else {
            throw BackendError.notPrepared
        }
        idleEviction.cancel()
        activeBackend = cachedBackend
        return cachedBackend
    }

    func release(_ backend: TranscriptionBackend, discard: Bool) async {
        guard activeBackend === backend || cachedBackend === backend else { return }
        if activeBackend === backend {
            activeBackend = nil
        }

        guard discard else {
            scheduleIdleEviction(for: backend)
            return
        }

        idleEviction.cancel()
        if cachedBackend === backend {
            cachedBackend = nil
            prepared = false
            await backend.release()
        }
    }

    func invalidate() async {
        // This provider is shared by captions and dictation. An invalidation
        // requested by one consumer must not tear the backend out from under
        // the other consumer's active lease. The active owner will return it;
        // callers that need a full unload stop all consumers before retrying.
        guard activeBackend == nil else { return }
        idleEviction.cancel()
        preparationGeneration += 1
        let task = preparationTask
        preparationTask = nil
        task?.cancel()
        try? await task?.value

        let cached = cachedBackend
        cachedBackend = nil
        prepared = false
        activeBackend = nil
        unpreparedBackend = nil
        if let cached {
            await cached.release()
        }
    }

    func replace(with backend: TranscriptionBackend) async {
        await invalidate()
        unpreparedBackend = backend
    }

    private func scheduleIdleEviction(for backend: TranscriptionBackend) {
        guard prepared, activeBackend == nil, cachedBackend === backend else { return }
        idleEviction.schedule(after: idleEvictionDelay,
                              shouldEvict: { [weak self] in
                                  guard let self else { return false }
                                  return self.activeBackend == nil && self.cachedBackend === backend
                              },
                              evict: { [weak self] in
                                  await self?.evictIdle(backend)
                              })
    }

    private func evictIdle(_ backend: TranscriptionBackend) async {
        guard activeBackend == nil, cachedBackend === backend else { return }
        cachedBackend = nil
        prepared = false
        await backend.release()
    }
}

/// Adapter retained for unit tests and small callers that still provide a
/// backend factory. Production uses one `ASRBackendPool` for both consumers.
@MainActor
final class SingleBackendProvider: ASRBackendProvider {
    private let pool: ASRBackendPool

    init(makeBackend: @escaping () -> TranscriptionBackend) {
        pool = ASRBackendPool(makeBackend: makeBackend, idleEvictionDelay: .seconds(86_400))
    }

    func prepare(locale: Locale,
                 progress: @escaping @Sendable (String) -> Void) async throws {
        try await pool.prepare(locale: locale, progress: progress)
    }

    func acquire(locale: Locale,
                 progress: @escaping @Sendable (String) -> Void) async throws -> TranscriptionBackend {
        try await pool.acquire(locale: locale, progress: progress)
    }

    func release(_ backend: TranscriptionBackend, discard: Bool) async {
        await pool.release(backend, discard: discard)
    }

    func invalidate() async {
        await pool.invalidate()
    }
}
