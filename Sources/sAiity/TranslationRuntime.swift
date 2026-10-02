import Foundation

/// One owner for resident translation weights, native serialization and use leases.
@MainActor
final class TranslationRuntime {
    var active: (any Translating)?
    var engine: TranslationEngine?
    var preparedTarget: String?
    var ready = false
    var fallback = TranslationRuntimeFallback()
    var failureBudget = TranslationFailureBudget()
    let gate = TranslationInferenceGate()
    let idleEviction = IdleEviction()
    var swap: Task<Void, Never>?
    var generation = 0
    private(set) var users = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func beginUse() { users += 1 }

    func endUse() {
        precondition(users > 0, "Unbalanced translator use lease")
        users -= 1
        guard users == 0 else { return }
        let pending = waiters
        waiters.removeAll(keepingCapacity: true)
        pending.forEach { $0.resume() }
    }

    func waitUntilIdle() async {
        guard users > 0 else { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    /// Detach first; the caller waits for leases before destroying native state.
    func take() -> (any Translating)? {
        let outgoing = active
        active = nil
        engine = nil
        preparedTarget = nil
        ready = false
        return outgoing
    }

    func stop(_ translator: (any Translating)?) async {
        guard let translator else { return }
        _ = try? await gate.run { await translator.stop() }
    }
}
