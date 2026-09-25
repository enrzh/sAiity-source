import Foundation
import Testing

@testable import sAiity

@Suite struct SettingsStateHonestyTests {
    @Test("recommended recognition is selected only when its weights are on disk")
    func recommendedRecognitionStaysUnsetUntilInstalled() {
        let missing = SettingsStateHonesty.reconcile(
            recognition: nil,
            recommendedRecognitionInstalled: false,
            showCaptionTranslation: false,
            captionTarget: nil,
            dictationTranslationEnabled: false,
            dictationTarget: nil,
            cleanupEnabled: false,
            cleanupReady: false)
        #expect(missing.recognition == nil)

        let installed = SettingsStateHonesty.reconcile(
            recognition: nil,
            recommendedRecognitionInstalled: true,
            showCaptionTranslation: false,
            captionTarget: nil,
            dictationTranslationEnabled: false,
            dictationTarget: nil,
            cleanupEnabled: false,
            cleanupReady: false)
        #expect(installed.recognition == ASREngine.recommended)

        let explicit = SettingsStateHonesty.reconcile(
            recognition: .parakeetEou,
            recommendedRecognitionInstalled: true,
            showCaptionTranslation: false,
            captionTarget: nil,
            dictationTranslationEnabled: false,
            dictationTarget: nil,
            cleanupEnabled: false,
            cleanupReady: false)
        #expect(explicit.recognition == .nemotron)
    }

    @Test("translation and cleanup cannot stay on without a target or a ready model")
    func enabledSwitchesFollowWhatTheMacCanDo() {
        let dishonest = SettingsStateHonesty.reconcile(
            recognition: .nemotron,
            recommendedRecognitionInstalled: true,
            showCaptionTranslation: true,
            captionTarget: nil,
            dictationTranslationEnabled: true,
            dictationTarget: "",
            cleanupEnabled: true,
            cleanupReady: false)
        #expect(!dishonest.showCaptionTranslation)
        #expect(!dishonest.dictationTranslationEnabled)
        #expect(!dishonest.cleanupEnabled)

        let ready = SettingsStateHonesty.reconcile(
            recognition: .nemotron,
            recommendedRecognitionInstalled: true,
            showCaptionTranslation: true,
            captionTarget: "de",
            dictationTranslationEnabled: true,
            dictationTarget: "fr",
            cleanupEnabled: true,
            cleanupReady: true)
        #expect(ready.showCaptionTranslation)
        #expect(ready.dictationTranslationEnabled)
        #expect(ready.cleanupEnabled)
    }

    @Test("caption language says Auto only when the recognizer detects it from audio")
    func languageLabelMatchesTheRecognizer() {
        #expect(SettingsStateHonesty.languageLabel(for: nil) == "Not set")
        #expect(SettingsStateHonesty.languageLabel(for: .nemotron) == "Auto")
        #expect(SettingsStateHonesty.languageLabel(for: .parakeetEou) == "Auto")
    }
}

@MainActor
@Suite struct SettingsStateHonestyAppStateTests {
    @Test("opening settings corrects stored recognition, translation, and cleanup")
    func appStateDropsWorkItCannotDo() {
        let defaults = UserDefaults.standard
        let keys = ["asrEngine", "translateTo", "translateDictation", "dictationTranslateTo",
                    "dictationTranslateToMigrated", "dictationCleanupEnabled", CaptionStyle.key]
        let snapshot = keys.map { ($0, defaults.object(forKey: $0)) }
        defer {
            snapshot.forEach { key, value in
                if let value { defaults.set(value, forKey: key) }
                else { defaults.removeObject(forKey: key) }
            }
        }

        defaults.removeObject(forKey: "asrEngine")
        defaults.removeObject(forKey: "translateTo")
        defaults.set(true, forKey: "translateDictation")
        defaults.set(true, forKey: "dictationTranslateToMigrated")
        defaults.removeObject(forKey: "dictationTranslateTo")
        defaults.set(true, forKey: "dictationCleanupEnabled")
        var style = CaptionStyle()
        style.showTranslation = true
        if let data = try? JSONEncoder().encode(style) {
            defaults.set(data, forKey: CaptionStyle.key)
        }

        let state = AppState()
        if ASREngine.recommended.needsDownload {
            #expect(state.engine == nil)
        } else {
            #expect(state.engine == ASREngine.recommended)
            #expect(ASREngine.selected == ASREngine.recommended)
        }
        #expect(state.style.showTranslation == false)
        #expect(state.translateDictation == false)
        #expect(defaults.bool(forKey: "translateDictation") == false)
        #expect(state.dictationCleanupEnabled == (state.llmModel?.isDownloaded == true))
        #expect(SettingsStateHonesty.languageLabel(for: state.engine) != "Any language")
    }
}
