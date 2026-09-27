import AppKit
import Testing

@testable import sAiity

@MainActor
@Suite struct SettingsWindowTests {
    @Test("settings keeps the everyday destinations separate")
    func settingsNavigationIsCompact() {
        #expect(SettingsPane.allCases == [.setup, .captions, .dictation, .library, .transcripts])
    }

    @Test("interrupted download cleanup preserves completed models")
    func interruptedDownloadCleanupPreservesCompletedModels() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("saiity-interrupted-test-\(UUID().uuidString)")
        let partialURL = root.appendingPathComponent("partial", isDirectory: true)
        let completeURL = root.appendingPathComponent("complete", isDirectory: true)
        try FileManager.default.createDirectory(at: partialURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: completeURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let partial = ModelAsset(
            id: "test.partial", family: .translation, title: "Partial", detail: "",
            recommended: false, licence: nil, advertisedBytes: nil,
            storage: .directory(partialURL, markers: ["weights.bin"]),
            removal: .remove(partialURL), use: .never, install: nil)
        let complete = ModelAsset(
            id: "test.complete", family: .translation, title: "Complete", detail: "",
            recommended: false, licence: nil, advertisedBytes: nil,
            storage: .directory(completeURL, markers: ["weights.bin"]),
            removal: .remove(completeURL), use: .never, install: nil)
        try Data(repeating: 1, count: 2048)
            .write(to: partialURL.appendingPathComponent("weights.part"))
        try Data(repeating: 2, count: 16)
            .write(to: completeURL.appendingPathComponent("weights.bin"))

        let state = AppState()
        state.assets = [ModelRegistry.status(of: partial), ModelRegistry.status(of: complete)]
        let freed = await state.clearInterruptedDownloads(includeRetired: false)

        #expect(freed == 2048)
        #expect(!FileManager.default.fileExists(atPath: partialURL.path))
        #expect(FileManager.default.fileExists(atPath: completeURL.path))
    }

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

