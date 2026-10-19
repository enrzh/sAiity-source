import AppKit
import SwiftUI

/// Press-to-talk: the shortcut, what happens to the words, and the bubble.
///
/// The first section answers "can I dictate right now": the switch, the
/// shortcut, anything still missing (a permission, a model) and a way to try
/// it. Everything a first-time user does not need sits under Advanced.
@MainActor
struct DictationView: View {
    @Bindable var state: AppState
    var onDetailVisibilityChanged: (Bool) -> Void = { _ in }

    @State private var permissions = PermissionMonitor()
    @State private var shortcutMessage: String?
    @State private var showsAdvanced = false
    @State private var showsVocabulary = false
    @State private var recentCopyNote: String?

    var body: some View {
        Form {
            essentials
            processing
            bubble
            advanced
        }
        .formStyle(.grouped)
        .task { await permissions.watch() }
        .task { await state.refreshModelsAsync() }
        .onChange(of: state.dictationTranslateTo) { _, target in
            // A language picked in the full list turns translation on, the
            // same as picking one from the menu.
            if target != nil { state.translateDictation = true }
        }
        .sheet(isPresented: $state.showDictationTranslationPicker) {
            TranslationTargetPicker(state: state,
                                    target: $state.dictationTranslateTo,
                                    title: "Translate dictation to",
                                    scope: .dictation)
        }
        .sheet(isPresented: $state.showLocalModels) { LocalModelsView(state: state) }
        .sheet(isPresented: $state.showsRecentDictations) {
            recentDictationsSheet.onAppear { recentCopyNote = nil }
        }
        .sheet(isPresented: $showsVocabulary) { vocabularySheet }
    }

    // MARK: Essentials

    private var shortcutHint: String {
        let chord = state.dictationChord.displayString
        return state.dictationChord.isModifierOnly
            ? String(localized: "Hold \(chord), speak, then let go. Pressing any other key with it cancels.")
            : String(localized: "Hold \(chord), speak, then let go.")
    }

    @ViewBuilder
    private var essentials: some View {
        Section {
            Toggle(isOn: $state.dictationEnabled) {
                Text("Dictation")
                Text("Your words appear wherever you are typing.")
            }
            if state.dictationEnabled {
                LabeledContent {
                    DictationShortcutRecorder(state: state) { message in
                        shortcutMessage = message
                    }
                    .frame(width: 150, height: 26)
                } label: {
                    Text("Shortcut")
                    Text(verbatim: shortcutHint)
                }
                if let shortcutMessage {
                    Text(verbatim: shortcutMessage)
                        .foregroundStyle(.orange)
                }
                ForEach(permissions.missing(for: .dictation)) { permission in
                    PermissionRow(permission: permission, status: permissions.status(permission))
                }
                ForEach(recognitionAssets, id: \.id) { asset in
                    RequiredModelRow(state: state, asset: asset)
                }
                if state.dictationUsesOriginalText {
                    Text("Original text for this app · cleanup and translation off")
                        .foregroundStyle(.secondary)
                }
                LabeledContent {
                    Button("Try Dictation…") {
                        OnboardingWindowController.shared.show(state: state, trial: .dictation)
                    }
                    .disabled(CaptionSession.shared.isRunning || CaptionSession.shared.isProcessingTranscript)
                } label: {
                    Text("Test")
                    Text("Records one sentence and shows the result without typing it anywhere.")
                }
            }
        }
    }

    /// The recognition model files the current choice needs.
    private var recognitionAssets: [ModelAsset] {
        if state.dictationRecognizer == .whisper {
            return ModelRegistry.assets().filter { $0.id == AssetID.whisper(WhisperDictationBackend.model) }
        }
        let engine = state.dictationEngine ?? ASREngine.dictationEffective
        return engine.assetDescriptors.filter {
            engine != .nemotron || $0.id == AssetID.nemotron(chunkMs: state.dictationNemotronTier)
        }
    }

    // MARK: Processing

    private var translationTarget: Binding<String?> {
        Binding(
            get: { state.translateDictation ? state.dictationTranslateTo : nil },
            set: { code in
                if let code {
                    state.dictationTranslateTo = code
                    state.translateDictation = true
                } else {
                    state.translateDictation = false
                }
            })
    }

