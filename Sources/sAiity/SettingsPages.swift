import AppKit
import AVFoundation
import ApplicationServices
import Carbon.HIToolbox
import CoreGraphics
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Models

/// Everything this app has put on disk, in one place.
///
/// Every row is the same shape and comes from the same registry, so an asset
/// cannot go missing from this page the way MADLAD did — it was downloadable,
/// 1.86 GB, and had no row at all. Assets macOS owns are shown separately and
/// honestly: they can be measured but no app can delete them.
struct ModelsView: View {
    @Bindable var state: AppState
    @State private var showsModelDetails = false

    /// Recommended first, otherwise registry order. The Recognition section
    /// used to open with the fast Nemotron tier — the ~640 MB variant whose own
    /// description warns it costs roughly double the encoder work — above the
    /// balanced one that is actually the right first download.
    private func assets(_ family: ModelAsset.Family) -> [AssetStatus] {
        state.assets.filter { $0.asset.family == family }
            .enumerated()
            .sorted { a, b in
                a.element.asset.recommended == b.element.asset.recommended
                    ? a.offset < b.offset
                    : a.element.asset.recommended
            }
            .map(\.element)
    }

    private var interruptedDownloads: [AssetStatus] {
        state.assets.filter(\.isPartial)
    }

    private var interruptedBytes: Int64 {
        interruptedDownloads.reduce(0) { $0 + $1.bytesOnDisk } + state.retiredPartialBytes
    }

    @ViewBuilder
    private func modelGroup(_ title: LocalizedStringKey, family: ModelAsset.Family) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.subheadline.weight(.semibold))
            ForEach(assets(family)) { assetRow($0) }
        }
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 20) {
                HStack(alignment: .center, spacing: 14) {
                    Image(systemName: "internaldrive")
                        .font(.title3)
                        .foregroundStyle(.tint)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Local model inventory")
                            .font(.headline)
                        Label("On this Mac", systemImage: "lock.shield")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 12)
                    VStack(alignment: .trailing, spacing: 3) {
                        Text(state.ownedTotal)
                            .font(.title3.weight(.semibold))
                            .monospacedDigit()
                        if let stray = state.strayTotal {
                            Text("Other files: \(stray) — retired or incomplete downloads.")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        HStack(spacing: 8) {
                            if state.isModelsLoading {
                                ProgressView()
                                    .controlSize(.small)
                                    .accessibilityLabel("Refreshing models")
                            } else {
                                Button {
                                    Task { await state.refreshModelsAsync(force: true) }
                                } label: {
                                    Label("Refresh", systemImage: "arrow.clockwise")
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                                .help("Check downloaded models again")
                            }
                        }
                    }
                }
                .padding(16)
                .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(Color(nsColor: .separatorColor).opacity(0.4), lineWidth: 0.5)
                }

                if state.assets.isEmpty && state.isModelsLoading {
                    HStack(spacing: 10) {
                        ProgressView()
                        Text("Checking downloaded models…")
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, minHeight: 120)
                }

                SettingsSection(title: "Models") {
                    modelGroup("Recognition", family: .recognition)
                    Divider()
                    modelGroup("Translation", family: .translation)
                    if !assets(.cleanup).isEmpty {
                        Divider()
                        modelGroup("Dictation cleanup", family: .cleanup)
                    }
                }

                SettingsDisclosure(isExpanded: $showsModelDetails) {
                    SettingsSection(title: "Models") {
                        if !interruptedDownloads.isEmpty || state.retiredPartialBytes > 0 {
                            Button("Clear Interrupted…", role: .destructive) {
                                confirmClearInterrupted()
                            }
                            .controlSize(.small)
                            .disabled(state.isModelsLoading || state.hasActiveDownloads)
                            .help("Delete interrupted downloads without removing completed models.")
                        }
                        if state.ownedBytes > 0 {
                            Button("Remove All…", role: .destructive) { confirmRemoveAll() }
                                .controlSize(.small)
                        }
                        Button("Manage") { state.showLocalModels = true }
                            .controlSize(.small)
                    }
                }

                if let e = state.modelError {
                    SettingsSection(title: "Model issue",
                                    subtitle: "The last model operation needs attention.") {
                        Label(e, systemImage: "exclamationmark.triangle")
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 8)
            .frame(maxWidth: 780, alignment: .leading)
        }
        .task { await state.refreshModelsAsync() }
        .sheet(isPresented: $state.showLocalModels) { LocalModelsView(state: state) }
    }

    @ViewBuilder
    private func assetRow(_ s: AssetStatus) -> some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(s.asset.title).font(.body.weight(.medium))
                    // Two independent facts, two badges. State first: "in use"
                    // used to be shown for the stored preference alone, so a
                    // fresh install badged two rows that had no bytes behind
                    // them, right next to their own "634 MB to download" line.
                    if s.asset.use.isSelected, s.isInstalled {
                        badge("in use")
                    } else if s.asset.use.isSelected {
                        badge("selected")
                    }
                    // Then the suggestion, which is a property of the model and
                    // not of this disk — so it stays visible after downloading,
                    // where it answers "which of these should I pick?" rather
                    // than "which should I fetch?".
                    if s.asset.recommended { badge("recommended") }
                }
                Text(s.asset.detail).font(.caption).foregroundStyle(.secondary)
                sizeLine(s)
                // Downloading a multi-gigabyte model is agreeing to somebody's
                // terms; say whose before the button is pressed, not after.
                if let lic = s.asset.licence {
                    Text(lic).font(.caption2).foregroundStyle(.tertiary)
                }
            }
            Spacer(minLength: 12)
            trailingControl(s)
        }
        .padding(.vertical, 3)
    }

    private func badge(_ text: LocalizedStringKey) -> some View {
        Text(text).font(.caption2)
            .padding(.horizontal, 6).padding(.vertical, 1)
            .background(.tint.opacity(0.2), in: Capsule())
    }

    @ViewBuilder
    private func sizeLine(_ s: AssetStatus) -> some View {
        if s.isPartial {
            Text("Partial download — \(ModelRegistry.format(s.bytesOnDisk)) saved · Resume continues where it stopped")
                .font(.caption2).foregroundStyle(.orange)
        } else if s.bytesOnDisk > 0 {
            Text(ModelRegistry.format(s.bytesOnDisk)).font(.caption2).foregroundStyle(.tertiary)
        } else if let b = s.asset.advertisedBytes {
            Text("\(ModelRegistry.format(b)) to download").font(.caption2).foregroundStyle(.tertiary)
        }
    }

    private func trailingControl(_ s: AssetStatus) -> some View {
        AssetControl(state: state, status: s)
    }

    private func confirmClearInterrupted() {
        let total = ModelRegistry.format(interruptedBytes)
        let a = NSAlert()
        a.messageText = String(localized: "Clear interrupted downloads?")
        a.informativeText = String(localized: "This frees \(total). Completed models stay installed.")
        a.alertStyle = .warning
        a.addButton(withTitle: String(localized: "Clear Interrupted"))
        a.addButton(withTitle: String(localized: "Cancel"))
        guard a.runModal() == .alertFirstButtonReturn else { return }
        Task {
            if let freed = await state.clearInterruptedDownloads(), freed > 0 {
                let done = NSAlert()
                done.messageText = String(localized: "Cleared \(ModelRegistry.format(freed)) of interrupted downloads.")
                done.addButton(withTitle: String(localized: "OK"))
                _ = done.runModal()
            }
        }
    }

    /// Names the real figure before doing anything irreversible, and says up
    /// front what is NOT included — otherwise "remove all" that leaves several
    /// gigabytes of Apple assets behind reads as a bug.
    private func confirmRemoveAll() {
        let total = ModelRegistry.format(state.ownedBytes)
        let a = NSAlert()
        a.messageText = String(localized: "Remove all downloaded models?")
        a.informativeText = String(localized: "This frees \(total).\n\nAnything you use again will be downloaded once more.")
        a.alertStyle = .warning
        a.addButton(withTitle: String(localized: "Remove All"))
        a.addButton(withTitle: String(localized: "Cancel"))
        guard a.runModal() == .alertFirstButtonReturn else { return }
        Task {
            if let freed = await state.removeAllDownloads() {
                let done = NSAlert()
                done.messageText = String(localized: "Removed \(ModelRegistry.format(freed)).")
                done.addButton(withTitle: String(localized: "OK"))
                _ = done.runModal()
            }
        }
    }
}

// MARK: - Appearance

@MainActor
struct DictationView: View {
    @Bindable var state: AppState
    var onDetailVisibilityChanged: (Bool) -> Void = { _ in }

    // Permission checks can involve TCC IPC. Keep the answers in observable
    // view state instead of probing from `body`, which SwiftUI may evaluate
    // many times while the page is opening.
    @State private var inputMonitoringGranted: Bool?
    @State private var accessibilityGranted: Bool?
    @State private var whisperReady: Bool?
    @State private var whisperBusy = false
    @State private var showsProcessingDetails = false
    @State private var recentCopyNote: String?

    private func openModels() {
        SettingsWindowController.selectModelsPane()
    }

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

    /// What the row displays. Empty is what makes the menu read "Off".
    ///
    /// Three states, not two. `enforceSettingsHonesty()` clamps
    /// `dictationCleanupEnabled` to `llmModel.isDownloaded`, so a model that
    /// is not on this Mac yet always reads as disabled. Showing "Off" for
    /// that would swallow the pick the moment it was made — the user would
    /// choose a model and watch the menu snap back with no explanation. That
    /// one case shows the model and the download notice instead, which is
    /// the truth: the choice is stored, it just cannot run yet.
    private var cleanupDisplayedFile: String {
        guard let model = state.llmModel else { return "" }
        if model.isDownloaded, !state.dictationCleanupEnabled { return "" }
        return model.file
    }

    /// The picker carries the on/off state as well as the model: "Off" means
    /// cleanup is off, and picking a model turns it back on.
    /// `dictationCleanupEnabled` stays a real property — it gates the runtime
    /// and feeds `dictationProfile` — it just is not a separate control,
    /// because a switch beside a model menu invites the combination "cleanup
    /// on, no model", which the runtime then quietly drops back to the
    /// deterministic pass.
    private var cleanupModelSelection: Binding<String> {
        Binding(
            get: { cleanupDisplayedFile },
            set: { file in
                state.llmModel = cleanupModels.first { $0.file == file }
                state.dictationCleanupEnabled = state.llmModel != nil
            })
    }

    /// The tooltip has to exist in every state: `.help("")` puts a blank
    /// entry in the help menu, and when the row reads "Off" the model note
    /// would be describing something the row is not showing.
    private var cleanupHelp: String {
        guard !cleanupDisplayedFile.isEmpty, let model = state.llmModel else {
            return String(localized: "Choose a local model to clean up dictated text.")
        }
        return model.note
    }

    private var whisperReadinessID: String {
        "\(state.dictationRecognizer.rawValue)|\(WhisperDictationBackend.model.rawValue)"
    }

    static func cleanupDownloadAction(file: String,
                                      selected: () -> String?,
                                      download: () async -> Bool,
                                      enable: () -> Void) async {
        guard await download(), selected() == file else { return }
        enable()
    }