    @Test("dictation cleanup exposes supported Gemma assets only")
    func dictationCleanupAssetsAreDownloadableAndFamilyRestricted() {
        let statuses = TranslationEngine.qwen.assetDescriptors.map(ModelRegistry.status(of:))
            + TranslationEngine.madlad.assetDescriptors.map(ModelRegistry.status(of:))
        let cleanup = DictationView.cleanupAssets(from: statuses)

        #expect(!cleanup.isEmpty)
        #expect(cleanup.allSatisfy {
            let title = $0.asset.title.lowercased()
            return title.contains("gemma")
        })
        #expect(!cleanup.contains { $0.asset.id == AssetID.madlad })
        #expect(cleanup.contains { $0.asset.id == AssetID.llm(file: "gemma-3-1b-it-Q4_K_M.gguf") })
        #expect(cleanup.contains { $0.asset.id == AssetID.llm(file: "gemma-3-4b-it-Q4_K_M.gguf") })
        #expect(!cleanup.contains { $0.asset.title.lowercased().contains("qwen") })
    }

    @Test("dictation cleanup is on by default and persists independently")
    func dictationCleanupIsIndependent() {
        let defaults = UserDefaults.standard
        let keys = ["dictationCleanupEnabled", "dictationRecognizer", "asrEngine",
                    "translateTo", "translateDictation", "dictationTranslateTo",
                    "dictationTranslateToMigrated", CaptionStyle.key]
        let snapshot = keys.map { ($0, defaults.object(forKey: $0)) }
        defer { snapshot.forEach { key, value in value.map { defaults.set($0, forKey: key) } ?? defaults.removeObject(forKey: key) } }
        defaults.removeObject(forKey: "dictationCleanupEnabled")
        defaults.removeObject(forKey: "dictationRecognizer")
        let state = AppState()
        let cleanupReady = state.llmModel?.isDownloaded == true
        #expect(state.dictationCleanupEnabled == cleanupReady)
        state.dictationCleanupEnabled = false
        #expect(defaults.bool(forKey: "dictationCleanupEnabled") == false)
        state.dictationCleanupEnabled = true
        #expect(state.dictationCleanupEnabled == cleanupReady)
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
        let snapshot = ["dictationRecognizer", "asrEngine", "dictationStreamingEngine", "whisperDictationSelected",
                        "dictationCleanupEnabled", "translateDictation", "translateTo",
                        CaptionStyle.key].map { ($0, defaults.object(forKey: $0)) }
        defer { snapshot.forEach { key, value in value.map { defaults.set($0, forKey: key) } ?? defaults.removeObject(forKey: key) } }
        defaults.set(ASREngine.parakeetEou.rawValue, forKey: "asrEngine")
        defaults.set(ASREngine.parakeetEou.rawValue, forKey: "dictationStreamingEngine")
        #expect(ASREngine.dictationSelected == nil)
        #expect(ASREngine.dictationEffective == .nemotron)
        DictationRecognizer.selected = .streaming
        let state = AppState()
        state.dictationRecognizer = .whisper
        WhisperDictationBackend.model = .small
        #expect(DictationRecognizer.selected == .whisper)
        #expect(WhisperDictationBackend.isSelected)
        #expect(WhisperDictationBackend.model == .small)
        #expect(ASREngine.selected != .parakeetEou)
    }

    @Test("dictation profiles map to the existing runtime controls")
    func dictationProfilesApplyWithoutChangingCaptionEngine() {
        let defaults = UserDefaults.standard
        let keys = ["dictationRecognizer", "dictationStreamingEngine", "nemotronChunkMs",
                    "dictationNemotronChunkMs", "asrEngine",
                    "dictationCleanupEnabled", "whisperDictationLocale",
                    "translateTo", "translateDictation", CaptionStyle.key]
        let snapshot = keys.map { ($0, defaults.object(forKey: $0)) }
        defer {
            snapshot.forEach { key, value in
                if let value { defaults.set(value, forKey: key) }
                else { defaults.removeObject(forKey: key) }
            }
        }

        defaults.set(ASREngine.parakeetEou.rawValue, forKey: "asrEngine")
        defaults.removeObject(forKey: "dictationRecognizer")
        defaults.removeObject(forKey: "dictationStreamingEngine")
        defaults.removeObject(forKey: "nemotronChunkMs")
        defaults.removeObject(forKey: "dictationNemotronChunkMs")
        defaults.removeObject(forKey: "dictationCleanupEnabled")
        defaults.removeObject(forKey: "whisperDictationLocale")

        let state = AppState()
        let cleanupReady = state.llmModel?.isDownloaded == true
        #expect(state.dictationProfile == (cleanupReady ? DictationProfile.balanced : .custom))

        state.dictationProfile = .fast
        #expect(state.dictationRecognizer == .streaming)
        #expect(defaults.string(forKey: "dictationStreamingEngine") == ASREngine.nemotron.rawValue)
        #expect(state.dictationNemotronTier == 1120)
        #expect(!state.dictationCleanupEnabled)

        state.dictationProfile = .accurate
        #expect(state.dictationRecognizer == .whisper)
        #expect(WhisperDictationBackend.locale == "auto")
        #expect(state.dictationCleanupEnabled == cleanupReady)
        #expect(ASREngine.selected != .parakeetEou)
    }

    @Test("a dictation profile never touches the caption tier or restarts captions")
    func dictationProfileDoesNotChangeCaptionEngine() {
        let defaults = UserDefaults.standard
        let keys = ["dictationRecognizer", "dictationStreamingEngine", "nemotronChunkMs",
                    "dictationNemotronChunkMs", "asrEngine", "dictationCleanupEnabled",
                    "whisperDictationLocale", CaptionStyle.key]
        let snapshot = keys.map { ($0, defaults.object(forKey: $0)) }
        defer {
            snapshot.forEach { key, value in
                if let value { defaults.set(value, forKey: key) }
                else { defaults.removeObject(forKey: key) }
            }
        }
        defaults.set(ASREngine.nemotron.rawValue, forKey: "asrEngine")
        defaults.set(NemotronEngine.chunkMs, forKey: "nemotronChunkMs")
        defaults.removeObject(forKey: "dictationNemotronChunkMs")
        defaults.removeObject(forKey: "dictationRecognizer")
        defaults.removeObject(forKey: "dictationStreamingEngine")
        defaults.removeObject(forKey: "dictationCleanupEnabled")
        defaults.removeObject(forKey: "whisperDictationLocale")

        var engineChanges = 0
        var dictationChanges = 0
        let state = AppState()
        // Observers go in after construction: `AppState.init` reconciles stored
        // settings and may legitimately post an engine change of its own, which
        // is not what this test is about.
        let engineToken = NotificationCenter.default.addObserver(
            forName: .saiityEngineChanged, object: nil, queue: .main) { _ in
                engineChanges += 1
            }
        let dictationToken = NotificationCenter.default.addObserver(
            forName: .saiityDictationSettingChanged, object: nil, queue: .main) { _ in
                dictationChanges += 1
            }
        defer {
            NotificationCenter.default.removeObserver(engineToken)
            NotificationCenter.default.removeObserver(dictationToken)
        }

        let captionTierBefore = state.nemotronTier
        #expect(captionTierBefore == NemotronEngine.chunkMs)

        // Fast is the profile that used to rewrite the shared caption key.
        state.dictationProfile = .fast
        #expect(state.dictationNemotronTier == 1120)
        #expect(defaults.integer(forKey: "nemotronChunkMs") == captionTierBefore)
        #expect(state.nemotronTier == captionTierBefore)
        #expect(NemotronEngine.selectedChunkMs == captionTierBefore)
        // One dictation refresh, and no engine change at all: an
        // `saiityEngineChanged` here is what stops and rebuilds a live caption
        // session's backend.
        #expect(engineChanges == 0)
        #expect(dictationChanges >= 1)

        state.dictationProfile = .balanced
        #expect(state.dictationNemotronTier == NemotronEngine.chunkMs)
        #expect(state.nemotronTier == captionTierBefore)
        #expect(engineChanges == 0)
    }

    @Test("dictation's tier is its own preference and follows captions only until it chooses")
    func dictationTierIsIndependentOfCaptionTier() {
        let defaults = UserDefaults.standard
        let keys = [NemotronEngine.captionTierKey, NemotronEngine.dictationTierKey]
        let snapshot = keys.map { ($0, defaults.object(forKey: $0)) }
        defer {
            snapshot.forEach { key, value in
                if let value { defaults.set(value, forKey: key) }
                else { defaults.removeObject(forKey: key) }
            }
        }

        // Nothing chosen anywhere: both surfaces read the default tier.
        defaults.removeObject(forKey: NemotronEngine.captionTierKey)
        defaults.removeObject(forKey: NemotronEngine.dictationTierKey)
        #expect(NemotronEngine.selectedChunkMs == NemotronEngine.chunkMs)
        #expect(NemotronEngine.dictationSelectedChunkMs == NemotronEngine.chunkMs)
        #expect(!NemotronEngine.hasExplicitDictationChunkSelection)

        // A caption choice is inherited by dictation, and counts as an explicit
        // pin — exactly the behaviour the shared key used to provide.
        defaults.set(1120, forKey: NemotronEngine.captionTierKey)
        #expect(NemotronEngine.dictationSelectedChunkMs == 1120)
        #expect(NemotronEngine.hasExplicitDictationChunkSelection)

        // Dictation's own choice then wins and the caption tier is left alone.
        NemotronEngine.dictationSelectedChunkMs = NemotronEngine.chunkMs
        #expect(defaults.integer(forKey: NemotronEngine.dictationTierKey) == NemotronEngine.chunkMs)
        #expect(defaults.integer(forKey: NemotronEngine.captionTierKey) == 1120)
        #expect(NemotronEngine.selectedChunkMs == 1120)
        #expect(NemotronEngine.dictationSelectedChunkMs == NemotronEngine.chunkMs)

        // A tier that is not a real one is refused rather than persisted, so a
        // later read cannot resolve a download against a 404 URL.
        NemotronEngine.dictationSelectedChunkMs = 7
        #expect(NemotronEngine.dictationSelectedChunkMs == NemotronEngine.chunkMs)
    }

    @Test("a Nemotron tier either surface names counts as in use")
    func nemotronTierInUseCoversBothSurfaces() {
        let defaults = UserDefaults.standard
        let keys = [NemotronEngine.captionTierKey, NemotronEngine.dictationTierKey,
                    "asrEngine", "dictationStreamingEngine", "dictationRecognizer"]
        let snapshot = keys.map { ($0, defaults.object(forKey: $0)) }
        defer {
            snapshot.forEach { key, value in
                if let value { defaults.set(value, forKey: key) }
                else { defaults.removeObject(forKey: key) }
            }
        }
        defaults.set(ASREngine.nemotron.rawValue, forKey: "asrEngine")
        defaults.set(NemotronEngine.chunkMs, forKey: NemotronEngine.captionTierKey)
        defaults.set(ASREngine.nemotron.rawValue, forKey: "dictationStreamingEngine")
        defaults.set(DictationRecognizer.streaming.rawValue, forKey: "dictationRecognizer")
        defaults.set(1120, forKey: NemotronEngine.dictationTierKey)

        let inUse = AssetUse.whenNemotronTier(chunkMs: 1120)
        #expect(inUse.isSelected, "the tier dictation runs is not reported as in use")
        // The tier only the caption side names, too.
        #expect(AssetUse.whenNemotronTier(chunkMs: NemotronEngine.chunkMs).isSelected)
        // A third tier that neither names is free to delete.
        #expect(!AssetUse.whenNemotronTier(chunkMs: 480).isSelected)
    }

    @Test("dictation translation is opt-in and persisted")
    func dictationTranslationIsOptIn() {
        let defaults = UserDefaults.standard
        let keys = ["translateDictation", "dictationTranslateTo", "dictationTranslateToMigrated",
                    "asrEngine", "dictationCleanupEnabled", "translateTo", CaptionStyle.key]
        let snapshot = keys.map { ($0, defaults.object(forKey: $0)) }
        defer {
            snapshot.forEach { key, value in
                if let value { defaults.set(value, forKey: key) }
                else { defaults.removeObject(forKey: key) }
            }
        }

        defaults.set(true, forKey: "dictationTranslateToMigrated")
        defaults.set("de", forKey: "dictationTranslateTo")
        defaults.removeObject(forKey: "translateDictation")
        let state = AppState()
        #expect(state.translateDictation == false)

        state.translateDictation = true
        #expect(defaults.bool(forKey: "translateDictation"))

        state.translateDictation = false
        #expect(defaults.bool(forKey: "translateDictation") == false)
    }

    @Test("a retired dictation engine falls back, and a supported one is honoured")
    func dictationTranslationEngineIsIndependent() {
        let defaults = UserDefaults.standard
        let keys = ["translationEngine", "dictationTranslationEngine", "asrEngine",
                    "dictationCleanupEnabled", "translateDictation", "translateTo",
                    "dictationTranslateTo", "dictationTranslateToMigrated", CaptionStyle.key]
        let snapshot = keys.map { ($0, defaults.object(forKey: $0)) }
        defer {
            snapshot.forEach { key, value in
                if let value { defaults.set(value, forKey: key) }
                else { defaults.removeObject(forKey: key) }
            }
        }

        // The local LLM is still retired, so a stale preference for it must
        // normalize away and leave dictation following the captions choice.
        defaults.set(TranslationEngine.madlad.rawValue, forKey: "translationEngine")
        defaults.set(TranslationEngine.qwen.rawValue, forKey: "dictationTranslationEngine")
        let retired = AppState()
        #expect(retired.dictationTranslationEngine == nil)
        #expect(TranslationEngine.dictationEffective == .madlad)
        // Keep the retired raw value for rollback; the normalized view is what
        // every runtime path consumes.
        #expect(defaults.string(forKey: "dictationTranslationEngine") == TranslationEngine.qwen.rawValue)

        // Hy-MT2 is selectable again, so a dictation preference for it is a
        // real choice rather than a stale one, and it is honoured as written.
        defaults.set(TranslationEngine.hyMT2.rawValue, forKey: "dictationTranslationEngine")
        let supported = AppState()
        #expect(supported.dictationTranslationEngine == .hyMT2)
        #expect(TranslationEngine.dictationEffective == .hyMT2)
    }

    @Test("legacy Qwen translation selections fall back to MADLAD")
    func legacyQwenSelectionDoesNotRemainInVisiblePicker() {
        let defaults = UserDefaults.standard
        let keys = ["translationEngine", "dictationTranslationEngine"]
        let snapshot = keys.map { ($0, defaults.object(forKey: $0)) }
        defer {
            snapshot.forEach { key, value in
                if let value { defaults.set(value, forKey: key) }
                else { defaults.removeObject(forKey: key) }
            }
        }
        defaults.set(TranslationEngine.qwen.rawValue, forKey: "translationEngine")
        defaults.set(TranslationEngine.qwen.rawValue, forKey: "dictationTranslationEngine")
        #expect(TranslationEngine.visibleSelection(TranslationEngine.selected) == nil)
        #expect(TranslationEngine.effective == .madlad)
        #expect(TranslationEngine.dictationEffective == .madlad)
    }

    @Test("first dictation target initialization inherits captions once, including Off")
    func dictationTargetMigratesOnce() {
        let defaults = UserDefaults.standard
        let keys = ["translateTo", "dictationTranslateTo", "dictationTranslateToMigrated",
                    "asrEngine", "dictationCleanupEnabled", "translateDictation", CaptionStyle.key]
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
        let defaults = UserDefaults.standard
        let keys = ["asrEngine", "dictationCleanupEnabled", "translateDictation", "translateTo",
                    "dictationTranslateTo", "dictationTranslateToMigrated", CaptionStyle.key]
        let snapshot = keys.map { ($0, defaults.object(forKey: $0)) }
        defer {
            snapshot.forEach { key, value in
                if let value { defaults.set(value, forKey: key) }
                else { defaults.removeObject(forKey: key) }
            }
        }
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
        let defaults = UserDefaults.standard
        let keys = ["asrEngine", "dictationCleanupEnabled", "translateDictation", "translateTo",
                    "dictationTranslateTo", "dictationTranslateToMigrated", CaptionStyle.key]
        let snapshot = keys.map { ($0, defaults.object(forKey: $0)) }
        defer {
            snapshot.forEach { key, value in
                if let value { defaults.set(value, forKey: key) }
                else { defaults.removeObject(forKey: key) }
            }
            settingsWindow()?.close()
            SettingsWindowController.state.showDictationTranslationPicker = false
        }
        SettingsWindowController.showDictationTranslationPicker()

        guard let window = settingsWindow() else {
            Issue.record("settings window was not created")
            return
        }

        #expect(SettingsWindowController.state.showDictationTranslationPicker)
        #expect(SettingsWindowController.selectedPane == .dictation)
        #expect(window.title == SettingsPane.dictation.windowTitle)
        #expect(window.standardWindowButton(.miniaturizeButton)?.isEnabled == true)
        #expect(window.standardWindowButton(.zoomButton)?.isEnabled == true)
        #expect(window.contentViewController != nil)
        #expect(abs((window.contentView?.bounds.height ?? 0) - 420) < 1)
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
        let defaults = UserDefaults.standard
        let keys = ["asrEngine", "dictationCleanupEnabled", "translateDictation", "translateTo",
                    "dictationTranslateTo", "dictationTranslateToMigrated", CaptionStyle.key]
        let snapshot = keys.map { ($0, defaults.object(forKey: $0)) }
        defer {
            snapshot.forEach { key, value in
                if let value { defaults.set(value, forKey: key) }
                else { defaults.removeObject(forKey: key) }
            }
        }
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

    @Test("model inventory refresh completes asynchronously and caches its snapshot")
    func modelInventoryRefreshIsNonBlockingAndCached() async {
        let state = AppState()
        await state.refreshModelsAsync(force: true)
        #expect(!state.assets.isEmpty)
        #expect(!state.isModelsLoading)
        #expect(state.ownedBytes >= 0)
    }

    @Test("settings uses the navigation shell")
    func settingsUsesNavigationShell() {
        let defaults = UserDefaults.standard
        let keys = ["asrEngine", "dictationCleanupEnabled", "translateDictation", "translateTo",
                    "dictationTranslateTo", "dictationTranslateToMigrated", CaptionStyle.key]
        let snapshot = keys.map { ($0, defaults.object(forKey: $0)) }
        defer {
            snapshot.forEach { key, value in
                if let value { defaults.set(value, forKey: key) }
                else { defaults.removeObject(forKey: key) }
            }
            settingsWindow()?.close()
        }
        SettingsWindowController.show()

        guard let window = settingsWindow() else {
            Issue.record("settings window was not created")
            return
        }

        let titles = [SettingsPane.setup, .captions, .dictation, .library, .transcripts].map(\.windowTitle)
        #expect(titles.contains(window.title))
        #expect(SettingsPane.library.windowTitle == "Models")
        #expect(SettingsPane.transcripts.windowTitle == "Transcripts")
        #expect(SettingsWindowController.selectedPane == .dictation || SettingsWindowController.selectedPane == .captions)
        #expect(window.titlebarAppearsTransparent == false)
        #expect(window.isOpaque)
        #expect(window.toolbar != nil)
        #expect(window.standardWindowButton(.miniaturizeButton)?.isEnabled == true)
        #expect(window.standardWindowButton(.zoomButton)?.isEnabled == true)
        #expect(window.contentViewController != nil)
        #expect(window.contentView?.bounds.width ?? 0 >= 760)
        #expect(abs((window.contentView?.bounds.height ?? 0) - 420) < 1)
    }

    private func settingsWindow() -> NSWindow? {
        NSApp.windows.first {
            $0.identifier == SettingsWindowController.settingsWindowIdentifier
        }
    }
}
