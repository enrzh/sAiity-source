import Foundation

/// How many failures it takes before a translator is written off.
///
/// There is no second engine to fall back to — `TranslationEngine.allCases` is
/// `[.madlad]` and `TranslationRuntimeFallback.resolve` returns nil for a
/// quarantined MADLAD — so retiring one is not a graceful degradation, it is
/// the end of translation for the app's lifetime. A short caption the model
/// declines to translate is ordinary behaviour and must not reach that state on
/// its own; only sustained failure should.
struct TranslationFailureBudget: Sendable, Equatable {
    /// Consecutive failures required before retiring.
    let threshold: Int
    private(set) var streak = 0

    init(threshold: Int = 3) {
        self.threshold = max(1, threshold)
    }

    /// Record a failure. True means the engine should now be retired; the
    /// streak resets on retirement so a later failure starts a fresh budget.
    mutating func recordFailure() -> Bool {
        streak += 1
        guard streak >= threshold else { return false }
        streak = 0
        return true
    }

    /// One success is enough to clear the budget. The question is whether the
    /// engine is broken *now*, not how many failures it has ever had.
    mutating func recordSuccess() {
        streak = 0
    }
}

/// Keeps a broken native translator from being retried over and over in one
/// app session. The state is intentionally in-memory: a new app build or a
/// repaired model should get a fresh chance without a migration preference.
struct TranslationRuntimeFallback: Sendable {
    private(set) var quarantined: Set<TranslationEngine> = []

    mutating func quarantine(_ engine: TranslationEngine) {
        quarantined.insert(engine)
    }

    func resolve(_ preferred: TranslationEngine?) -> TranslationEngine? {
        guard let preferred else { return nil }
        guard quarantined.contains(preferred) else { return preferred }
        let fallback: TranslationEngine?
        switch preferred {
        case .hyMT2, .qwen:
            fallback = .madlad
        case .madlad:
            fallback = nil
        }
        guard let fallback, !quarantined.contains(fallback) else { return nil }
        return fallback
    }
}
