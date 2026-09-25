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

    private static func overloadKey(scope: Scope) -> String {
        "\(scope.rawValue)ASROverloaded"
    }

    static func choose(preferred: Int,
                       available: [Int],
                       installed: Set<Int>,
                       measuredRTF: [Int: Double],
                       preferFastWhenUnmeasured: Bool = false) -> Int {
        let tiers = available.filter { installed.contains($0) }.sorted()
        guard let fast = tiers.first else { return preferred }
        guard let balanced = tiers.last, fast != balanced else {
            return fast
        }

        if preferFastWhenUnmeasured, measuredRTF[fast] == nil {
            return fast
        }

        if let fastRTF = measuredRTF[fast], fastRTF.isFinite,
           fastRTF <= fastRTFCeiling {
            return fast
        }
        if preferred == fast,
           let fastRTF = measuredRTF[fast], fastRTF > fastRTFCeiling {
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
               }),
               preferFastWhenUnmeasured: scope == .captions
                   || UserDefaults.standard.bool(forKey: overloadKey(scope: scope)))
    }

    static func record(realTimeFactor: Double, tier: Int, scope: Scope = .dictation) {
        guard realTimeFactor.isFinite, realTimeFactor >= 0 else { return }
        UserDefaults.standard.set(realTimeFactor, forKey: metricKey(tier, scope: scope))
        if scope == .captions, realTimeFactor <= fastRTFCeiling {
            UserDefaults.standard.set(false, forKey: overloadKey(scope: scope))
        }
    }

    /// A dropped caption buffer is stronger evidence than a single RTF sample.
    /// Keep the next automatic session on the fastest installed tier; explicit
    /// user selections still bypass this policy at the caller.
    static func markOverloaded(scope: Scope = .captions) {
        UserDefaults.standard.set(true, forKey: overloadKey(scope: scope))
    }

    #if SAIITY_TEST_HOOKS
    static func clearOverloadForTests(scope: Scope = .captions) {
        UserDefaults.standard.removeObject(forKey: overloadKey(scope: scope))
    }
    #endif
}