    private var translationEngine: TranslationEngine {
        state.dictationTranslationEngine ?? TranslationEngine.dictationEffective
    }

    @ViewBuilder
    private var processing: some View {
        Section {
            Picker(selection: Binding(get: { state.dictationProfile },
                                      set: { state.dictationProfile = $0 })) {
                ForEach(DictationProfile.allCases.filter { $0 != .custom }, id: \.self) { profile in
                    Text(verbatim: profile.displayName).tag(profile)
                }
                if state.dictationProfile == .custom {
                    Divider()
                    Text(verbatim: DictationProfile.custom.displayName).tag(DictationProfile.custom)
                }
            } label: {
                Text("Mode")
                Text(verbatim: Self.profileExplanation(state.dictationProfile))
            }

            TranslationTargetRow(title: "Translate to",
                                 target: translationTarget,
                                 recent: state.recentDictationTargetsForMenu) {
                state.showDictationTranslationPicker = true
            }
            if state.translateDictation, let id = translationEngine.activeAssetID,
               let asset = translationEngine.assetDescriptors.first(where: { $0.id == id }) {
                RequiredModelRow(state: state, asset: asset)
            }

            Picker(selection: cleanupModelSelection) {
                Text("Off").tag("")
                ForEach(cleanupModels) { model in
                    Text(verbatim: model.label).tag(model.file)
                }
            } label: {
                Text("Clean up with")
                Text("A local model fixes punctuation and small slips. Adds a moment after you let go.")
            }
            if let model = state.llmModel, !model.isDownloaded,
               let asset = state.assets.first(where: { $0.id == AssetID.llm(file: model.file) }) {
                LabeledContent {
                    if state.activeDownload == asset.id {
                        AssetControl(state: state, status: asset)
                    } else {
                        Button("Download & Use") {
                            Task {
                                await Self.cleanupDownloadAction(file: model.file,
                                    selected: { state.llmModel?.file },
                                    download: { await state.download(asset.asset) },
                                    enable: { state.dictationCleanupEnabled = model.isCleanupCompatible() })
                            }
                        }
                        .disabled(state.activeDownload != nil)
                    }
                } label: {
                    Text(verbatim: model.label)
                    Text(verbatim: model.sizeText)
                }
            }
        } header: {
            Text("Processing")
        }
    }

    // MARK: Bubble

    private var showsBubble: Binding<Bool> {
        Binding(get: { !state.dictationStyle.hidden },
                set: { visible in
                    var updated = state.dictationStyle
                    updated.hidden = !visible
                    state.dictationStyle = updated
                })
    }

    @ViewBuilder
    private var bubble: some View {
        Section {
            Toggle(isOn: showsBubble) {
                Text("Show bubble")
                Text("A small bubble shows that Syllivra is listening, then the result.")
            }
            if showsBubble.wrappedValue {
                BubbleStylePicker(style: $state.dictationStyle, context: .dictation)
                BubbleTextSizeSlider(style: $state.dictationStyle, context: .dictation)
                LabeledContent("Preview") {
                    Button("Show Preview") {
                        NotificationCenter.default.post(name: .saiityDictationPreview, object: nil)
                    }
                }
            }
        } header: {
            Text("Bubble")
        }
    }

    // MARK: Advanced

