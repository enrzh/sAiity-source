import AppKit
import Testing

@testable import sAiity

@MainActor
@Suite struct SettingsWindowTests {
    @Test("download captures model and refreshes readiness")
    func downloadActionUsesCapturedModelAndRefreshesReadiness() async {
        var events: [String] = []
        await DictationView.downloadAction(.base, prepare: { choice in events.append("prepare-\(choice)") }, refresh: { events.append("refresh") }, setError: { error in events.append("error-\(error.localizedDescription)") })
        #expect(events == ["prepare-base", "refresh"])
    }

    @Test("download failure stores error and refreshes state")
    func downloadFailureSetsModelErrorAndRefreshesState() async {
        var events: [String] = []
        await DictationView.downloadAction(.small, prepare: { _ in throw NSError(domain: "test", code: 1, userInfo: [NSLocalizedDescriptionKey: "failed"]) }, refresh: { events.append("refresh") }, setError: { error in events.append("error-\(error.localizedDescription)") })
        #expect(events == ["error-failed", "refresh"])
    }

    @Test("retry clears failure before using captured model")
    func retryClearsFailureThenUsesCapturedModel() async {
        var events: [String] = []
        await DictationView.retryAction(.small, clearError: { events.append("clear") }, prepare: { choice in events.append("prepare-\(choice)") }, refresh: { events.append("refresh") }, setError: { _ in events.append("error") })
        #expect(events == ["clear", "prepare-small", "refresh"])
    }

    @Test("remove invalidates before deleting and refreshes readiness")
    func removeInvalidatesBeforeDeletingAndRefreshesReadiness() async throws {
        var events: [String] = []
        try await DictationView.removeAction(.base, invalidate: { events.append("invalidate") }, remove: { choice in events.append("remove-\(choice)") }, refresh: { events.append("refresh") }, setError: { error in events.append("error-\(error.localizedDescription)") })
        #expect(events == ["invalidate", "remove-base", "refresh"])
    }

    @Test("permission recovery opens input monitoring settings")
    func permissionRecoveryOpensInputMonitoringSettings() {
        var opened: String?
        DictationView.permissionRecoveryAction("Privacy_ListenEvent") { opened = $0 }
        #expect(opened == "Privacy_ListenEvent")
    }

    @Test("not ready action selects existing models pane")
    func notReadyActionSelectsExistingModelsPane() {
        var selected = false
        DictationView.notReadyAction { selected = true }
        #expect(selected)
    }

