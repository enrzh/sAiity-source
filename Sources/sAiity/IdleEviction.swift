import Foundation

/// Schedules one cancellable release after a resource has gone idle.
///
/// The eligibility check runs at the deadline as well as when the schedule is
/// created. That makes a stale task harmless if a session starts again before
/// the grace period expires.
@MainActor
final class IdleEviction {
    private var task: Task<Void, Never>?
    private var generation = 0

#if SAIITY_TEST_HOOKS
    var isScheduledForTests: Bool { task != nil }
#endif

    func cancel() {
        generation += 1
        task?.cancel()
        task = nil
    }

    func schedule(after delay: Duration,
                  shouldEvict: @escaping @MainActor () -> Bool,
                  evict: @escaping @MainActor () async -> Void) {
        cancel()
        let token = generation
        task = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: delay)
            } catch {
                return
            }
            guard let self,
                  !Task.isCancelled,
                  self.generation == token,
                  shouldEvict() else { return }
            self.task = nil
            await evict()
        }
    }
}