    @ViewBuilder
    private var advanced: some View {
        Section {
            DisclosureGroup("Advanced", isExpanded: $showsAdvanced) {
                Picker("Recognition", selection: $state.dictationRecognizer) {
                    Text("Streaming").tag(DictationRecognizer.streaming)
                    Text("Whisper Auto").tag(DictationRecognizer.whisper)
                }
                if state.dictationRecognizer == .streaming {
                    Picker("Speech model", selection: $state.dictationEngine) {
                        Text("Not set").tag(Optional<ASREngine>.none)
                        ForEach(ASREngine.userSelectableCases, id: \.self) { engine in
                            Text(verbatim: engine.displayName).tag(Optional(engine))
                        }
                    }
                    .help(state.dictationEngine?.summary ?? ASREngine.recommended.summary)
                    if state.dictationEngine == .nemotron {
                        Picker("Update speed", selection: $state.dictationNemotronTier) {
                            Text("Balanced").tag(2240)
                            Text("Realtime").tag(1120)
                        }
                    }
                    Toggle(isOn: $state.dictationRealtimeText) {
                        Text("Show words while speaking")
                        Text("The finished text replaces them when you let go.")
                    }
                } else {
                    Picker("Whisper model", selection: Binding(
                        get: { WhisperDictationBackend.model },
                        set: { WhisperDictationBackend.model = $0 })) {
                        ForEach(WhisperDictationBackend.ModelChoice.allCases, id: \.self) { choice in
                            Text(choice.description.capitalized).tag(choice)
                        }
                    }
                    Picker("Language", selection: Binding(get: { WhisperDictationBackend.locale },
                                                          set: { WhisperDictationBackend.locale = $0 })) {
                        Text("Automatic").tag("auto")
                        ForEach(whisperSourceLanguages, id: \.code) { language in
                            Text(language.displayName).tag(language.code)
                        }
                    }
                }
                Picker("Translate with", selection: Binding(
                    get: { translationEngine },
                    set: { state.dictationTranslationEngine = $0 })) {
                    ForEach(TranslationEngine.userSelectableCases, id: \.self) { engine in
                        Text(engine.displayName).tag(engine)
                    }
                }
                .help(translationEngine.summary)
                LabeledContent {
                    Button("Edit…") { showsVocabulary = true }
                } label: {
                    Text("Vocabulary")
                    Text("Names and terms to spell your way.")
                }
                LabeledContent {
                    Button("Manage…") { state.showLocalModels = true }
                } label: {
                    Text("Cleanup models")
                }
                applicationExceptions
                Toggle(isOn: $state.keepRecentDictations) {
                    Text("Keep the last 5 dictations")
                    Text("Only in memory, until you quit.")
                }
                if state.keepRecentDictations {
                    LabeledContent("Recent dictations") {
                        Button("Show…") {
                            recentCopyNote = nil
                            state.showsRecentDictations = true
                        }
                    }
                }
                BubbleSurfaceControls(style: $state.dictationStyle)
                LabeledContent("Bubble") {
                    Button("Reset Appearance") { state.dictationStyle = CaptionStyle.dictationDefaults }
                }
            }
        }
    }

    @ViewBuilder
    private var applicationExceptions: some View {
        LabeledContent {
            Button("Add App…", action: addOriginalTextApplication)
        } label: {
            Text("Original text in these apps")
            Text("No cleanup, vocabulary or translation for recordings started there.")
        }
        ForEach(state.originalTextApplications, id: \.self) { id in
            LabeledContent {
                Button("Remove") { state.originalTextApplications.removeAll { $0 == id } }
            } label: {
                Text(verbatim: NSWorkspace.shared.urlForApplication(withBundleIdentifier: id)
                    .map { FileManager.default.displayName(atPath: $0.path) } ?? id)
            }
        }
    }

    private var vocabularySheet: some View {
        SheetShell(title: "Vocabulary",
                   subtitle: "Used by captions and dictation.",
                   width: 520, height: 460) {
            ScrollView {
                VocabularyEditor()
                    .padding(16)
            }
        }
    }

