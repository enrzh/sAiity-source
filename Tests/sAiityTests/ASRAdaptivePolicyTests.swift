import Foundation
import Testing

@testable import sAiity

@Suite struct ASRAdaptivePolicyTests {
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
}
