import Testing

@testable import sAiity

struct OnboardingTests {
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
