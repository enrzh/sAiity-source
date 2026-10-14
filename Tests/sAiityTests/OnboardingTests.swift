import Testing
import Foundation

@testable import sAiity

struct OnboardingTests {
    @MainActor @Test("setup resume is consumed from its supplied preference domain")
    func dupResumeUsesIsolatedDefaults() throws {
        let suite = "saiity-resume-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(OnboardingStep.permission.rawValue, forKey: "onboardingResumeStep")
        #expect(OnboardingModel(state: AppState(), defaults: defaults).step == .permission)
        #expect(defaults.object(forKey: "onboardingResumeStep") == nil)
    }

    @MainActor @Test("Try Dictation reveals its trial without changing captions-only setup choices")
    func dupExplicitTrialPreservesSetup() throws {
        let suite = "saiity-trial-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = OnboardingModel(state: AppState(), defaults: defaults)
        model.useCase = .captions
        model.openTrial(.dictation)
        #expect(model.step == .finish)
        #expect(model.trial == .dictation)
        #expect(model.useCase == .captions)
        model.trialBusy = true
        model.openTrial(.captions)
        #expect(model.trial == .dictation)
    }

    @Test("input hints wait for enough audio and report observations without judging speech")
    func dupInputHealthTrialHints() {
        #expect(DictationInputHealth(sampleCount: 16_000, rmsDBFS: -80, clippedSampleFraction: 0,
                                    observedDuration: 1).trialHint == String(localized: "Speak a short sentence to check this microphone."))
        #expect(DictationInputHealth(sampleCount: 32_000, rmsDBFS: -.infinity, clippedSampleFraction: 0,
                                    observedDuration: 2).trialHint == String(localized: "Input is very quiet. Check the microphone or move closer."))
        #expect(DictationInputHealth(sampleCount: 32_000, rmsDBFS: -20, clippedSampleFraction: 0.02,
                                    observedDuration: 2).trialHint == String(localized: "Input may be clipping. Lower the microphone input level."))
        #expect(DictationInputHealth(sampleCount: 32_000, rmsDBFS: nil, clippedSampleFraction: 0,
                                    observedDuration: 2).trialHint == String(localized: "Audio level is unavailable. The dictation result is still the useful check."))
        #expect(DictationInputHealth(sampleCount: 32_000, rmsDBFS: -20, clippedSampleFraction: 0,
                                    observedDuration: 2).trialHint == String(localized: "Audio input detected. Review the words below to check recognition."))
    }

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