    @Test("dictation cleanup exposes downloadable Qwen and Gemma assets")
    func dictationCleanupAssetsAreDownloadableAndFamilyRestricted() {
        let statuses = TranslationEngine.qwen.assetDescriptors.map(ModelRegistry.status(of:))
            + TranslationEngine.madlad.assetDescriptors.map(ModelRegistry.status(of:))
        let cleanup = DictationView.cleanupAssets(from: statuses)

        #expect(!cleanup.isEmpty)
        #expect(cleanup.allSatisfy {
            let title = $0.asset.title.lowercased()
            return title.contains("qwen") || title.contains("gemma")
        })
        #expect(!cleanup.contains { $0.asset.id == AssetID.madlad })
        #expect(cleanup.contains { $0.asset.id == AssetID.llm(file: "Qwen3.5-2B-Q4_K_M.gguf") })
        #expect(cleanup.contains { $0.asset.id == AssetID.llm(file: "gemma-3-1b-it-Q4_K_M.gguf") })
    }

    @Test("dictation cleanup is on by default and persists independently")
    func dictationCleanupIsIndependent() {
        let defaults = UserDefaults.standard
        let keys = ["dictationCleanupEnabled", "dictationRecognizer"]
        let snapshot = keys.map { ($0, defaults.object(forKey: $0)) }
        defer { snapshot.forEach { key, value in value.map { defaults.set($0, forKey: key) } ?? defaults.removeObject(forKey: key) } }
        defaults.removeObject(forKey: "dictationCleanupEnabled")
        defaults.removeObject(forKey: "dictationRecognizer")
        let state = AppState()
        #expect(state.dictationCleanupEnabled == true)
        state.dictationCleanupEnabled = false
        #expect(defaults.bool(forKey: "dictationCleanupEnabled") == false)
        state.dictationCleanupEnabled = true
        #expect(defaults.bool(forKey: "dictationCleanupEnabled"))
        state.engine = .nemotron
        state.dictationRecognizer = .whisper
        #expect(ASREngine.selected == .nemotron)
        #expect(state.dictationRecognizer == .whisper)
        #expect(WhisperDictationBackend.isSelected)
    }

    @Test("dictation locale covers every catalog language")
    func dictationLocaleCoversLanguageCatalog() {
        #expect(Set(WhisperDictationBackend.supportedLanguageCodes) == Set(LanguageCatalog.all.map(\.code)))
        #expect(WhisperDictationBackend.ModelChoice.allCases == [.base, .small])
        #expect(WhisperDictationBackend.isReady(.base, under: URL(fileURLWithPath: "/definitely-missing")) == false)
    }

    @Test("dictation recognizer choices update runtime selection without changing captions")
    func dictationRecognizerChoicesAreIndependent() {
        let defaults = UserDefaults.standard
        let snapshot = ["dictationRecognizer", "asrEngine", "whisperDictationSelected"].map { ($0, defaults.object(forKey: $0)) }
        defer { snapshot.forEach { key, value in value.map { defaults.set($0, forKey: key) } ?? defaults.removeObject(forKey: key) } }
        defaults.set(ASREngine.parakeetEou.rawValue, forKey: "asrEngine")
        DictationRecognizer.selected = .streaming
        let state = AppState()
        state.dictationRecognizer = .whisper
        WhisperDictationBackend.model = .small
        #expect(DictationRecognizer.selected == .whisper)
        #expect(WhisperDictationBackend.isSelected)
        #expect(WhisperDictationBackend.model == .small)
        #expect(ASREngine.selected == .parakeetEou)
    }

    @Test("dictation translation is opt-in and persisted")
    func dictationTranslationIsOptIn() {
        let defaults = UserDefaults.standard
        let previous = defaults.object(forKey: "translateDictation")
        defer {
            if let previous {
                defaults.set(previous, forKey: "translateDictation")
            } else {
                defaults.removeObject(forKey: "translateDictation")
            }
        }

        defaults.removeObject(forKey: "translateDictation")
        let state = AppState()
        #expect(state.translateDictation == false)

        state.translateDictation = true
        #expect(defaults.bool(forKey: "translateDictation"))

        state.translateDictation = false
        #expect(defaults.bool(forKey: "translateDictation") == false)
    }

    @Test("first dictation target initialization inherits captions once, including Off")
    func dictationTargetMigratesOnce() {
        let defaults = UserDefaults.standard
        let keys = ["translateTo", "dictationTranslateTo", "dictationTranslateToMigrated"]
        let snapshot = keys.map { ($0, defaults.object(forKey: $0)) }
        defer {
            snapshot.forEach { key, value in
                if let value { defaults.set(value, forKey: key) }
                else { defaults.removeObject(forKey: key) }
            }
        }

        defaults.set("de", forKey: "translateTo")
        defaults.removeObject(forKey: "dictationTranslateTo")
        defaults.removeObject(forKey: "dictationTranslateToMigrated")
        let inherited = AppState()
        #expect(inherited.dictationTranslateTo == "de")
        #expect(defaults.bool(forKey: "dictationTranslateToMigrated"))

        inherited.dictationTranslateTo = "fr"
        inherited.translateTo = "ja"
        let independent = AppState()
        #expect(independent.dictationTranslateTo == "fr")
        #expect(independent.translateTo == "ja")

        defaults.removeObject(forKey: "dictationTranslateTo")
        defaults.removeObject(forKey: "dictationTranslateToMigrated")
        defaults.removeObject(forKey: "translateTo")
        let off = AppState()
        #expect(off.dictationTranslateTo == nil)
        #expect(defaults.bool(forKey: "dictationTranslateToMigrated"))
    }

    @Test("dictation language picker has its own presentation state")
    func dictationPickerIsIndependent() {
        let state = AppState()
        #expect(state.showTranslationPicker == false)
        #expect(state.showDictationTranslationPicker == false)

        state.showDictationTranslationPicker = true

        #expect(state.showDictationTranslationPicker)
        #expect(state.showTranslationPicker == false)
    }

    @Test("dictation preparation uses its own target when captions are off")
    func dictationPreparationTargetIsIndependent() {
        #expect(AppDelegate.translationTargetForPreparation(
            captionsTarget: nil,
            requestedTarget: "de") == "de")
        #expect(AppDelegate.translationTargetForPreparation(
            captionsTarget: "fr",
            requestedTarget: "de") == "de")
        #expect(AppDelegate.translationTargetForPreparation(
            captionsTarget: "fr",
            requestedTarget: nil) == "fr")
    }

    @Test("dictation picker request selects the Dictation pane")
    func dictationPickerRequestSelectsDictationPane() {
        SettingsWindowController.showDictationTranslationPicker()
        defer {
            NSApp.windows
                .first(where: { $0.contentViewController is NSTabViewController })?
                .close()
            SettingsWindowController.state.showDictationTranslationPicker = false
        }

        guard let window = NSApp.windows.first(where: {
            $0.contentViewController is NSTabViewController
        }), let tabs = window.contentViewController as? NSTabViewController else {
            Issue.record("settings window was not created")
            return
        }

        #expect(SettingsWindowController.state.showDictationTranslationPicker)
        #expect(tabs.selectedTabViewItemIndex == 1)
    }

    @Test("recognition deletion releases dictation's fallback backend")
    func recognitionDeletionReleasesDictationBackendWithoutSelectedEngine() async {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("saiity-delete-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory,
                                                  withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let asset = ModelAsset(
            id: "test-recognition",
            family: .recognition,
            title: "Test recognition",
            detail: "",
            recommended: false,
            licence: nil,
            advertisedBytes: nil,
            storage: .directory(directory, markers: []),
            removal: .remove(directory),
            use: .never,
            install: nil)
        let state = AppState()
        var released = 0
        let previousRelease = CaptionSession.shared.releaseModels
        let previousRunning = CaptionSession.shared.isRunning
        CaptionSession.shared.releaseModels = { released += 1 }
        CaptionSession.shared.setRunning(false)
        defer {
            CaptionSession.shared.releaseModels = previousRelease
            CaptionSession.shared.setRunning(previousRunning)
        }

        await state.delete(asset)

        #expect(released == 1)
        #expect(!FileManager.default.fileExists(atPath: directory.path))
    }

    @Test("settings uses preference toolbar chrome with visible labels")
    func toolbarUsesPreferenceChrome() {
        SettingsWindowController.show()
        defer {
            NSApp.windows
                .first(where: { $0.contentViewController is NSTabViewController })?
                .close()
        }

        guard let window = NSApp.windows.first(where: {
            $0.contentViewController is NSTabViewController
        }) else {
            Issue.record("settings window was not created")
            return
        }

        #expect(window.toolbarStyle == .preference)
        #expect(window.titlebarAppearsTransparent == false)
        #expect(window.toolbar?.displayMode == .iconAndLabel)
        #expect(window.toolbar?.allowsDisplayModeCustomization == false)

        func descendants(of view: NSView) -> [NSView] {
            view.subviews + view.subviews.flatMap(descendants)
        }
        let backdrop = window.contentView?.superview.map(descendants(of:))?
            .compactMap { $0 as? SettingsWindowToolbarBackdrop }
            .first
        #expect(backdrop != nil)
        #expect(backdrop?.isOpaque == true)
        #expect(backdrop?.hitTest(NSPoint(x: 1, y: 1)) == nil)
        #expect(backdrop?.layer?.backgroundColor != nil)
    }
}