    private var recentDictationsSheet: some View {
        SheetShell(title: "Recent Dictations", subtitle: "Kept only in memory until you quit Syllivra.",
                   width: 600, height: 480, minimumSize: CGSize(width: 460, height: 320)) {
            VStack(alignment: .leading, spacing: 12) {
                if state.recentDictations.isEmpty {
                    ContentUnavailableView("No Recent Dictations", systemImage: "clock",
                        description: Text("Your next dictations appear here until you quit."))
                } else {
                    List(Array(state.recentDictations.reversed())) { entry in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(entry.completedAt.formatted(date: .omitted, time: .shortened))
                                .foregroundStyle(.secondary)
                            Text(verbatim: entry.result.outputText).textSelection(.enabled)
                            HStack {
                                Button("Copy Result") { copyRecentText(entry.result.outputText) }
                                if let original = entry.result.originalForRecovery {
                                    Button("Copy Original") { copyRecentText(original) }
                                }
                            }
                        }
                        .padding(.vertical, 6)
                    }
                    Button("Clear Recent Dictations") { state.recentDictations.removeAll() }
                }
                if let note = recentCopyNote {
                    Text(verbatim: note).foregroundStyle(.secondary)
                }
            }
            .padding(16)
        }
    }

    // MARK: Helpers kept for tests and other pages

    private var whisperSourceLanguages: [AppLanguage] {
        var codes = WhisperDictationBackend.supportedLanguageCodes
        let chosen = WhisperDictationBackend.locale
        if WhisperDictationBackend.sourceLanguageCode(for: chosen) != nil { codes.insert(chosen) }
        return codes.map(AppLanguage.init(code:)).sorted {
            $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
        }
    }

    internal static func cleanupAssets(from assets: [AssetStatus]) -> [AssetStatus] {
        let selectedFile = LocalModel.cleanupSelected?.file
        let candidateIDs = Set(LocalModel.all
            .filter { !$0.isLegacy || $0.file == selectedFile }
            .filter { $0.isCleanupCandidate() }
            .map { AssetID.llm(file: $0.file) })
        return assets.filter { candidateIDs.contains($0.asset.id) }
    }

    private var cleanupModels: [LocalModel] {
        LocalModel.all.filter { !$0.isLegacy || $0 == state.llmModel }
    }

    /// Off is part of the menu: picking a model turns cleanup on, Off turns it
    /// off. A model that is chosen but not downloaded stays shown, with its
    /// download row underneath, instead of snapping back to Off.
    private var cleanupDisplayedFile: String {
        guard let model = state.llmModel else { return "" }
        if model.isDownloaded, !state.dictationCleanupEnabled { return "" }
        return model.file
    }

    private var cleanupModelSelection: Binding<String> {
        Binding(
            get: { cleanupDisplayedFile },
            set: { file in
                state.llmModel = cleanupModels.first { $0.file == file }
                state.dictationCleanupEnabled = state.llmModel != nil
            })
    }

    static func cleanupDownloadAction(file: String,
                                      selected: () -> String?,
                                      download: () async -> Bool,
                                      enable: () -> Void) async {
        guard await download(), selected() == file else { return }
        enable()
    }

    internal static func downloadAction(_ choice: WhisperDictationBackend.ModelChoice, prepare: (WhisperDictationBackend.ModelChoice) async throws -> Void, refresh: () -> Void, setError: (Error) -> Void) async {
        do { try await prepare(choice) } catch { setError(error) }
        refresh()
    }

    internal static func retryAction(_ choice: WhisperDictationBackend.ModelChoice, clearError: () -> Void, prepare: (WhisperDictationBackend.ModelChoice) async throws -> Void, refresh: () -> Void, setError: (Error) -> Void) async {
        clearError()
        await downloadAction(choice, prepare: prepare, refresh: refresh, setError: setError)
    }

    internal static func removeAction(_ choice: WhisperDictationBackend.ModelChoice, invalidate: () async -> Void, remove: (WhisperDictationBackend.ModelChoice) async throws -> Void, refresh: () -> Void, setError: (Error) -> Void) async throws {
        await invalidate()
        do { try await remove(choice) } catch { setError(error); refresh(); throw error }
        refresh()
    }

    internal static func permissionRecoveryAction(_ pane: String, open: (String) -> Void) { open(pane) }
    internal static func notReadyAction(selectModels: () -> Void) { selectModels() }

    static func profileExplanation(_ profile: DictationProfile) -> String {
        switch profile {
        case .fast: String(localized: "Words appear quickly. No cleanup.")
        case .balanced: String(localized: "Quick words, then cleanup if a model is chosen.")
        case .accurate: String(localized: "Listens to the whole recording, then cleans it up. Slower.")
        case .custom: String(localized: "Your own recognition, speed and cleanup settings.")
        }
    }

    private func copyRecentText(_ text: String) {
        recentCopyNote = TextInserter().copy(text).outcome == .copied
            ? String(localized: "Copied to Clipboard") : String(localized: "Copy failed — try again.")
    }

    private func addOriginalTextApplication() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.applicationBundle]
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.prompt = String(localized: "Add Application")
        guard panel.runModal() == .OK, let url = panel.url, let id = Bundle(url: url)?.bundleIdentifier else { return }
        state.originalTextApplications.append(id)
    }
}
