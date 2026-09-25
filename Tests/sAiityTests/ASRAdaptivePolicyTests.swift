import Foundation
import Testing

@testable import sAiity

@Suite(.serialized) struct ASRAdaptivePolicyTests {
    @Test("adaptive policy prefers fast tier after a healthy measurement")
    func healthyFastTier() {
        #expect(ASRAdaptivePolicy.choose(
            preferred: 2240,
            available: [1120, 2240],
            installed: [1120, 2240],
            measuredRTF: [1120: 0.42]) == 1120)
    }

    @Test("adaptive policy falls back when fast tier cannot keep up")
    func slowFastTier() {
        #expect(ASRAdaptivePolicy.choose(
            preferred: 1120,
            available: [1120, 2240],
            installed: [1120, 2240],
            measuredRTF: [1120: 1.2]) == 2240)
    }

    @Test("adaptive policy never selects a model that is not installed")
    func installedOnly() {
        #expect(ASRAdaptivePolicy.choose(
            preferred: 2240,
            available: [1120, 2240],
            installed: [2240],
            measuredRTF: [1120: 0.2]) == 2240)
    }

    @Test("adaptive policy uses the only installed tier")
    func onlyInstalledTier() {
        #expect(ASRAdaptivePolicy.choose(
            preferred: 2240,
            available: [1120, 2240],
            installed: [1120],
            measuredRTF: [2240: 0.2]) == 1120)
    }

    @Test("caption and dictation measurements remain independent")
    func scopesDoNotBleedTogether() {
        let defaults = UserDefaults.standard
        let keys = ["captionsASRRTF.1120", "dictationASRRTF.1120"]
        let previous = Dictionary(uniqueKeysWithValues: keys.map {
            ($0, defaults.object(forKey: $0))
        })
        defer {
            for key in keys {
                if let value = previous[key] {
                    defaults.set(value, forKey: key)
                } else {
                    defaults.removeObject(forKey: key)
                }
            }
        }

        defaults.set(0.4, forKey: "captionsASRRTF.1120")
        defaults.set(1.2, forKey: "dictationASRRTF.1120")

        let installed: Set<Int> = [1120, 2240]
        #expect(ASRAdaptivePolicy.chooseRuntimeTier(
            preferred: 2240,
            available: [1120, 2240],
            installed: installed,
            scope: .captions) == 1120)
        #expect(ASRAdaptivePolicy.chooseRuntimeTier(
            preferred: 2240,
            available: [1120, 2240],
            installed: installed,
            scope: .dictation) == 2240)
    }

    @Test("captions prefer the installed fast tier before a measurement exists")
    func captionsPreferFastWithoutMeasurement() {
        #expect(ASRAdaptivePolicy.chooseRuntimeTier(
            preferred: 2240,
            available: [1120, 2240],
            installed: [1120, 2240],
            scope: .captions) == 1120)
    }

    @Test("caption overloads keep the next automatic session on the fast tier")
    func overloadForcesFastTier() {
        let defaults = UserDefaults.standard
        let key = "captionsASROverloaded"
        let old = defaults.object(forKey: key)
        defer {
            if let old { defaults.set(old, forKey: key) }
            else { defaults.removeObject(forKey: key) }
        }

        ASRAdaptivePolicy.markOverloaded(scope: .captions)
        #expect(ASRAdaptivePolicy.chooseRuntimeTier(
            preferred: 2240,
            available: [1120, 2240],
            installed: [1120, 2240],
            scope: .captions) == 1120)
    }
}
