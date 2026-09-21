import Foundation

/// Chooses among already-installed Nemotron tiers using the previous dictation
/// session's measured real-time factor. It only changes the next session and
/// never starts a download to chase a faster tier.
enum ASRAdaptivePolicy {
    enum Scope: String {
        case dictation
        case captions
    }

    static let fastRTFCeiling = 0.85
    static let balancedRTFFloor = 0.55

    private static func metricKey(_ tier: Int, scope: Scope) -> String {
        "\(scope.rawValue)ASRRTF.\(tier)"
    }

    static func choose(preferred: Int,
                       available: [Int],
                       installed: Set<Int>,
                       measuredRTF: [Int: Double]) -> Int {
        let tiers = available.filter { installed.contains($0) }.sorted()
        guard let fast = tiers.first else { return preferred }
        guard let balanced = tiers.last, fast != balanced else {
            return fast
        }

        if let fastRTF = measuredRTF[fast], fastRTF.isFinite,
           fastRTF <= fastRTFCeiling {
            return fast
        }
        if preferred == fast,
           let fastRTF = measuredRTF[fast], fastRTF > 1.0 {
            return balanced
        }
        if preferred == balanced,
           let balancedRTF = measuredRTF[balanced], balancedRTF <= balancedRTFFloor {
            return fast
        }
        return installed.contains(preferred) ? preferred : balanced
    }

    static func chooseRuntimeTier(preferred: Int,
                                  available: [Int],
                                  installed: Set<Int>,
                                  scope: Scope = .dictation) -> Int {
        choose(preferred: preferred,
               available: available,
               installed: installed,
               measuredRTF: Dictionary(uniqueKeysWithValues: available.compactMap { tier in
                   guard let value = UserDefaults.standard.object(forKey: metricKey(tier, scope: scope)) as? Double else {
                       return nil
                   }
                   return (tier, value)
               }))
    }

    static func record(realTimeFactor: Double, tier: Int, scope: Scope = .dictation) {
        guard realTimeFactor.isFinite, realTimeFactor >= 0 else { return }
        UserDefaults.standard.set(realTimeFactor, forKey: metricKey(tier, scope: scope))
    }
}