    @ViewBuilder
    private var cleanupModelControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Selection and repair stay in Quick controls; only model notes live here.
            if let model = state.llmModel {
                HStack(alignment: .top, spacing: 8) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(model.note).font(.caption).foregroundStyle(.secondary)
                        Text(model.sizeText).font(.caption2).foregroundStyle(.tertiary)
                    }
                    Spacer(minLength: 8)
                }
            }

            Button("Manage") { state.showLocalModels = true }
                .buttonStyle(.bordered)
                .controlSize(.small)
        }
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

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                quickSettings
                SettingsDisclosure(isExpanded: $showsProcessingDetails) {
                    detailSettings
                }
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 8)
            .frame(maxWidth: 780, alignment: .leading)
        }
        .onAppear {
            onDetailVisibilityChanged(showsProcessingDetails)
        }
        .onChange(of: showsProcessingDetails) { _, expanded in
            onDetailVisibilityChanged(expanded)
        }
        .task {
            refreshPermissions()
            await state.refreshModelsAsync()
        }
        .task(id: whisperReadinessID) {
            guard state.dictationRecognizer == .whisper else {
                whisperReady = nil
                return
            }
            await refreshWhisperStatus()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            refreshPermissions()
        }
        .sheet(isPresented: $state.showDictationTranslationPicker) {
            TranslationTargetPicker(state: state,
                                    target: $state.dictationTranslateTo,
                                    title: "Translate dictation to",
                                    scope: .dictation)
        }
        .sheet(isPresented: $state.showLocalModels) {
            LocalModelsView(state: state)
        }
        .sheet(isPresented: $state.showsRecentDictations) {
            recentDictationsSheet.onAppear { recentCopyNote = nil }
        }
    }

    private var recentDictationsSheet: some View {
        SheetShell(title: "Recent Dictations", subtitle: "Kept only in memory until you quit Syllivra.",
                   width: 600, height: 480, minimumSize: CGSize(width: 460, height: 320)) {
            VStack(alignment: .leading, spacing: 12) {
                if state.recentDictations.isEmpty {
                    ContentUnavailableView("No Recent Dictations", systemImage: "clock",
                        description: Text("Enable recent dictations in More options to keep your next results until quitting."))
                } else {
                    List(Array(state.recentDictations.reversed())) { entry in
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text(entry.completedAt.formatted(date: .omitted, time: .shortened))
                                    .foregroundStyle(.secondary)
                                Spacer()
                                Text(entry.delivery.outcome == .insertedAndCopied ? String(localized: "Copied — paste requested") :
                                     entry.delivery.outcome == .copyFailed ? String(localized: "Copy failed") : String(localized: "Copied to Clipboard"))
                                    .font(.callout)
                            }
                            Text(verbatim: entry.result.outputText).textSelection(.enabled)
                            HStack {
                                Button("Copy Result") { copyRecentText(entry.result.outputText) }
                                if let original = entry.result.originalForRecovery {
                                    Button("Copy Original") { copyRecentText(original) }
                                }
                            }
                            .buttonStyle(.bordered)
                        }
                        .padding(.vertical, 8)
                    }
                    Button("Clear Recent Dictations") { state.recentDictations.removeAll() }
                        .buttonStyle(.bordered)
                }
                if let note = recentCopyNote {
                    Label(note, systemImage: "doc.on.clipboard").font(.callout)
                }
            }
            .padding(16)
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

    private var recoveryAndApplications: some View {
        SettingsSection(title: "Recovery") {
            Toggle("Keep the last 5 dictations until quitting", isOn: $state.keepRecentDictations)
            Text("Off by default. Results stay in memory only; turning this off clears the recent list.")
                .font(.callout).foregroundStyle(.secondary)
            Button("Recent Dictations…") {
                recentCopyNote = nil
                state.showsRecentDictations = true
            }
        }
    }

    private var applicationExceptions: some View {
        SettingsSection(title: "Application Exceptions",
                        subtitle: "Use original recognition text in these apps. Cleanup, corrections and translation are off for each recording started there.") {
            ForEach(state.originalTextApplications, id: \.self) { id in
                HStack {
                    Text(verbatim: NSWorkspace.shared.urlForApplication(withBundleIdentifier: id)
                        .map { FileManager.default.displayName(atPath: $0.path) } ?? id)
                    Spacer()
                    Button("Remove") { state.originalTextApplications.removeAll { $0 == id } }
                }
            }
            Button("Add Application…", action: addOriginalTextApplication).buttonStyle(.bordered)
        }
    }

    @ViewBuilder
    private var detailSettings: some View {
        VStack(alignment: .leading, spacing: 20) {
            recoveryAndApplications
            applicationExceptions
            SettingsSection(title: "Recognition") {
                HStack {
                    Label("Dictation engine", systemImage: "arrow.triangle.branch")
                    Spacer()
                    Picker("Dictation engine", selection: $state.dictationRecognizer) {
                        Text("Streaming").tag(DictationRecognizer.streaming)
                        Text("Whisper Auto").tag(DictationRecognizer.whisper)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }
                if state.dictationRecognizer == .streaming {
                    HStack {
                        Label("Recognition model", systemImage: "cpu")
                        Spacer()
                        Picker("Recognition model", selection: $state.dictationEngine) {
                            Text("Not set").tag(Optional<ASREngine>.none)
                            ForEach(ASREngine.userSelectableCases, id: \.self) { engine in
                                Text(verbatim: engine.displayName).tag(Optional(engine))
                            }
                        }
                        .pickerStyle(.menu)
                        .labelsHidden()
                        .help(state.dictationEngine?.summary ?? ASREngine.recommended.summary)
                    }
                    if state.dictationEngine == .nemotron {
                        Picker("Subtitle timing", selection: $state.dictationNemotronTier) {
                            Text("Balanced").tag(2240)
                            Text("Realtime").tag(1120)
                        }
                        .pickerStyle(.segmented)
                    }
                    Toggle("Realtime text", isOn: $state.dictationRealtimeText)
                        .help("The words appear as they are spoken, and the finished text replaces them when dictation ends.")
                }
                if state.dictationRecognizer == .whisper {
                    Picker("Whisper model", selection: Binding(
                        get: { WhisperDictationBackend.model },
                        set: { choice in
                            WhisperDictationBackend.model = choice
                            Task { await refreshWhisperStatus() }
                        })) {
                        ForEach(WhisperDictationBackend.ModelChoice.allCases, id: \.self) { choice in
                            Text(choice.description.capitalized).tag(choice)
                        }
                    }
                    .pickerStyle(.segmented)
                    Picker("Language", selection: Binding(get: { WhisperDictationBackend.locale }, set: { WhisperDictationBackend.locale = $0 })) {
                        Text("Automatic").tag("auto")
                        ForEach(whisperSourceLanguages, id: \.code) { language in
                            Text(language.displayName).tag(language.code)
                        }
                    }
                }
            }
            SettingsSection(title: "Translation") {
                translationSettings.engineControls
            }

            SettingsSection(title: "Cleanup details") {
                cleanupModelControls
                VocabularyEditor()
            }

            SettingsSection(title: "Bubble appearance",
                            subtitle: "Fine-tune the result bubble and its interaction.") {
                LabeledToggle("Show dictation bubble",
                              "Shows the result and waveform after dictation finishes.",
                              showsNote: false,
                              isOn: Binding(get: { !state.dictationStyle.hidden },
                                            set: { visible in
                                                   var updated = state.dictationStyle
                                                   updated.hidden = !visible
                                                   state.dictationStyle = updated
                                             }))
                Text("Layout").font(.subheadline.weight(.medium))
                BubbleSurfaceControls(style: $state.dictationStyle)
                HStack {
                    Button("Preview") {
                        NotificationCenter.default.post(name: .saiityDictationPreview, object: nil)
                    }
                    .buttonStyle(.bordered)
                    Spacer()
                    ResetButton { state.dictationStyle = CaptionStyle.dictationDefaults }
                }
            }

            SettingsSection(title: "Permissions",
                            subtitle: "Needed only for the global shortcut and text insertion.") {
                permissionRow(title: "Input Monitoring",
                              granted: inputMonitoringGranted,
                              explanation: "Required to detect the shortcut in other apps.") {
                    _ = CGRequestListenEventAccess()
                    Self.permissionRecoveryAction("Privacy_ListenEvent", open: openPrivacySettings)
                }
                permissionRow(title: "Accessibility",
                              granted: accessibilityGranted,
                              explanation: "Required to paste into the focused text field.") {
                    Self.permissionRecoveryAction("Privacy_Accessibility", open: openPrivacySettings)
                }
                HStack {
                    Label("Microphone", systemImage: "mic")
                    Spacer()
                    Text("Only while dictating")
                        .foregroundStyle(.secondary)
                }
                HStack {
                    Label("Processing", systemImage: "lock.shield")
                    Spacer()
                    Text("On this Mac")
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
    @ViewBuilder
    private var quickSettings: some View {
        SettingsSection(title: "Quick controls") {
            HStack {
                Label("Enabled", systemImage: state.dictationEnabled ? "mic.fill" : "mic.slash")
                    .font(.body.weight(.medium))
                Spacer()
                Toggle("Enabled", isOn: $state.dictationEnabled)
                    .labelsHidden()
                    .toggleStyle(.switch)
            }
            HStack {
                Label("Shortcut", systemImage: "command")
                    .foregroundStyle(.secondary)
                Spacer()
                DictationShortcutRecorder(state: state)
                    .frame(width: 220, height: 30)
            }
            Button("Try Dictation") { OnboardingWindowController.shared.show(state: state, trial: .dictation) }
                .buttonStyle(.bordered)
                .disabled(CaptionSession.shared.isRunning || CaptionSession.shared.isProcessingTranscript)
            if state.dictationUsesOriginalText {
                Label("Original text for this app · cleanup and translation off", systemImage: "text.quote")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Picker("Dictation profile", selection: Binding(
                get: { state.dictationProfile },
                set: { state.dictationProfile = $0 })) {
                ForEach(DictationProfile.allCases.filter { $0 != .custom }, id: \.self) { profile in
                    Text(profile.displayName).tag(profile)
                        .help(Self.profileExplanation(profile))
                }
            }
            .pickerStyle(.segmented)
            Text(Self.profileExplanation(state.dictationProfile))
                .font(.caption).foregroundStyle(.secondary)
            if state.dictationRecognizer == .whisper {
                Text("Using Whisper Auto · \(WhisperDictationBackend.model.description.capitalized)")
                    .font(.caption).foregroundStyle(.secondary)
                whisperStatus
            } else {
                let engine = state.dictationEngine ?? ASREngine.dictationEffective
                Text("Using \(engine.displayName)")
                    .font(.caption).foregroundStyle(.secondary)
                ForEach(engine.assetDescriptors.filter {
                    engine != .nemotron || $0.id == AssetID.nemotron(chunkMs: state.dictationNemotronTier)
                }, id: \.id) { asset in
                    let status = state.assets.first(where: { $0.id == asset.id }) ?? ModelRegistry.status(of: asset)
                    if state.needsModelRepair(status) {
                        HStack {
                            Text(asset.title).font(.caption).foregroundStyle(.secondary)
                            Spacer()
                            AssetControl(state: state, status: status)
                        }
                    }
                }
            }
            if state.dictationProfile == .custom {
                Label("Custom settings", systemImage: "slider.horizontal.3")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Divider()

            Toggle("Translate dictated text", isOn: $state.translateDictation)
                .disabled(state.dictationTranslateTo?.isEmpty != false)
            translationSettings.targetControls

            Divider()

            // One row where there was a switch and a read-only model name.
            // The name was the same dead end as the two pickers above: it
            // printed which model cleanup would use and gave no way to change
            // it, so the only place to choose sat behind the disclosure. The
            // switch is "Off" in this menu — see `cleanupModelSelection` for
            // why those are one control rather than two.
            HStack {
                Label("Clean up with", systemImage: "cpu")
                Spacer()
                Picker("Clean up with", selection: cleanupModelSelection) {
                    Text("Off").tag("")
                    ForEach(cleanupModels) { model in
                        Text(model.label).tag(model.file)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .help(cleanupHelp)
            }
            // The one state where the row shows a model that cannot run:
            // `enforceSettingsHonesty()` has already forced
            // `dictationCleanupEnabled` false, so without this the row would
            // read as a live selection that quietly does nothing.
            if let model = state.llmModel, !model.isDownloaded {
                HStack {
                    Text(model.sizeText).font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    if let asset = state.assets.first(where: { $0.id == AssetID.llm(file: model.file) }) {
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
                    }
                }
            }
        }
        SettingsSection(title: "Bubble appearance") {
            BubbleStylePresetControl(style: $state.dictationStyle, context: .dictation)
        }
    }

    private var translationSettings: TranslationSettingsRows {
        TranslationSettingsRows(target: $state.dictationTranslateTo,
                                engine: Binding(
                                    get: { state.dictationTranslationEngine ?? TranslationEngine.dictationEffective },
                                    set: { state.dictationTranslationEngine = $0 }),
                                engines: TranslationEngine.userSelectableCases, state: state) {
            state.showDictationTranslationPicker = true
        }
    }

    static func profileExplanation(_ profile: DictationProfile) -> String {
        switch profile {
        case .fast: String(localized: "Streams words with faster updates and skips model cleanup.")
        case .balanced: String(localized: "Streams words with more context per update, then uses available cleanup.")
        case .accurate: String(localized: "Recognizes the full recording after release, then uses available cleanup.")
        case .custom: String(localized: "Uses your chosen recognition, timing and cleanup settings.")
        }
    }

    @ViewBuilder
    private var whisperStatus: some View {
        let choice = WhisperDictationBackend.model
        let ready = whisperReady
        HStack(spacing: 10) {
            if whisperBusy {
                ProgressView()
                    .controlSize(.small)
                Text("Preparing Whisper…")
                    .foregroundStyle(.secondary)
            } else if ready == nil {
                ProgressView()
                    .controlSize(.small)
                Text("Checking Whisper…")
                    .foregroundStyle(.secondary)
            } else {
                Label(ready == true ? "Ready" : "Model needed",
                      systemImage: ready == true ? "checkmark.circle.fill" : "arrow.down.circle")
                    .foregroundStyle(ready == true ? .green : .orange)
            }
            Spacer()
            if ready == true {
                Button("Remove") {
                    Task { try? await removeWhisper(choice) }
                }
                .controlSize(.small)
                .disabled(whisperBusy || CaptionSession.shared.isRemovingModels)
            } else if ready == false {
                Button("Download") { prepareWhisper(choice) }
                    .controlSize(.small)
                    .disabled(whisperBusy || CaptionSession.shared.isRemovingModels)
                Button("Retry") { retryWhisper(choice) }
                    .controlSize(.small)
                    .disabled(whisperBusy || CaptionSession.shared.isRemovingModels)
            }
            Button("Models") { openModels() }
                .buttonStyle(.bordered)
                .controlSize(.small)
        }
    }

    @ViewBuilder
    private func permissionRow(title: LocalizedStringKey,
                               granted: Bool?,
                               explanation: LocalizedStringKey,
                               request: @escaping () -> Void) -> some View {
        let isGranted = granted == true
        let isChecking = granted == nil
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Label(title, systemImage: isGranted
                  ? "checkmark.circle.fill"
                  : isChecking ? "hourglass" : "exclamationmark.triangle.fill")
                .foregroundStyle(isGranted
                                 ? AnyShapeStyle(.secondary)
                                 : isChecking ? AnyShapeStyle(.secondary) : AnyShapeStyle(.orange))
            Spacer()
            if isGranted {
                Text("Allowed")
                    .foregroundStyle(.secondary)
            } else if isChecking {
                Text("Checking…")
                    .foregroundStyle(.secondary)
            } else {
                Button("Allow…", action: request)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
        }
        if granted == false {
            Text(explanation)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func refreshPermissions() {
        inputMonitoringGranted = CGPreflightListenEventAccess()
        accessibilityGranted = AXIsProcessTrusted()
    }

    private func refreshWhisperStatus() async {
        let choice = WhisperDictationBackend.model
        whisperReady = nil
        let ready = await Task.detached(priority: .utility) {
            WhisperDictationBackend.isReady(choice)
        }.value
        guard !Task.isCancelled, WhisperDictationBackend.model == choice else { return }
        whisperReady = ready
    }

    private func prepareWhisper(_ choice: WhisperDictationBackend.ModelChoice) {
        whisperBusy = true
        state.modelError = nil
        Task {
            await Self.downloadAction(choice, prepare: { choice in
                try await (NSApp.delegate as? AppDelegate)?.prepareSelectedWhisperModelForUse(choice)
            }, refresh: { Task { await state.refreshModelsAsync(force: true) } }, setError: { state.modelError = $0.localizedDescription })
            whisperBusy = false
            await refreshWhisperStatus()
        }
    }

    private func retryWhisper(_ choice: WhisperDictationBackend.ModelChoice) {
        whisperBusy = true
        Task {
            await Self.retryAction(choice, clearError: { state.modelError = nil }, prepare: { choice in
                try await (NSApp.delegate as? AppDelegate)?.prepareSelectedWhisperModelForUse(choice)
            }, refresh: { Task { await state.refreshModelsAsync(force: true) } }, setError: { state.modelError = $0.localizedDescription })
            whisperBusy = false
            await refreshWhisperStatus()
        }
    }

    private func removeWhisper(_ choice: WhisperDictationBackend.ModelChoice) async throws {
        whisperBusy = true
        defer {
            whisperBusy = false
            Task { await refreshWhisperStatus() }
        }
        // The shared transaction refuses a busy recording before invalidation.
        try await Self.removeAction(choice, invalidate: {}, remove: { choice in
            guard let asset = ModelRegistry.assets().first(where: { $0.id == AssetID.whisper(choice) }) else {
                throw BackendError.notPrepared
            }
            await state.delete(asset)
            if let error = state.modelError { throw TranslationEngineError.notAvailable(error) }
        }, refresh: { Task { await state.refreshModelsAsync(force: true) } }, setError: { state.modelError = $0.localizedDescription })
    }

    private func openPrivacySettings(_ pane: String) {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") else { return }
        NSWorkspace.shared.open(url)
    }
}

struct DictationShortcutRecorder: NSViewRepresentable {
    @Bindable var state: AppState

    func makeNSView(context: Context) -> RecorderView {
        let view = RecorderView()
        view.chord = state.dictationChord
        view.onChange = { state.dictationChord = $0 }
        return view
    }

    func updateNSView(_ view: RecorderView, context: Context) {
        view.chord = state.dictationChord
        view.refresh()
    }

    final class RecorderView: NSView {
        var chord = DictationChord.current
        var onChange: ((DictationChord) -> Void)?
        private var recording = false
        private var capture = DictationChordCaptureState()
        private var eventMonitor: Any?
        private let label = NSTextField(labelWithString: "")

        override init(frame: NSRect) {
            super.init(frame: frame)
            label.alignment = .center
            label.font = .monospacedSystemFont(ofSize: 12, weight: .medium)
            label.translatesAutoresizingMaskIntoConstraints = false
            addSubview(label)
            NSLayoutConstraint.activate([
                label.centerXAnchor.constraint(equalTo: centerXAnchor),
                label.centerYAnchor.constraint(equalTo: centerYAnchor),
                // Fixed, not a minimum. A `greaterThanOrEqualTo` inside an HStack
                // with a Spacer expanded to fill the row, so the recorder ran to
                // ~450 pt to hold five characters of key chord. A control the size
                // of its content is also a control, not a banner.
                widthAnchor.constraint(equalToConstant: 170),
                heightAnchor.constraint(equalToConstant: 28),
            ])
            wantsLayer = true
            layer?.cornerRadius = ShortcutRecorderChrome.cornerRadius
            refresh()
        }

        required init?(coder: NSCoder) { fatalError() }
        override var acceptsFirstResponder: Bool { true }

        override func hitTest(_ point: NSPoint) -> NSView? {
            super.hitTest(point) == nil ? nil : self
        }

        override func viewWillMove(toWindow newWindow: NSWindow?) {
            if newWindow == nil { endRecording() }
            NotificationCenter.default.removeObserver(self, name: NSWindow.didResignKeyNotification, object: window)
            if let newWindow {
                NotificationCenter.default.addObserver(self, selector: #selector(stopRecordingWhenWindowDeactivates(_:)),
                                                       name: NSWindow.didResignKeyNotification, object: newWindow)
            }
            super.viewWillMove(toWindow: newWindow)
        }

        @objc private func stopRecordingWhenWindowDeactivates(_ notification: Notification) {
            endRecording()
        }

        func refresh() {
            let assigned = chord.displayString
            let text = ShortcutRecorderChrome.label(
                assigned: assigned.isEmpty ? nil : assigned,
                recording: recording)
            label.stringValue = recording
                ? String(localized: "Press the full chord, then release…")
                : text.text
            label.textColor = text.isInvitation
                ? NSColor.controlAccentColor
                : NSColor.labelColor
            layer?.backgroundColor = ShortcutRecorderChrome.fill(
                recording: recording, assigned: !assigned.isEmpty)
            layer?.borderWidth = ShortcutRecorderChrome.borderWidth(recording: recording)
            layer?.borderColor = ShortcutRecorderChrome.border(
                recording: recording, assigned: !assigned.isEmpty)
        }

        override func mouseDown(with event: NSEvent) {
            beginRecording()
        }

        private func beginRecording() {
            guard !recording, let window, window.makeFirstResponder(self) else { return }
            recording = true
            capture.reset()
            HotKeyCenter.shared.setSuspended(true)
            eventMonitor = Shortcut.monitorEvents(in: self)
            NotificationCenter.default.post(name: .saiityDictationShortcutRecordingChanged,
                                            object: true)
            refresh()
        }

        private func endRecording() {
            guard recording else { return }
            recording = false
            capture.reset()
            if let eventMonitor { NSEvent.removeMonitor(eventMonitor) }
            eventMonitor = nil
            HotKeyCenter.shared.setSuspended(false)
            NotificationCenter.default.post(name: .saiityDictationShortcutRecordingChanged,
                                            object: false)
            refresh()
        }

        override func isAccessibilityElement() -> Bool { true }
        override func accessibilityRole() -> NSAccessibility.Role? { .button }
        override func accessibilityLabel() -> String? { String(localized: "Dictation shortcut") }
        override func accessibilityValue() -> Any? {
            recording ? String(localized: "Press the full chord, then release…") : chord.displayString
        }
        override func accessibilityHelp() -> String? {
            String(localized: "Press to record a new dictation shortcut. Press Escape to cancel.")
        }
        override func accessibilityPerformPress() -> Bool {
            beginRecording()
            return recording
        }

        override var focusRingMaskBounds: NSRect { bounds }
        override func drawFocusRingMask() {
            NSBezierPath(roundedRect: bounds, xRadius: 6, yRadius: 6).fill()
        }

        override func performKeyEquivalent(with event: NSEvent) -> Bool {
            guard recording, window?.firstResponder === self else { return false }
            keyDown(with: event)
            return true
        }

        override func flagsChanged(with event: NSEvent) {
            guard recording else { super.flagsChanged(with: event); return }
            let key = UInt16(event.keyCode)
            let isDown = DictationChord.modifierIsDown(key, flags: event.modifierFlags)
            commitIfReady(capture.handle(.flagsChanged(key, isDown: isDown)))
        }

        override func keyDown(with event: NSEvent) {
            if !recording, event.keyCode == UInt16(kVK_Space) || event.keyCode == UInt16(kVK_Return) {
                beginRecording()
                return
            }
            guard recording else { super.keyDown(with: event); return }
            if event.keyCode == UInt16(kVK_Escape) {
                endRecording()
                return
            }
            _ = capture.handle(.keyDown(UInt16(event.keyCode)))
        }

        override func keyUp(with event: NSEvent) {
            guard recording else { super.keyUp(with: event); return }
            commitIfReady(capture.handle(.keyUp(UInt16(event.keyCode))))
        }

        private func commitIfReady(_ chord: DictationChord?) {
            guard let chord else { refresh(); return }
            self.chord = chord
            onChange?(chord)
            endRecording()
        }

        override func resignFirstResponder() -> Bool {
            endRecording()
            return true
        }
    }
}

/// Everything about producing a caption, on one page: which engine, what
/// language, how it looks, and how to toggle it. Previously this was spread
/// across four tabs, which made a simple app feel like a control panel.
struct CaptionsView: View {
    @Bindable var state: AppState
    var onDetailVisibilityChanged: (Bool) -> Void = { _ in }
    @State private var diagnosticsRevision = 0
    @State private var showsProcessingDetails = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                primaryAction
                quickSettings
                SettingsDisclosure(isExpanded: $showsProcessingDetails) {
                    detailSettings
                }
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 8)
            .frame(maxWidth: 780, alignment: .leading)
        }
        .onAppear {
            onDetailVisibilityChanged(showsProcessingDetails)
        }
        .onChange(of: showsProcessingDetails) { _, expanded in
            onDetailVisibilityChanged(expanded)
        }
        .task(id: "\(state.translateTo ?? "")|\(state.translationEngine?.rawValue ?? "none")") {
            await state.refreshTargetSupport()
        }
        .onReceive(NotificationCenter.default.publisher(for: Diagnostics.changed)) { _ in
            diagnosticsRevision += 1
        }
        .sheet(isPresented: $state.showLocalModels) { LocalModelsView(state: state) }
        .sheet(isPresented: $state.showTranslationPicker) {
            TranslationTargetPicker(state: state,
                                    target: $state.translateTo,
                                    title: "Translate captions to")
        }
    }

    /// The pane's primary action: start or stop captioning.
    ///
    /// This pane configures captioning and, until it existed, offered no way to
    /// begin it — so the only routes in were learning the ⌥⌘C chord or finding
    /// the menu bar item. A settings page for the app's headline feature with no
    /// button for that feature is the wrong shape, whatever the arguments for
    /// keeping the menu bar quiet.
    ///
    /// Prominent because it is the one primary action here, and sized to its
    /// content rather than stretched: a full-width button reads as a page banner,
    /// and this is a control. The label is the same pair of words the menu bar
    /// uses, from the same session state, so the two can never disagree.
    private var primaryAction: some View {
        HStack {
            Button {
                NotificationCenter.default.post(name: .saiityToggleCaptions, object: nil)
            } label: {
                Label(CaptionSession.shared.isStopping ? "Stopping…" : state.isCaptioning ? "Stop captions" : "Start captions",
                      systemImage: state.isCaptioning ? "stop.fill" : "captions.bubble.fill")
                    .frame(minWidth: 132)
            }
            // `.borderedProminent`, not `.glassProminent`. Glass is translucent,
            // so a prominent glass button takes its colour from whatever is
            // behind it — over this dark settings surface it came out as a quiet
            // grey capsule, reading *quieter* than the shortcut recorders below.
            // The one control that starts captioning cannot be the quietest thing
            // on the pane. This one is accent-filled and unambiguous.
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(CaptionSession.shared.isStopping)
            VStack(alignment: .leading, spacing: 4) {
                Text(CaptionSession.shared.isStopping ? "Stopping…" : state.isCaptioning
                     ? "Captions are running."
                     : "Captions run on this Mac. Nothing is uploaded.")
                    .font(.callout)
                if CaptionSession.shared.translationBacklogged {
                    Label("Translation is too slow; some lines are untranslated. Original captions continue.", systemImage: "clock")
                        .font(.caption)
                }
            }
            .foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    private var detailSettings: some View {
        VStack(alignment: .leading, spacing: 20) {
            SettingsSection(title: "Recognition") {
                HStack {
                    Label("Recognition model", systemImage: "cpu")
                    Spacer()
                    Picker("Recognition model", selection: $state.engine) {
                        Text("Not set").tag(Optional<ASREngine>.none)
                        ForEach(ASREngine.userSelectableCases, id: \.self) { engine in
                            Text(verbatim: engine.displayName).tag(Optional(engine))
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    // The long version — why one model over another — is too long
                    // for a menu item and would become an interpolated key
                    // retranslated in four languages on every word change. It lives
                    // in the tooltip, on the Models page, and in the caption below.
                    .help(state.engine?.summary ?? ASREngine.recommended.summary)
                }
            }
            SettingsSection(title: "Translation") {
                translationSettings.engineControls
            }
            SettingsSection(title: "Shortcuts",
                            subtitle: "Global controls for starting and stopping captions.") {
                ForEach(HotKeyCenter.Action.allCases, id: \.self) { action in
                    HStack {
                        Text(action.title)
                        Spacer()
                        ShortcutRecorder(action: action, state: state)
                    }
                }
                if let e = state.shortcutError {
                    Text(e).font(.caption).foregroundStyle(.orange)
                }
            }

            SettingsSection(title: "Capture",
                            subtitle: "Choose which audio reaches the caption engine.") {
                Picker("Capture audio from", selection: $state.captureApp) {
                    Text("Everything the Mac plays").tag(String?.none)
                    ForEach(state.runningApps, id: \.bundleID) { app in
                        Text(app.name).tag(Optional(app.bundleID))
                    }
                }
                LabeledToggle("Include my microphone",
                              "Off by default. System audio on a call carries only the other participants — your own voice never enters the mix, so a saved transcript is missing your half of the conversation. On, Syllivra also opens the microphone (macOS asks once) and mixes it into recognition. Audio still never leaves this Mac. Takes effect immediately, including mid-session: switching it off releases the microphone straight away.",
                                                            isOn: $state.includeMic)
                LabeledToggle("Identify speakers",
                              "Adds local voice labels to captions and saved transcripts. Overlapping voices are marked; their words cannot be separated. Applies to the next caption session.",
                              isOn: $state.identifyCaptionSpeakers)
                    .disabled(state.isCaptioning)
                if state.identifyCaptionSpeakers, !CaptionSpeakerTracker.isInstalled {
                    Text("Download Speaker identification from Models first.")
                        .font(.caption).foregroundStyle(.secondary)
                    AssetControl(state: state, status: ModelRegistry.status(of: CaptionSpeakerTracker.asset))
                }
            }

            SettingsSection(title: "Sentences",
                            subtitle: "Use pauses to decide when a translated sentence is complete.") {
                LabeledToggle("End a sentence on a pause",
                              "Most of what the multilingual engine emits carries no punctuation, so a pause is what tells the app a thought has finished — and a finished sentence is what gets translated. Off, sentences close only on real punctuation and on the length cap, which suits a speaker who pauses mid-thought.",
                                                            isOn: $state.speechGapEnabled)
                if state.speechGapEnabled {
                    slider("Pause length", $state.speechGapHoldMs,
                           Double(SpeechGap.range.lowerBound)...Double(SpeechGap.range.upperBound),
                           readout: CaptionLatencyCopy.pauseLength(milliseconds:),
                           readoutWidth: 108)
                }
                HStack {
                    Spacer()
                    ResetButton {
                        state.speechGapEnabled = true
                        state.speechGapHoldMs = Double(SpeechGap.defaultHoldMs)
                    }
                }
            }

            SettingsSection(title: "Vocabulary",
                            subtitle: "Keep names and technical terms consistent across captions and dictation.") {
                VocabularyEditor()
            }

            appearanceSections

            captionPerformanceSection
        }
    }
    @ViewBuilder
    private var captionPerformanceSection: some View {
        let revision = diagnosticsRevision
        let summaries = Diagnostics.recentTimingSummaries
        SettingsSection(title: "Performance",
                        subtitle: "Recent local caption timing from this Mac.") {
            if let lag = summaries.first(where: { $0.operation == "captions.visible-lag" }) {
                LabeledContent("Time until the caption appears") {
                    Text(verbatim: CaptionPerformanceCopy.duration(lag.p50))
                        .monospacedDigit()
                }
            }
            if let translation = summaries.first(where: { $0.operation == "captions.translation" }) {
                LabeledContent("Translation delay") {
                    Text(verbatim: CaptionPerformanceCopy.duration(translation.p50))
                        .monospacedDigit()
                }
            }
            if let rtf = summaries.first(where: { $0.operation == "captions.asr.rtf" }) {
                LabeledContent("Recognition speed") {
                    Text(verbatim: CaptionPerformanceCopy.recognitionSpeed(p50RealTimeFactor: rtf.p50))
                }
            }
            if let dropped = summaries.first(where: { $0.operation == "captions.asr.dropped" }) {
                LabeledContent("Audio not captioned") {
                    Text(verbatim: CaptionPerformanceCopy.audioNotCaptioned(dropped.p50))
                        .monospacedDigit()
                }
            }
            if summaries.first(where: { $0.operation.hasPrefix("captions.") }) == nil {
                Text("No caption measurements yet. Start captions once to collect them.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .id(revision)
    }

    @ViewBuilder
    private var quickSettings: some View {
        VStack(alignment: .leading, spacing: 20) {
            SettingsSection(title: "Quick controls") {
                LabeledToggle("Show the caption bubble",
                              "Hides the subtitles without stopping recognition, so you can keep a transcript running with nothing on screen.",
                              showsNote: false,
                              isOn: Binding(get: { !state.style.hidden },
                                            set: { visible in
                                                var updated = state.style
                                                updated.hidden = !visible
                                                state.style = updated
                                            }))
                if let engine = state.engine {
                    Text("Using \(engine.displayName)")
                        .font(.caption).foregroundStyle(.secondary)
                    Text(verbatim: engine.shortSummary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if case .only(let codes) = engine.coverage {
                        let names = codes.sorted()
                            .map { Locale.current.localizedString(forLanguageCode: $0) ?? $0 }
                        Label("Recognises \(names.joined(separator: ", ")) only. Other languages come out as nonsense rather than an error.",
                              systemImage: "exclamationmark.triangle")
                            .font(.caption).foregroundStyle(.orange)
                    }
                } else {
                    Label("No recognition model chosen yet. \(ASREngine.recommended.displayName) is the recommended starting point for automatic multilingual recognition. Download it under Models.",
                          systemImage: "sparkles")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if let engine = state.engine, engine != .nemotron {
                    ForEach(engine.assetDescriptors, id: \.id) { asset in
                        let status = state.assets.first(where: { $0.id == asset.id }) ?? ModelRegistry.status(of: asset)
                        if state.needsModelRepair(status) {
                            HStack {
                                Text(asset.title).font(.caption).foregroundStyle(.secondary)
                                Spacer()
                                AssetControl(state: state, status: status)
                            }
                        }
                    }
                }
                if state.engine == .nemotron {
                    Picker("Subtitle timing", selection: $state.nemotronTier) {
                        Text("Balanced").tag(2240)
                        Text("Realtime").tag(1120)
                    }
                    .pickerStyle(.segmented)
                    Text(state.nemotronTier == 1120
                         ? "Words appear while speech continues, using the faster local model. Uses more processing power; text can still be revised."
                         : "Streaming words with more context per update and lower processing cost.")
                        .font(.caption).foregroundStyle(.secondary)
                    if let asset = ASREngine.nemotron.assetDescriptors.first(where: { $0.id == AssetID.nemotron(chunkMs: state.nemotronTier) }) {
                        let status = state.assets.first(where: { $0.id == asset.id }) ?? ModelRegistry.status(of: asset)
                        if state.needsModelRepair(status) {
                            HStack {
                                if !status.isInstalled {
                                    Text("Download this timing model before starting captions.")
                                        .font(.caption).foregroundStyle(.secondary)
                                    Spacer()
                                }
                                AssetControl(state: state, status: status)
                            }
                        }
                    }
                } else if state.engine == .qwen06 || state.engine == .qwen17 {
                    Text("This model shows captions on pauses. Choose Nemotron for realtime word updates.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                HStack {
                    Label("Language", systemImage: "waveform")
                    Spacer()
                    Text(SettingsStateHonesty.languageLabel(for: state.engine))
                        .foregroundStyle(.secondary)
                    Button("Models") { SettingsWindowController.selectModelsPane() }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                }
                Divider()
                LabeledToggle("Show the translation line",
                              "The second line under each caption. Turning this off keeps translation running for the transcript but hides it on screen.",
                              showsNote: false,
                              isOn: Binding(
                                get: { state.style.showTranslation },
                                set: { visible in
                                    var updated = state.style
                                    updated.showTranslation = visible
                                    state.style = updated
                                }))
                    .disabled(state.translateTo?.isEmpty != false)
                translationSettings.targetControls
                if let t = state.translateTo, !state.targetSupportedByEngine {
                    TargetUnsupportedNotice(state: state, target: t)
                }
                if state.translateTo != nil {
                    Picker("Translation timing", selection: $state.translationTiming) {
                        ForEach(TranslationTiming.allCases, id: \.self) { timing in
                            Text(timing.displayName).tag(timing)
                        }
                    }
                    .pickerStyle(.segmented)
                    Text(state.translationTiming == .live
                         ? "Translation follows the words while you listen and may change as the sentence grows. Saved transcripts use the final translation."
                         : "Translation appears when a sentence finishes.")
                        .font(.caption).foregroundStyle(.secondary)
                    if state.translationTiming == .live {
                        Text("Realtime previews slow down in Low Power Mode or under sustained load. Final sentence translations keep priority.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }

            SettingsSection(title: "Bubble appearance") {
                BubbleStylePresetControl(style: $state.style, context: .captions)
            }
        }
    }

    private var translationSettings: TranslationSettingsRows {
        TranslationSettingsRows(target: $state.translateTo,
                                engine: Binding(
                                    get: { state.translationEngine ?? .recommended },
                                    set: { state.translationEngine = $0 }),
                                engines: TranslationEngine.userSelectableCases, state: state) {
            state.showTranslationPicker = true
        }
    }

    @ViewBuilder
    private var appearanceSections: some View {
        SettingsSection(title: "Bubble behavior",
                        subtitle: "Fine-tune the caption bubble and its interaction.") {
            LabeledToggle("Let clicks pass through the bubble",
                          "On, only the bubble's top strip can be grabbed and everything else clicks straight through to the video underneath — which matters, because the bubble sits over the scrubber. Off, you can drag it by any part of it.",
                                                    isOn: $state.captionClickThrough)
            LabeledToggle("Announce captions to VoiceOver",
                          "Off by default. Each finished sentence is posted as a VoiceOver announcement, which also reaches a connected braille display. In-progress text is never announced — it would arrive faster than speech or braille can render it.",
                                                    isOn: $state.announceCaptions)
            Text("Layout").font(.subheadline.weight(.medium))
            BubbleSurfaceControls(style: $state.style, includePositioning: true)
            HStack {
                Spacer()
                ResetButton {
                    let d = CaptionStyle()
                    var reset = state.style
                    reset.glassStyle = d.glassStyle
                    reset.tintHex = d.tintHex
                    reset.cornerRadius = d.cornerRadius
                    reset.widthFraction = d.widthFraction
                    reset.screenMargin = d.screenMargin
                    reset.maxHeight = d.maxHeight
                    reset.autoResize = d.autoResize
                    state.style = reset
                    NotificationCenter.default.post(name: .saiityResetBubble, object: nil)
                }
            }
            Divider()
            Text("Text size adapts automatically to the available width.")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                Button("Preview") {
                    NotificationCenter.default.post(name: .saiityCaptionPreview, object: nil)
                }
                .buttonStyle(.bordered)
                Button("Reset position") {
                    NotificationCenter.default.post(name: .saiityResetBubble, object: nil)
                }
                .buttonStyle(.bordered)
                ResetButton("Reset everything") { state.style = CaptionStyle() }
            }
            .controlSize(.small)
        }
    }

    /// Sliders here are always label + track + read-out; writing that out five
    /// times invites them to drift apart.
    @ViewBuilder
    private func slider(_ title: LocalizedStringKey, _ value: Binding<Double>,
                        _ range: ClosedRange<Double>, _ format: String = "%.0f",
                        scale: Double = 1,
                        readout: ((Double) -> String)? = nil,
                        readoutWidth: CGFloat = 62) -> some View {
        LabeledContent(title) {
            HStack {
                Slider(value: value, in: range)
                Text(readout?(value.wrappedValue)
                     ?? String(format: format, value.wrappedValue * scale))
                    // 44 was sized for "22" and "62%"; a seconds readout is
                    // wider still. Right-aligned, so the extra width costs the
                    // slider a few points and nothing else.
                    .monospacedDigit().fixedSize()
                    .frame(width: readoutWidth, alignment: .trailing)
            }
        }
    }
}

/// "Reset" for one group of settings.
///
/// Every group gets one. A single global Defaults button means undoing one
/// experiment with the translation colour also throws away a carefully chosen
/// font size, so in practice nobody presses it and the settings silently drift
/// somewhere the user cannot get back from.
struct ResetButton: View {
    let title: LocalizedStringKey
    let action: () -> Void

    init(_ title: LocalizedStringKey = "Reset", action: @escaping () -> Void) {
        self.title = title
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Image(systemName: "arrow.counterclockwise")
        }
        .buttonStyle(.borderless)
        .controlSize(.small)
        .frame(minWidth: 28, minHeight: 28)
        .contentShape(Rectangle())
        .help(title)
            .accessibilityLabel(title)
    }
}

struct BubbleStylePresetControl: View {
    @Binding var style: CaptionStyle
    let context: BubbleStyleContext
    @Environment(\.colorSchemeContrast) private var contrast
    @State private var hoveredPreset: BubbleStylePreset?

    private var selectedPreset: BubbleStylePreset? {
        style.matchingPreset(for: context)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Preset")
                    .font(.body.weight(.medium))
                Spacer()
                if selectedPreset == nil {
                    Label("Custom", systemImage: "slider.horizontal.3")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 12) {
                    ForEach(BubbleStylePreset.allCases, id: \.self) { preset in
                        presetButton(preset).frame(width: 150)
                    }
                }
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible())], spacing: 12) {
                    ForEach(BubbleStylePreset.allCases, id: \.self) { preset in
                        presetButton(preset)
                    }
                }
            }

            MatchedFontSizeControl(style: $style, context: context)

            Text("Presets change appearance only. Behavior and translation settings stay unchanged.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    private func presetButton(_ preset: BubbleStylePreset) -> some View {
        Button {
            style = preset.applying(to: style, context: context)
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                presetPreview(preset)
                HStack(spacing: 6) {
                    Text(preset.title)
                        .font(.body.weight(.medium))
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 4)
                    if selectedPreset == preset {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.tint)
                    }
                }
            }
            .frame(maxWidth: .infinity, minHeight: 100, alignment: .leading)
            .padding(12)
            .contentShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .background {
            RoundedRectangle(cornerRadius: 10)
                .fill(selectedPreset == preset
                      ? Color.accentColor.opacity(0.12)
                      : Color(nsColor: .controlBackgroundColor))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .stroke(selectedPreset == preset
                        ? Color.accentColor
                        : Color.primary.opacity(contrast == .increased ? 0.55 : hoveredPreset == preset ? 0.3 : 0.12),
                        lineWidth: selectedPreset == preset ? 1.5 : 1)
        }
        .onHover { hoveredPreset = $0 ? preset : nil }
        .help(Text(preset.title))
        .accessibilityLabel(Text(preset.title))
        .accessibilityAddTraits(selectedPreset == preset ? .isSelected : [])
    }

    @ViewBuilder
    private func presetPreview(_ preset: BubbleStylePreset) -> some View {
        let preview = preset.applying(to: style, context: context)
        let scale = context == .captions ? 0.45 : 0.75
        let shape = RoundedRectangle(cornerRadius: preview.cornerRadius * scale)
        let width = context == .captions
            ? 120 * preview.widthFraction : min(120, preview.dictationWidth * 0.24)
        VStack(alignment: .leading, spacing: preview.lineGap * scale) {
            if context == .dictation {
                HStack(alignment: .center, spacing: 3) {
                    ForEach(0..<9) { index in
                        Capsule()
                            .fill(.secondary)
                            .frame(width: 3, height: CGFloat([4, 9, 15, 7, 20, 12, 17, 8, 4][index]))
                    }
                }
            }
            Text("See you tomorrow.")
                .font(Font(NSFont.systemFont(ofSize: max(10, preview.original.fontSize * scale),
                                             weight: .init(preview.original.weight))))
                .foregroundStyle(.primary)
            if context == .captions {
                Text(verbatim: "Bis morgen.")
                    .font(Font(NSFont.systemFont(ofSize: max(10, preview.translation.fontSize * scale),
                                                 weight: .init(preview.translation.weight))))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(8)
        .frame(width: width, alignment: .leading)
        .background {
            if preview.glassStyle == CaptionStyle.liquidGlass {
                shape.fill(Color.clear).glassEffect(.regular, in: shape)
            } else {
                shape.fill(.regularMaterial)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 80, alignment: .leading)
        .accessibilityHidden(true)
    }
}

/// One compact font control for both lines. Keeping the two roles matched is
/// intentional: changing the size writes the complete style value, so the
/// persisted notification reaches the live overlay instead of only the form.
struct MatchedFontSizeControl: View {
    @Binding var style: CaptionStyle
    let context: BubbleStyleContext

    private var range: ClosedRange<Double> {
        context == .dictation ? 10...28 : 16...54
    }

    private var sizeBinding: Binding<Double> {
        Binding(
            get: { style.original.fontSize },
            set: { newValue in
                var updated = style
                updated.original.fontSize = newValue
                updated.translation.fontSize = newValue
                style = updated
            })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            LabeledContent("Font size") {
                HStack(spacing: 8) {
                    Slider(value: sizeBinding, in: range)
                    Text("\(Int(style.original.fontSize.rounded())) pt")
                        .monospacedDigit()
                        .fixedSize()
                        .frame(width: 48, alignment: .trailing)
                }
            }
            Text("Original and translation update together in the live bubble.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

struct BubbleSurfaceControls: View {
    @Binding var style: CaptionStyle
    var includePositioning = false

    var body: some View {
        Group {
            LabeledToggle("Transparent background",
                          "Use a translucent background. Turn off for a solid background. macOS accessibility settings take precedence.",
                          isOn: styleBinding(\.backgroundIsTransparent))
            if includePositioning {
                Picker("Sizing", selection: styleBinding(\.autoResize)) {
                    Text("Auto adjust").tag(true)
                    Text("Drag to resize").tag(false)
                }
                .pickerStyle(.segmented)
                if style.autoResize {
                    Text("The bubble adapts to the display automatically.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("Drag any bubble edge to choose its width.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                surfaceSlider("Gap to screen edge", styleBinding(\.screenMargin), 0...160, "%.0f")
                surfaceSlider("Maximum height", styleBinding(\.maxHeight), 120...720, "%.0f")
            } else {
                surfaceSlider("Maximum result height", styleBinding(\.maxHeight), 120...420, "%.0f")
            }
            Label {
                Text(verbatim: layoutSummary)
            } icon: {
                Image(systemName: "ruler")
            }
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var layoutSummary: String {
        if includePositioning {
            let sizing = String(localized: style.autoResize ? "Auto width" : "Drag to resize")
            let format = String(localized: "%@ · max height %d pt · %d pt edge")
            return String(format: format, sizing, Int(style.maxHeight), Int(style.screenMargin))
        }
        let format = String(localized: "Preset width · max result height %d pt")
        return String(format: format, Int(style.maxHeight))
    }

    private func styleBinding<Value>(_ keyPath: WritableKeyPath<CaptionStyle, Value>) -> Binding<Value> {
        Binding(
            get: { style[keyPath: keyPath] },
            set: { newValue in
                var updated = style
                updated[keyPath: keyPath] = newValue
                style = updated
            })
    }

    @ViewBuilder
    private func surfaceSlider(_ title: LocalizedStringKey, _ value: Binding<Double>,
                               _ range: ClosedRange<Double>, _ format: String,
                               scale: Double = 1) -> some View {
        LabeledContent(title) {
            HStack {
                Slider(value: value, in: range)
                Text(String(format: format, value.wrappedValue * scale))
                    .monospacedDigit()
                    .fixedSize()
                    .frame(width: 62, alignment: .trailing)
            }
        }
    }
}

/// A compact toggle that keeps its explanation available as hover help.
struct LabeledToggle: View {
    // Both are LocalizedStringKey. As String they would reach Text's verbatim
    // overload, which is how every one of these explanations stayed English
    // in the German build while the surrounding section was translated.
    let title: LocalizedStringKey
    let note: LocalizedStringKey
    let showsNote: Bool
    @Binding var isOn: Bool

    init(_ title: LocalizedStringKey,
         _ note: LocalizedStringKey,
         showsNote: Bool = false,
         isOn: Binding<Bool>) {
        self.title = title
        self.note = note
        self.showsNote = showsNote
        self._isOn = isOn
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Toggle(title, isOn: $isOn)
                .help(note)
            if showsNote {
                Text(note)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

// MARK: - Shortcuts

/// Click to arm, then the next keypress becomes the shortcut. Implemented as an
/// NSView because SwiftUI has no way to intercept a raw keyDown with modifiers
/// before the system interprets it.
struct ShortcutRecorder: NSViewRepresentable {
    let action: HotKeyCenter.Action
    @Bindable var state: AppState

    func makeNSView(context: Context) -> RecorderView {
        let v = RecorderView()
        v.action = action
        v.onChange = { s in
            HotKeyCenter.setShortcut(s, for: action)
            let registered = HotKeyCenter.shared.rebind(action)
            state.shortcutError = (!registered && s != nil)
                ? String(localized: "That combination is already taken by another app.") : nil
        }
        return v
    }

    func updateNSView(_ v: RecorderView, context: Context) {
        v.refresh()
    }

    final class RecorderView: NSView {
        var action: HotKeyCenter.Action = .toggleCaptions
        var onChange: ((Shortcut?) -> Void)?
        private var recording = false
        private var eventMonitor: Any?
        private let label = NSTextField(labelWithString: "")

        override init(frame: NSRect) {
            super.init(frame: frame)
            label.alignment = .center
            label.font = .monospacedSystemFont(ofSize: 12, weight: .medium)
            label.translatesAutoresizingMaskIntoConstraints = false
            addSubview(label)
            NSLayoutConstraint.activate([
                label.centerXAnchor.constraint(equalTo: centerXAnchor),
                label.centerYAnchor.constraint(equalTo: centerYAnchor),
                // See the note on the dictation recorder: fixed, so the control is
                // the size of a key chord rather than the width of the pane.
                widthAnchor.constraint(equalToConstant: 130),
                heightAnchor.constraint(equalToConstant: 28),
            ])
            wantsLayer = true
            layer?.cornerRadius = ShortcutRecorderChrome.cornerRadius
            refresh()
        }
        required init?(coder: NSCoder) { fatalError() }

        func refresh() {
            let assigned = HotKeyCenter.shortcut(for: action)?.displayString
            let text = ShortcutRecorderChrome.label(assigned: assigned, recording: recording)
            label.stringValue = text.text
            label.textColor = text.isInvitation
                ? NSColor.controlAccentColor
                : NSColor.labelColor
            layer?.backgroundColor = ShortcutRecorderChrome.fill(
                recording: recording, assigned: assigned != nil)
            layer?.borderWidth = ShortcutRecorderChrome.borderWidth(recording: recording)
            layer?.borderColor = ShortcutRecorderChrome.border(
                recording: recording, assigned: assigned != nil)
        }

        override var acceptsFirstResponder: Bool { true }
        override func hitTest(_ point: NSPoint) -> NSView? {
            super.hitTest(point) == nil ? nil : self
        }

        override func viewWillMove(toWindow newWindow: NSWindow?) {
            if newWindow == nil { endRecording() }
            NotificationCenter.default.removeObserver(self, name: NSWindow.didResignKeyNotification, object: window)
            if let newWindow {
                NotificationCenter.default.addObserver(self, selector: #selector(stopRecordingWhenWindowDeactivates(_:)),
                                                       name: NSWindow.didResignKeyNotification, object: newWindow)
            }
            super.viewWillMove(toWindow: newWindow)
        }

        @objc private func stopRecordingWhenWindowDeactivates(_ notification: Notification) {
            endRecording()
        }

        override func mouseDown(with event: NSEvent) {
            arm()
        }

        private func arm() {
            guard !recording, let window, window.makeFirstResponder(self) else { return }
            recording = true
            HotKeyCenter.shared.setSuspended(true)
            eventMonitor = Shortcut.monitorEvents(in: self)
            NotificationCenter.default.post(name: .saiityDictationShortcutRecordingChanged, object: true)
            refresh()
        }

        private func endRecording() {
            guard recording else { return }
            recording = false
            if let eventMonitor { NSEvent.removeMonitor(eventMonitor) }
            eventMonitor = nil
            HotKeyCenter.shared.setSuspended(false)
            NotificationCenter.default.post(name: .saiityDictationShortcutRecordingChanged, object: false)
            refresh()
        }

        // The ring is what tells a Full Keyboard Access user that Tab landed
        // here; without it the control is focusable but looks inert.
        override var focusRingMaskBounds: NSRect { bounds }
        override func drawFocusRingMask() {
            NSBezierPath(roundedRect: bounds, xRadius: 6, yRadius: 6).fill()
        }

        // A real control to assistive tech: role, a label naming the action,
        // the current shortcut as the value, and an actual press action.
        // Ironic history: the one control that exists to serve keyboard users
        // was mouse-armed and invisible to VoiceOver.
        override func isAccessibilityElement() -> Bool { true }
        override func accessibilityRole() -> NSAccessibility.Role? { .button }
        override func accessibilityLabel() -> String? { action.title }
        override func accessibilityValue() -> Any? {
            recording ? String(localized: "Press keys…")
                : HotKeyCenter.shortcut(for: action)?.displayString
                    ?? String(localized: "Not set")
        }
        override func accessibilityHelp() -> String? {
            String(localized: "Press to record a new shortcut. Delete clears it; Escape cancels.")
        }
        override func accessibilityPerformPress() -> Bool {
            arm()
            return recording
        }

        override func performKeyEquivalent(with event: NSEvent) -> Bool {
            guard recording, window?.firstResponder === self else { return false }
            keyDown(with: event)
            return true
        }

        override func keyDown(with event: NSEvent) {
            // Arm from the keyboard too: Tab reaches this view, but recording
            // used to start only in mouseDown — a keyboard user could focus
            // the control and then do nothing with it.
            if !recording,
               event.keyCode == UInt16(kVK_Space) || event.keyCode == UInt16(kVK_Return) {
                arm()
                return
            }
            guard recording else { super.keyDown(with: event); return }
            // ⌫ clears.
            if event.keyCode == UInt16(kVK_Delete) {
                endRecording(); onChange?(nil); refresh(); return
            }
            if event.keyCode == UInt16(kVK_Escape) {
                endRecording(); return
            }
            let mods = Shortcut.carbonModifiers(from: event.modifierFlags)
            let s = Shortcut(keyCode: UInt32(event.keyCode), modifiers: mods)
            guard s.isUsable else { return }   // keep listening until it is valid
            endRecording()
            onChange?(s)
            refresh()
        }

        override func resignFirstResponder() -> Bool {
            endRecording()
            return true
        }
    }
}

// MARK: - Transcripts

/// Everything this app has recorded: whether it records at all, the sessions
/// on disk, a search across all of them, and the reader.
///
/// Split out of the old combined "Library" page. Recording and reading back a
/// conversation is a task in its own right — a person opening this looks for a
/// transcript, not for a permission status, and the two had nothing to do with
/// each other beyond both being "stuff the app keeps".
struct TranscriptsView: View {
    @Bindable var state: AppState
    /// Cross-session search. Non-empty replaces the session list with the
    /// matching lines — "what was said about X in yesterday's call" used to
    /// require exporting to Markdown and searching in another app.
    @State private var query = ""
    @State private var searchHits: [SearchHit] = []
    @State private var isSearching = false
    /// The session open in the transcript viewer sheet.
    @State private var showsLibraryDetails = false
    @State private var retentionDays = TranscriptRetention.days
    @State private var retranslator = Retranslator()
    @State private var retranslateProgress: Retranslator.Progress?
    @State private var retranslateNote: String?
    @State private var retranslating: SessionRef?
    @State private var summarizer = TranscriptSummarizer()
    @State private var summaryProgress: TranscriptSummarizer.Progress?
    @State private var summarizing: SessionRef?
    @State private var summaryFailure: (sessionID: String, message: String)?
    @State private var summaryIDs: Set<String> = []
    @State private var libraryRevision = 0
    @State private var renamingSession: SessionRef?
    @State private var nameDraft = ""
    @State private var renameFailure: String?
    @State private var renameBusy = false

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 20) {
            SettingsSection(title: "Recording") {
                Toggle("Save transcripts of sessions", isOn: $state.saveTranscript)
            }

            SettingsSection(title: "Saved sessions") {
                if state.sessions.isEmpty {
                    ContentUnavailableView(
                        "Nothing saved yet",
                        systemImage: "text.document",
                        description: Text("Turn on “Save transcripts of sessions” and every captioned session appears here."))
                        .frame(maxWidth: .infinity)
                } else {
                    TextField("Search all transcripts", text: $query)
                        .textFieldStyle(.roundedBorder)
                }
                if !state.sessions.isEmpty, !trimmedQuery.isEmpty {
                    if isSearching {
                        HStack(spacing: 8) {
                            ProgressView()
                                .controlSize(.small)
                            Text("Searching saved transcripts…")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    } else if searchHits.isEmpty {
                        // The framework's own empty state, which localizes and
                        // themes itself.
                        ContentUnavailableView.search(text: query)
                    }
                    ForEach(searchHits) { hit in
                        Button {
                            state.openTranscript(hit.session, revealing: hit.seg.i)
                        } label: {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(verbatim: hit.session.meta.title ?? hit.session.meta.startedAt.formatted(date: .abbreviated, time: .shortened))
                                    .font(.caption).foregroundStyle(.secondary)
                                Text(hit.seg.text).lineLimit(2)
                                if let tr = hit.seg.tr, !tr.isEmpty {
                                    Text(tr).font(.caption)
                                        .foregroundStyle(.secondary).lineLimit(1)
                                }
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help("Open this transcript")
                    }
                } else if !state.sessions.isEmpty {
                    ForEach(state.sessions, id: \.id) { s in
                        sessionRow(s)
                    }
                }
                if !trimmedQuery.isEmpty {
                    // Keep a running session and its Cancel reachable during search.
                    if let s = summarizing { sessionRow(s) }
                    if let s = retranslating { sessionRow(s) }
                }
                if let p = retranslateProgress, retranslating == nil {
                    TranscriptProgressRow(label: "\(p.note) \(p.done)/\(p.total)",
                                          done: p.done, total: p.total)
                }
                if let note = retranslateNote {
                    Label(note, systemImage: note.hasPrefix("✓") ? "checkmark.circle" : "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(note.hasPrefix("✓")
                                         ? AnyShapeStyle(.secondary)
                                         : AnyShapeStyle(Color.orange))
                }
            }

            SettingsDisclosure(isExpanded: $showsLibraryDetails) {
                SettingsSection(title: "Recording") {
                    Picker("Keep transcripts", selection: $retentionDays) {
                        ForEach(TranscriptRetention.choices, id: \.self) { d in
                            Text(TranscriptRetention.label(d)).tag(d)
                        }
                    }
                    .disabled(CaptionSession.shared.isProcessingTranscript || summarizing != nil)
                    .onChange(of: retentionDays) { old, new in
                        // Ask first. Choosing "7 days" used to delete every older
                        // transcript the instant the menu closed — irreversible,
                        // unannounced, and from a control that reads like a
                        // preference rather than a command. Deleting all
                        // transcripts has always required a confirmation; this
                        // deletes a subset and had none.
                        let doomed = TranscriptStore.sessionsOlderThan(days: new)
                        guard !doomed.isEmpty else {
                            TranscriptRetention.days = new
                            return
                        }
                        let a = NSAlert()
                        a.messageText = String(localized: "Delete \(doomed.count) transcripts now?")
                        a.informativeText = String(localized: "Keeping transcripts for \(new) days means \(doomed.count) already older than that are deleted immediately, and any future session is deleted once it reaches that age. This cannot be undone.")
                        a.alertStyle = .warning
                        a.addButton(withTitle: String(localized: "Delete and Keep Setting"))
                        a.addButton(withTitle: String(localized: "Cancel"))
                        guard a.runModal() == .alertFirstButtonReturn else {
                            retentionDays = old      // put the control back
                            return
                        }
                        TranscriptRetention.days = new
                        Task {
                            let result = await TranscriptRetention.sweep()
                            retranslateNote = result.failed == 0
                                ? "✓ " + String(localized: "Deleted \(result.deleted) transcripts.")
                                : String(localized: "Deleted \(result.deleted) transcripts; \(result.failed) could not be removed.")
                            await state.refreshLibraryAsync(force: true)
                        }
                    }
                }
                SettingsSection(title: "Saved sessions") {
                    if !state.sessions.isEmpty, trimmedQuery.isEmpty {
                        HStack {
                            Menu("Export all…") {
                                Button("Plain text") { exportLibrary("txt") }
                                Button("Markdown") { exportLibrary("md") }
                                Button("SRT") { exportLibrary("srt") }
                                Button("WebVTT") { exportLibrary("vtt") }
                            }
                            .controlSize(.small)
                            .fixedSize()
                            .disabled(retranslateProgress != nil || retranslating != nil || summarizing != nil)
                        }
                        Button("Delete all…", role: .destructive) {
                            let a = NSAlert()
                            a.messageText = String(localized: "Delete all transcripts?")
                            a.informativeText = String(localized: "Permanently removes \(state.sessions.count) sessions.")
                            a.addButton(withTitle: String(localized: "Delete All"))
                            a.addButton(withTitle: String(localized: "Cancel"))
                            a.alertStyle = .warning
                            if a.runModal() == .alertFirstButtonReturn {
                                let result = TranscriptStore.deleteAll()
                                retranslateNote = result.failed == 0
                                    ? "✓ " + String(localized: "Deleted \(result.deleted) transcripts.")
                                    : String(localized: "Deleted \(result.deleted) transcripts; \(result.failed) could not be removed.")
                                SessionCatalog.invalidate()
                                Task { await state.refreshLibraryAsync(force: true) }
                            }
                        }
                        .controlSize(.small)
                        .disabled(CaptionSession.shared.isProcessingTranscript || summarizing != nil || retranslating != nil)
                    }
                }
            }
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 8)
            .frame(maxWidth: 780, alignment: .leading)
        }
        .task(id: "\(trimmedQuery)|\(state.sessions.map(\.id))|\(state.sessions.map(\.meta.title))|\(libraryRevision)") {
            await refreshSearch()
        }
        .task(id: "\(state.sessions.map(\.id))|\(libraryRevision)") {
            let sessions = state.sessions
            let ids = await Task.detached {
                Set(sessions.filter { TranscriptSummaryStore.read($0) != nil }.map(\.id))
            }.value
            guard !Task.isCancelled else { return }
            summaryIDs = ids
        }
        .onReceive(NotificationCenter.default.publisher(for: .saiityTranscriptLibraryChanged)) { _ in
            libraryRevision += 1
        }
        .sheet(item: $renamingSession) { session in
            SheetShell(title: "Rename Transcript", subtitle: "Only the session name changes. Spoken lines stay unchanged.",
                       width: 480, height: 230, dismissTitle: "Cancel", dismissIsDefaultAction: false) {
                VStack(alignment: .leading, spacing: 12) {
                    TextField("Session name", text: $nameDraft).textFieldStyle(.roundedBorder)
                        .disabled(renameBusy)
                    Text("Up to 80 characters. Leave blank to show the date.")
                        .font(.callout).foregroundStyle(.secondary)
                    if let renameFailure {
                        Label(renameFailure, systemImage: "exclamationmark.triangle").font(.callout)
                            .foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
                    }
                    Button("Save Name") { rename(session) }
                        .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                        .disabled(renameBusy || nameDraft.trimmingCharacters(in: .whitespacesAndNewlines).count > 80 || CaptionSession.shared.isProcessingTranscript)
                }.padding(16)
            }
        }
        .sheet(item: $state.transcriptToOpen, onDismiss: { state.transcriptSegmentToReveal = nil }) { s in
            TranscriptViewerSheet(
                session: s,
                summaryProgress: summarizing?.id == s.id ? summaryProgress : nil,
                isSummarizing: summarizing?.id == s.id,
                summaryFailure: summaryFailure?.sessionID == s.id ? summaryFailure?.message : nil,
                modelAvailable: summarizer.modelAvailable,
                summaryUnavailable: retranslateProgress != nil || summarizing != nil || CaptionSession.shared.isProcessingTranscript,
                onSummarize: { startSummary(s) },
                onCancel: { Task { await summarizer.cancelAndWait() } },
                onRemove: { removeSummary(s) },
                onShowDictation: {
                    state.transcriptToOpen = nil
                    NotificationCenter.default.post(name: .saiitySelectSettingsPane, object: SettingsPane.dictation.rawValue)
                },
                onSummarizeWithLanguage: { startSummary(s, outputLanguage: $0) },
                initialSegmentIndex: state.transcriptSegmentToReveal)
        }
    }

    private func sessionRow(_ s: SessionRef) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Button { state.openTranscript(s) } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        if let title = s.meta.title {
                            Text(verbatim: title).font(.body.weight(.medium))
                            Text(s.meta.startedAt.formatted(date: .abbreviated, time: .shortened))
                                .font(.callout).foregroundStyle(.secondary)
                        } else {
                            Text(s.meta.startedAt.formatted(date: .abbreviated, time: .shortened))
                        }
                        Text("\(s.meta.lineCount) lines · \(s.meta.locale)")
                            .font(.caption).foregroundStyle(.secondary)
                        if summaryIDs.contains(s.id) {
                            Text("Summary").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Open this transcript")
                Menu {
                    Menu("Export") {
                        Button("SRT") { export(s, "srt") }
                        Button("WebVTT") { export(s, "vtt") }
                        Button("Markdown") { export(s, "md") }
                    }
                    Menu("Translate") {
                        ForEach(state.recentTargetsForMenu, id: \.self) { code in
                            Button(AppLanguage(code: code).displayName) { startRetranslate(s, to: code) }
                        }
                    }
                    .disabled(retranslateProgress != nil || retranslating != nil || summarizing != nil || CaptionSession.shared.isProcessingTranscript)
                    Button("Rename…") {
                        nameDraft = s.meta.title ?? ""
                        renameFailure = nil
                        renamingSession = s
                    }
                    .disabled(CaptionSession.shared.isRunning || CaptionSession.shared.isProcessingTranscript)
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([s.url]) }
                    Divider()
                    Button("Delete", role: .destructive) {
                        guard summarizing?.id != s.id, retranslating?.id != s.id else { return }
                        guard TranscriptStore.delete(s) else {
                            retranslateNote = String(localized: "Could not delete this transcript.")
                            Task { await state.refreshLibraryAsync(force: true) }
                            return
                        }
                        SessionCatalog.invalidate()
                        Task { await state.refreshLibraryAsync(force: true) }
                    }
                    .disabled(summarizing?.id == s.id || retranslating?.id == s.id)
                } label: {
                    Label("Session actions", systemImage: "ellipsis")
                        .labelStyle(.iconOnly)
                        .frame(minWidth: 28, minHeight: 28)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("Session actions")
            }
            if let p = retranslateProgress, retranslating?.id == s.id {
                TranscriptProgressRow(
                    label: "Translating \(s.meta.startedAt.formatted(date: .abbreviated, time: .shortened))… \(p.done)/\(p.total)",
                    done: p.done, total: p.total,
                    cancel: { Task { await retranslator.cancelAndWait() } })
            }
            if let p = summaryProgress, summarizing?.id == s.id {
                TranscriptProgressRow(
                    label: "Summarizing \(s.meta.startedAt.formatted(date: .abbreviated, time: .shortened))… \(p.done)/\(p.total)",
                    done: p.done, total: p.total,
                    cancel: { Task { await summarizer.cancelAndWait() } })
            }
            if let failure = summaryFailure, failure.sessionID == s.id {
                Label(failure.message, systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.orange)
            }
        }
    }

    private var trimmedQuery: String {
        query.trimmingCharacters(in: .whitespaces)
    }

    private struct SearchHit: Identifiable, Sendable {
        let id: String
        let session: SessionRef
        let seg: Segment
    }

    /// Search runs off the main actor and is restarted by `.task(id:)`, so a
    /// fast typist never makes SwiftUI decode every saved meeting on each
    /// keystroke. The previous results stay visible until the new query has
    /// finished, which keeps the page responsive instead of flashing empty.
    private func refreshSearch() async {
        let q = trimmedQuery
        guard !q.isEmpty else {
            searchHits = []
            isSearching = false
            return
        }

        isSearching = true
        let sessions = state.sessions
        let worker = Task.detached(priority: .userInitiated) {
            Self.search(sessions: sessions, query: q)
        }
        let result = await withTaskCancellationHandler {
            await worker.value
        } onCancel: {
            worker.cancel()
        }
        guard !Task.isCancelled else { return }
        searchHits = result
        isSearching = false
    }

    nonisolated private static func search(sessions: [SessionRef], query: String) -> [SearchHit] {
        TranscriptStore.search(sessions: sessions, query: query).map { hit in
            SearchHit(id: "\(hit.session.id)#\(hit.segment.i)", session: hit.session, seg: hit.segment)
        }
    }

    private func startRetranslate(_ s: SessionRef, to code: String) {
        guard retranslating == nil, retranslateProgress == nil, summarizing == nil else { return }
        retranslateNote = nil
        retranslating = s
        Task {
            await retranslator.run(session: s, target: code) { p in
                retranslateProgress = p
            } onFinish: { err in
                retranslateProgress = nil
                retranslating = nil
                if let err {
                    retranslateNote = s.meta.startedAt.formatted(date: .abbreviated, time: .shortened) + ": " + err
                } else {
                    retranslateNote = "✓ " + s.meta.startedAt.formatted(date: .abbreviated, time: .shortened) + ": " + String(localized: "Translated into \(AppLanguage(code: code).displayName).")
                    Task { await state.refreshLibraryAsync(force: true) }
                }
            }
        }
    }

    private func rename(_ session: SessionRef) {
        guard !renameBusy, !CaptionSession.shared.isRunning, !CaptionSession.shared.isProcessingTranscript else { return }
        let title = nameDraft
        renameBusy = true
        Task {
            defer { renameBusy = false }
            do {
                try await TranscriptStore.shared.renameSession(session, title: title)
                await state.refreshLibraryAsync(force: true)
                renamingSession = nil
            } catch {
                renameFailure = error.localizedDescription
            }
        }
    }

    private func startSummary(_ s: SessionRef, outputLanguage: String? = nil) {
        guard summarizing == nil, retranslateProgress == nil, retranslating == nil else { return }
        summaryFailure = nil
        summarizing = s
        Task {
            await summarizer.run(session: s, outputLanguage: outputLanguage) { p in
                summaryProgress = p
            } onFinish: { err in
                if let err {
                    summaryFailure = (s.id, err)
                } else {
                    summaryIDs.insert(s.id)
                    NotificationCenter.default.post(name: .saiityTranscriptLibraryChanged, object: nil)
                }
            }
            // Keep the controls busy until the model and task have unwound.
            summaryProgress = nil
            summarizing = nil
        }
    }

    private func removeSummary(_ s: SessionRef) {
        guard summarizing == nil else { return }
        do {
            guard try TranscriptSummaryStore.remove(s) else { throw CocoaError(.fileWriteNoPermission) }
            summaryFailure = nil
            summaryIDs.remove(s.id)
            NotificationCenter.default.post(name: .saiityTranscriptLibraryChanged, object: nil)
        } catch {
            summaryFailure = (s.id, String(localized: "The summary could not be removed. The transcript and existing summary were kept."))
        }
    }

    private func exportLibrary(_ format: String) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = String(localized: "Export")
        panel.message = String(localized: "Choose a folder for every saved transcript.")
        guard panel.runModal() == .OK, let dir = panel.url else { return }
        // Off the main actor: this reads, formats and writes every saved
        // session, and a library of a few hundred long meetings would freeze
        // the window for the duration with no way to tell it was working.
        let sessions = state.sessions
        retranslateProgress = Retranslator.Progress(
            done: 0, total: sessions.count, note: String(localized: "Exporting…"))
        Task {
            let r = await Task.detached(priority: .userInitiated) {
                Export.writeLibrary(sessions, format: format, to: dir)
            }.value
            retranslateProgress = nil
            retranslateNote = r.failed == 0
                ? "✓ " + String(localized: "Exported \(r.written) transcripts.")
                : String(localized: "Exported \(r.written); \(r.failed) could not be written.")
            NSWorkspace.shared.activateFileViewerSelecting([dir])
        }
    }

    private func export(_ s: SessionRef, _ kind: String) {
        let segs = TranscriptStore.segments(of: s)
        let text: String
        switch kind {
        case "srt": text = Export.srt(segs)
        case "vtt": text = Export.vtt(segs)
        default: text = Export.markdown(segs, meta: s.meta, summary: TranscriptSummaryStore.read(s))
        }
        if let url = Export.write(text, named: "transcript.\(kind)", in: s.url) {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
    }
}

// MARK: - General

/// What the app can see, what it will do on its own, and what it promises —
/// permissions, the login item, setup, diagnostics, privacy.
///
/// The counterpart to the Transcripts split: this page answers "is it set up
/// correctly", which is a different question from "what did it record".
struct GeneralView: View {
    @Bindable var state: AppState
    var onDetailVisibilityChanged: (Bool) -> Void = { _ in }
    @State private var diagnosticsRevision = 0
    @State private var screenRecordingGranted: Bool?
    @State private var inputMonitoringGranted: Bool?
    @State private var accessibilityGranted: Bool?
    @State private var credits = String(localized: "Loading credits…")
    @State private var dictationModelReady = false
    @State private var microphoneAuthorization = AVAuthorizationStatus.notDetermined
    @State private var showsDiagnostics = false

    private var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
            ?? String(localized: "Development build")
    }

    private static func loadCredits() -> String {
        guard let url = Bundle.main.url(forResource: "Credits", withExtension: "txt"),
              let text = try? String(contentsOf: url, encoding: .utf8) else {
            return String(localized: "Credits file missing from this build.")
        }
        return text
    }

    private func refreshPermissions() {
        screenRecordingGranted = CGPreflightScreenCaptureAccess()
        inputMonitoringGranted = CGPreflightListenEventAccess()
        accessibilityGranted = AXIsProcessTrusted()
        dictationModelReady = AppDelegate.dictationModelIsInstalled()
        microphoneAuthorization = AVCaptureDevice.authorizationStatus(for: .audio)
    }

    private func permissionLabel(_ granted: Bool?) -> String {
        guard let granted else { return String(localized: "Checking…") }
        return granted ? String(localized: "Ready") : String(localized: "Permission required")
    }

    static func dictationStatusLabel(enabled: Bool,
                                     input: Bool?,
                                     accessibility: Bool?,
                                     modelReady: Bool,
                                     microphone: AVAuthorizationStatus) -> String {
        guard enabled else { return String(localized: "Off") }
        guard modelReady else { return String(localized: "Not downloaded yet — see Models.") }
        if microphone == .denied || microphone == .restricted { return String(localized: "Microphone access needed") }
        guard input == true else { return input == nil ? String(localized: "Checking…") : String(localized: "Permission required") }
        guard let accessibility else { return String(localized: "Checking…") }
        guard accessibility else { return String(localized: "Shortcut ready — Accessibility needed") }
        return microphone == .notDetermined ? String(localized: "Microphone requested on first use") : String(localized: "Ready")
    }

    private func openAccessibilitySettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") else { return }
        NSWorkspace.shared.open(url)
    }

    @ViewBuilder
    private func setupStatusRow(title: LocalizedStringKey,
                                symbol: String,
                                value: String,
                                actionTitle: LocalizedStringKey?,
                                action: @escaping () -> Void) -> some View {
        HStack(spacing: 10) {
            Label(title, systemImage: symbol)
            Spacer(minLength: 12)
            Text(value)
                .foregroundStyle(.secondary)
            if let actionTitle {
                Button(actionTitle, action: action)
                    .controlSize(.small)
            }
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                primarySettings
                SettingsDisclosure(isExpanded: $showsDiagnostics) {
                    detailSettings
                }
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 8)
            .frame(maxWidth: 780, alignment: .leading)
        }
        .onAppear {
            onDetailVisibilityChanged(showsDiagnostics)
        }
        .onChange(of: showsDiagnostics) { _, expanded in
            onDetailVisibilityChanged(expanded)
        }
        .task {
            refreshPermissions()
            credits = Self.loadCredits()
            await state.refresh()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            refreshPermissions()
        }
        .onReceive(NotificationCenter.default.publisher(for: Diagnostics.changed)) { _ in
            diagnosticsRevision += 1
        }
        .onChange(of: state.ownedBytes) { refreshPermissions() }
    }

    @ViewBuilder
    private var primarySettings: some View {
        SettingsSection(title: "Status") {
            setupStatusRow(
                title: "Recognition",
                symbol: "waveform",
                value: state.engine == nil
                    ? String(localized: "Not set")
                    : state.engine?.needsDownload == true
                        ? String(localized: "Not downloaded yet — see Models.")
                        : String(localized: "Ready"),
                actionTitle: "Models") {
                    SettingsWindowController.selectModelsPane()
                }
            setupStatusRow(
                title: "Captions",
                symbol: "captions.bubble",
                value: permissionLabel(screenRecordingGranted),
                actionTitle: screenRecordingGranted == false ? "Open Settings" : nil) {
                    ScreenRecordingPermission.openSettings()
                }
            setupStatusRow(
                title: "Dictation",
                symbol: "mic",
                value: Self.dictationStatusLabel(enabled: state.dictationEnabled,
                                            input: inputMonitoringGranted,
                                            accessibility: accessibilityGranted,
                                            modelReady: dictationModelReady,
                                            microphone: microphoneAuthorization),
                actionTitle: state.dictationEnabled && !dictationModelReady ? "Models"
                    : state.dictationEnabled && (microphoneAuthorization == .denied || microphoneAuthorization == .restricted
                        || inputMonitoringGranted == false || accessibilityGranted == false) ? "Open Settings" : nil) {
                    if !dictationModelReady {
                        SettingsWindowController.selectModelsPane()
                    } else if microphoneAuthorization == .denied || microphoneAuthorization == .restricted {
                        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
                            NSWorkspace.shared.open(url)
                        }
                    } else if inputMonitoringGranted == false {
                        InputMonitoringPermission.openSettings()
                    } else {
                        openAccessibilitySettings()
                    }
                }
        }

        SettingsSection(title: "Privacy") {
            Text("Audio never leaves this Mac. Recognition, translation, and transcripts stay on this Mac.")
                .font(.caption)
        }
    }

    @ViewBuilder
    private var detailSettings: some View {
        SettingsSection(title: "Startup") {
            LabeledToggle("Start Syllivra when you log in",
                          "Registers the app as a login item so captions are one keypress away after a restart. Off by default — this app can capture system audio, so being running should be your choice.",
                                                    isOn: Binding(get: { state.launchAtLogin },
                                        set: { state.setLaunchAtLogin($0) }))
            if !state.launchAtLoginNote.isEmpty {
                Text(state.launchAtLoginNote).font(.caption).foregroundStyle(.orange)
            }
        }

        SettingsSection(title: "Troubleshooting",
                        subtitle: "Repair permissions, save diagnostics, or review app information.") {
            if let failure = Diagnostics.latestFailure {
                LabeledContent("Last operation", value: failure.operation)
                Text(failure.reason)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .textSelection(.enabled)
            } else {
                Text("No recent runtime failures.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            let lastRun = Diagnostics.recentLatestRun
            if !lastRun.isEmpty {
                Divider()
                Text("Last dictation").font(.headline)
                if let terminal = lastRun.first(where: { $0.outcome != nil }) {
                    switch terminal.outcome {
                    case "inserted", "paste-dispatched": Label("Copied — paste requested", systemImage: "checkmark.circle")
                    case "copied": Label("Copied to Clipboard", systemImage: "doc.on.clipboard")
                    case "copy-failed": Label("Copy failed", systemImage: "exclamationmark.triangle")
                    case "cancelled": Label("Cancelled", systemImage: "xmark.circle")
                    case "failed": Label("Failed", systemImage: "exclamationmark.triangle")
                    default: EmptyView()
                    }
                }
                if let slowest = DiagnosticsTimingSummarizer.slowestStage(lastRun) {
                    Text(verbatim: DiagnosticsTimingSummarizer.slowestExplanation(slowest.operation))
                        .font(.callout).foregroundStyle(.secondary)
                }
                ForEach(Array(lastRun.reversed().enumerated()), id: \.offset) { _, timing in
                    VStack(alignment: .leading, spacing: 4) {
                        LabeledContent(DiagnosticsTimingSummarizer.stageTitle(timing.operation),
                                       value: CaptionPerformanceCopy.duration(timing.seconds))
                        if let cold = timing.cold {
                            Text(cold ? String(localized: "Model loading was needed") : String(localized: "Model was already prepared"))
                                .font(.callout).foregroundStyle(.secondary)
                        }
                        if let loads = timing.modelLoadCount {
                            Text("Loads requested: \(loads)").font(.callout).foregroundStyle(.secondary)
                        }
                        if let calls = timing.modelCallCount {
                            Text("Model calls: \(calls)").font(.callout).foregroundStyle(.secondary)
                        }
                    }
                }
                Text("Contains timings and outcomes, never your dictated words.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            let timings = Array(Diagnostics.recentTimings.prefix(5))
            if !timings.isEmpty {
                Divider()
                Text("Recent timings")
                    .font(.caption.weight(.medium))
                ForEach(Array(timings.enumerated()), id: \.offset) { _, timing in
                    let temperature = timing.cold == nil ? "" : (timing.cold == true ? " · cold" : " · warm")
                    Text(verbatim: "\(timing.operation) · \(String(format: "%.2f s", timing.seconds))\(temperature)")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            HStack {
                Button("Run setup again…") {
                    Onboarding.reset()
                    OnboardingWindowController.shared.show(state: state)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                Text("Walks through permission and models from the start.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Button("Save diagnostics…") { Diagnostics.save() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                Text("Writes one text file with the app's state and this run's log, for bug reports. Review it before sharing.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .id(diagnosticsRevision)

        SettingsSection(title: "About Syllivra",
                        subtitle: "Version, licence, and the credits for the models and libraries used here.") {
            LabeledContent("Version", value: version)
            Text(credits)
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct TranscriptProgressRow: View {
    let label: LocalizedStringKey
    let done: Int
    let total: Int
    var cancel: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ProgressView(value: Double(done), total: Double(max(total, 1)))
                .accessibilityLabel(Text(label))
            HStack {
                Text(label).font(.caption).foregroundStyle(.secondary)
                Spacer()
                if let cancel {
                    Button("Cancel", action: cancel).buttonStyle(.bordered)
                }
            }
        }
    }
}

struct TranscriptViewerSheet: View {
    let session: SessionRef
    let summaryProgress: TranscriptSummarizer.Progress?
    let isSummarizing: Bool
    let summaryFailure: String?
    let modelAvailable: Bool
    let summaryUnavailable: Bool
    let onSummarize: () -> Void
    let onCancel: () -> Void
    let onRemove: () -> Void
    let onShowDictation: () -> Void
    var onSummarizeWithLanguage: ((String?) -> Void)? = nil
    var initialSegmentIndex: Int? = nil
    @State private var segments: [Segment] = []
    @State private var summary: TranscriptSummary?
    @State private var query = ""
    @State private var spokenLanguages: [String] = []
    @State private var selectedSummaryLanguage: String?
    @State private var hasLoaded = false
    @State private var reloadRevision = 0
    @State private var readingSize = 13.0
    @FocusState private var searchFocused: Bool

    private var summaryLanguageChoices: [String] {
        var choices = spokenLanguages
        if let raw = Bundle.main.preferredLocalizations.first,
           let code = TranscriptSummaryPlan.languageCode(raw)
            ?? TranscriptSummaryPlan.languageCode(TranslationLanguage.baseCode(raw)),
           !choices.contains(code) {
            choices.append(code)
        }
        return choices
    }

    private var shown: [Segment] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return segments }
        return segments.filter {
            $0.text.localizedCaseInsensitiveContains(q)
                || ($0.tr?.localizedCaseInsensitiveContains(q) ?? false)
        }
    }

    var body: some View {
        SheetShell(title: "Transcript — \(session.meta.title ?? session.meta.startedAt.formatted(date: .abbreviated, time: .shortened))",
                   subtitle: "Times count from the session start. Text can be selected and copied.",
                   width: 640, height: 680, minimumSize: CGSize(width: 560, height: 480),
                   headerAccessory: {
                       Menu {
                           ForEach([13.0, 16.0, 20.0, 26.0], id: \.self) { size in
                               Button(String(format: "%.0f pt", size)) { readingSize = size }
                           }
                       } label: {
                           Label("Text size", systemImage: "textformat.size").labelStyle(.iconOnly)
                       }
                       .help("Text size")
                       Button { searchFocused = true } label: {
                           Label("Search", systemImage: "magnifyingglass").labelStyle(.iconOnly)
                       }
                       .keyboardShortcut("f", modifiers: .command)
                       .help("Search")
                       TextField("Search", text: $query)
                           .textFieldStyle(.roundedBorder)
                           .frame(width: 160)
                           .focused($searchFocused)
                   }) {
            ScrollViewReader { proxy in
            List {
                VStack(alignment: .leading, spacing: 10) {
                    ViewThatFits(in: .horizontal) {
                        HStack {
                            Text("Summary").font(.headline).fixedSize()
                            Spacer()
                            summaryActions
                        }
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Summary").font(.headline)
                            summaryActions
                        }
                    }
                    Text("Written on this Mac by the dictation cleanup model. It can miss or invent details. The spoken lines below are unchanged.")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if spokenLanguages.count > 1 {
                        Text("This transcript uses more than one language. Choose the language for its summary.")
                            .font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Picker("Summary language", selection: $selectedSummaryLanguage) {
                            Text("Choose a language").tag(Optional<String>.none)
                            ForEach(summaryLanguageChoices, id: \.self) { code in
                                Text(verbatim: AppLanguage(code: code).displayName).tag(Optional(code))
                            }
                        }
                        .pickerStyle(.menu)
                        .disabled(summaryUnavailable || isSummarizing)
                    }
                    if !modelAvailable {
                        Text(String(localized: TranscriptSummarizer.modelRequiredMessage))
                            .font(.caption).foregroundStyle(.secondary)
                        Button("Open Dictation Settings", action: onShowDictation)
                            .buttonStyle(.bordered)
                    }
                    if let p = summaryProgress {
                        TranscriptProgressRow(
                            label: "Summarizing \(session.meta.startedAt.formatted(date: .abbreviated, time: .shortened))… \(p.done)/\(p.total)",
                            done: p.done, total: p.total, cancel: onCancel)
                    }
                    if let summaryFailure {
                        Label(summaryFailure, systemImage: "exclamationmark.triangle")
                            .font(.caption).foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if let summary {
                        if let code = summary.outputLanguage {
                            LabeledContent("Summary language", value: AppLanguage(code: code).displayName)
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        if !summary.recap.isEmpty {
                            Text("Recap").font(.caption).foregroundStyle(.secondary)
                            Text(verbatim: summary.recap).font(.system(size: readingSize)).textSelection(.enabled)
                        }
                        if !summary.decisions.isEmpty {
                            Text("Decisions").font(.caption).foregroundStyle(.secondary)
                            ForEach(Array(summary.decisions.enumerated()), id: \.offset) { _, line in
                                Text(verbatim: line).font(.system(size: readingSize)).textSelection(.enabled)
                            }
                        }
                        if !summary.actions.isEmpty {
                            Text("Actions").font(.caption).foregroundStyle(.secondary)
                            ForEach(Array(summary.actions.enumerated()), id: \.offset) { _, line in
                                Text(verbatim: line).font(.system(size: readingSize)).textSelection(.enabled)
                            }
                        }
                        if summary.omittedLineCount > 0 {
                            Text("Earlier lines were left out of this summary.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 8)
                if shown.isEmpty, !query.isEmpty {
                    ContentUnavailableView.search(text: query)
                }
                ForEach(shown, id: \.i) { seg in
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text(Export.clock(seg.t0))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 2) {
                            if let label = seg.speakerLabel {
                                Text(verbatim: label).font(.caption).foregroundStyle(.secondary)
                            }
                            Text(seg.text).font(.system(size: readingSize)).textSelection(.enabled)
                            if let tr = seg.tr, !tr.isEmpty {
                                Text(tr).font(.system(size: readingSize)).foregroundStyle(.secondary)
                                    .textSelection(.enabled)
                            }
                        }
                    }
                    // Extra air above a turn break — the reader sees the pause.
                    .padding(.top, seg.turn == true ? 12 : 1)
                    .padding(.bottom, 1)
                    .id(seg.i)
                    .listRowBackground(initialSegmentIndex == seg.i
                                       ? Color(nsColor: .findHighlightColor).opacity(0.2) : Color.clear)
                }
            }
            .task(id: "\(session.id)|\(reloadRevision)") {
                // A full read plus a JSON decode per line, off the main actor.
                // The viewer is a sheet the user can leave open, so a long
                // session must not freeze the UI on first open.
                #if SAIITY_TEST_HOOKS
                if ProcessInfo.processInfo.environment["SAIITY_CAPTURE_READER_LARGE"] == "1" {
                    readingSize = 26
                }
                #endif
                await reload {
                    await Task.yield()
                    guard !Task.isCancelled else { return }
                    if let initialSegmentIndex, segments.contains(where: { $0.i == initialSegmentIndex }) {
                        proxy.scrollTo(initialSegmentIndex, anchor: .center)
                    }
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .saiityTranscriptLibraryChanged)) { _ in
                reloadRevision += 1
            }
            }
        }
        .presentationSizing(.fitted)
    }

    private var summaryActions: some View {
        HStack(spacing: 12) {
            Button {
                if let onSummarizeWithLanguage {
                    onSummarizeWithLanguage(selectedSummaryLanguage)
                } else {
                    onSummarize()
                }
            } label: {
                if summary == nil { Text("Summarize") }
                else { Text("Summarize Again") }
            }
            .disabled(!hasLoaded || !modelAvailable || summaryUnavailable || isSummarizing
                      || (spokenLanguages.count > 1 && selectedSummaryLanguage == nil))
            if summary != nil {
                Button("Remove Summary", role: .destructive, action: onRemove)
                    .disabled(isSummarizing || CaptionSession.shared.isSummarizing)
            }
        }
        .buttonStyle(.bordered)
        .fixedSize()
    }

    private func reload(afterContentLoaded: @escaping () async -> Void) async {
        hasLoaded = false
        let session = session
        await Self.load(session: session, content: { lines, savedSummary in
            segments = lines
            summary = savedSummary
            await afterContentLoaded()
        }, languages: { codes in
            spokenLanguages = codes
            if let selectedSummaryLanguage, !summaryLanguageChoices.contains(selectedSummaryLanguage) {
                self.selectedSummaryLanguage = nil
            }
            hasLoaded = true
        })
    }

    @MainActor
    static func load(session: SessionRef,
                     analyze: @escaping @Sendable ([Segment]) async -> [String] = { TranscriptSummaryPlan.sessionLanguages($0) },
                     content: ([Segment], TranscriptSummary?) async -> Void,
                     languages: ([String]) -> Void) async {
        let reading = Task.detached(priority: .userInitiated) { () -> ([Segment], TranscriptSummary?) in
            let segments = TranscriptStore.segments(of: session)
            return (segments, TranscriptSummaryStore.read(session))
        }
        let loaded = await withTaskCancellationHandler {
            await reading.value
        } onCancel: { reading.cancel() }
        guard !Task.isCancelled else { return }
        await content(loaded.0, loaded.1)
        guard !Task.isCancelled else { return }
        let analysis = Task.detached(priority: .utility) { await analyze(loaded.0) }
        let codes = await withTaskCancellationHandler {
            await analysis.value
        } onCancel: { analysis.cancel() }
        guard !Task.isCancelled else { return }
        languages(codes)
    }
}

// MARK: - Translation languages



// MARK: - Dictation cleanup models

/// Pick which local model does dictation cleanup.
///
struct LocalModelsView: View {
    @Bindable var state: AppState
    @Environment(\.dismiss) private var dismiss

    private var visibleModels: [LocalModel] {
        LocalModel.all.filter { !$0.isLegacy || $0 == state.llmModel }
    }

    var body: some View {
        SheetShell(title: "Dictation cleanup models",
                   subtitle: "Gemma or your own GGUF · one is used at a time",
                   width: 520, height: 560) {
            List {
                ForEach(visibleModels) { m in
                    HStack(alignment: .top) {
                        // The radio is a Button so Tab reaches it and VoiceOver
                        // announces it as selectable, with the selection trait.
                        Button { state.llmModel = m } label: {
                            Image(systemName: m == state.llmModel ? "largecircle.fill.circle" : "circle")
                                .foregroundStyle(m == state.llmModel ? Color.accentColor : Color.secondary)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Use \(m.label)")
                        .accessibilityAddTraits(m == state.llmModel ? .isSelected : [])
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                Text(m.label).font(.body.weight(.medium))
                                if m.recommended {
                                    Text("recommended").font(.caption2)
                                        .padding(.horizontal, 6).padding(.vertical, 1)
                                        .background(.tint.opacity(0.2), in: Capsule())
                                }
                            }
                            Text(m.note).font(.caption).foregroundStyle(.secondary)
                            Text(m.sizeText).font(.caption2).foregroundStyle(.tertiary)
                        }
                        Spacer()
                        // Same registry asset the Models page uses, so download
                        // state, progress and the delete guards are identical
                        // wherever this model is shown.
                        if let asset = state.assets.first(where: { $0.id == "mt.llm.\(m.file)" }) {
                            AssetControl(state: state, status: asset)
                        }
                        if case .huggingFace = m.source {} else {
                            Button {
                                Task { await state.forgetCustomModel(m) }
                            } label: {
                                Image(systemName: "minus.circle")
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(.secondary)
                            .help("Forget this model and delete its file.")
                        }
                    }
                    .contentShape(Rectangle())
                    .onTapGesture { state.llmModel = m }   // convenience only; the Button above is the accessible path
                    .padding(.vertical, 3)
                }
            }
            .listStyle(.inset)

            Divider()
            addYourOwn

            if let e = state.modelError {
                Divider()
                Text(e).font(.caption).foregroundStyle(.red).padding(14)
            }
        }
    }

    @State private var customURL = ""
    @State private var adding = false

    /// Bring-your-own-model. The file picker is what actually covers Ollama:
    /// its blobs ARE GGUF files, but it publishes no download URLs, so "paste a
    /// link" alone could never reach a model the user already has on disk.
    @ViewBuilder
    private var addYourOwn: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Add your own").font(.callout.weight(.medium))
            HStack(spacing: 6) {
                TextField("Direct link to a .gguf file", text: $customURL)
                    .textFieldStyle(.roundedBorder)
                    .disableAutocorrection(true)
                Button("Add") { addByURL() }
                    .disabled(adding || URL(string: customURL)?.scheme?.hasPrefix("http") != true)
                Button("Choose file…") { addByFile() }
                    .disabled(adding)
                if adding { ProgressView().controlSize(.small) }
            }
            Text("A link downloads through the app; a chosen file is copied in. Ollama users: the blobs under ~/.ollama/models/blobs are GGUF files and can be chosen directly. The translation prompt was tuned on Qwen — another family may behave a little differently.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(14)
    }

    private func addByURL() {
        guard let url = URL(string: customURL) else { return }
        adding = true
        state.modelError = nil
        Task { @MainActor in
            defer { adding = false }
            do {
                let m = try await LocalModel.addCustom(url: url)
                customURL = ""
                await state.refreshModelsAsync(force: true)
                await state.download(m.asset(in: state))
            } catch {
                state.modelError = error.localizedDescription
            }
        }
    }

    private func addByFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.init(filenameExtension: "gguf") ?? .data]
        // Ollama blobs have no extension at all, so the filter cannot be strict.
        panel.allowsOtherFileTypes = true
        panel.canChooseDirectories = false
        panel.message = String(localized: "Choose a GGUF model file. Ollama blobs (sha256-…) work too.")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        adding = true
        state.modelError = nil
        Task { @MainActor in
            defer { adding = false }
            do {
                _ = try LocalModel.addCustom(importing: url)
                await state.refreshModelsAsync(force: true)
            } catch {
                state.modelError = error.localizedDescription
            }
        }
    }
}

private extension LocalModel {
    /// The registry asset for this model, freshly built — the stored snapshot
    /// may predate a just-added custom model.
    func asset(in state: AppState) -> ModelAsset {
        TranslationEngine.qwen.assetDescriptors.first { $0.id == "mt.llm.\(file)" }!
    }
}
