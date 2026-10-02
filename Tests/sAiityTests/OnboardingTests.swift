import Testing
import Foundation

@testable import sAiity

struct OnboardingTests {
    @MainActor @Test("rerunning setup preserves the existing automatic-update choice")
    func updatePreferenceIsPreserved() throws {
        let suite = "saiity-onboarding-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let state = AppState()
        for enabled in [true, false] {
            defaults.set(enabled, forKey: "SUEnableAutomaticChecks")
            #expect(OnboardingModel(state: state, defaults: defaults).wantsAutoUpdates == enabled)
        }
    }
    @Test("onboarding offers the three useful setup choices")
    func useCasesCoverTheTwoFeatures() {
        #expect(Set(OnboardingModel.UseCase.allCases) == [.captions, .dictation, .both])
        #expect(OnboardingModel.UseCase.captions.includesCaptions)
        #expect(!OnboardingModel.UseCase.captions.includesDictation)
        #expect(!OnboardingModel.UseCase.dictation.includesCaptions)
        #expect(OnboardingModel.UseCase.dictation.includesDictation)
        #expect(OnboardingModel.UseCase.both.includesCaptions)
        #expect(OnboardingModel.UseCase.both.includesDictation)
    }

    @Test("onboarding asks for setup before contextual permissions")
    func setupComesFirst() {
        #expect(OnboardingStep.allCases == [.setup, .permission, .finish])
    }
}
