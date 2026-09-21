import Foundation

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
