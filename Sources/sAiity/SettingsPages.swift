import AppKit
import ApplicationServices
import Carbon.HIToolbox
import CoreGraphics
import SwiftUI

// MARK: - Models

/// Everything this app has put on disk, in one place.
///
/// Every row is the same shape and comes from the same registry, so an asset
/// cannot go missing from this page the way MADLAD did — it was downloadable,
/// 1.86 GB, and had no row at all. Assets macOS owns are shown separately and
/// honestly: they can be measured but no app can delete them.
struct ModelsView: View {
    @Bindable var state: AppState

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
            LazyVStack(alignment: .leading, spacing: 14) {
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
                                .buttonStyle(.glass)
                                .controlSize(.small)
                                .help("Check downloaded models again")
                            }
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
    @State private var vocabularyText = DictationVocabulary.serialized
    @State private var whisperReady: Bool?
    @State private var whisperBusy = false
    @State private var showsProcessingDetails = false

    private func openModels() {
        SettingsWindowController.selectModelsPane()
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

    private var cleanupModelSelection: Binding<String> {
        Binding(
            get: { state.llmModel?.file ?? "" },
            set: { file in state.llmModel = cleanupModels.first { $0.file == file } })
    }

    private var whisperReadinessID: String {
        "\(state.dictationRecognizer.rawValue)|\(WhisperDictationBackend.model.rawValue)"
    }

    @ViewBuilder
    private var cleanupModelControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("Dictation cleanup", selection: cleanupModelSelection) {
                Text("Off").tag("")
                ForEach(cleanupModels) { model in
                    Text(model.label).tag(model.file)
                }
            }
            .pickerStyle(.menu)

            if let model = state.llmModel {
                HStack(alignment: .top, spacing: 8) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(model.note).font(.caption).foregroundStyle(.secondary)
                        Text(model.sizeText).font(.caption2).foregroundStyle(.tertiary)
                    }
                    Spacer(minLength: 8)
                    if let asset = state.assets.first(where: { $0.id == AssetID.llm(file: model.file) }) {
                        AssetControl(state: state, status: asset)
                    }
                }
            } else {
                Label("Ready", systemImage: "checkmark.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Button("Manage") { state.showLocalModels = true }
                .buttonStyle(.glass)
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
            VStack(alignment: .leading, spacing: 14) {
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
    }

    @ViewBuilder
    private var detailSettings: some View {
        VStack(alignment: .leading, spacing: 14) {
            SettingsSection(title: "Translation engine",
                            subtitle: "Choose the local engine used for translated dictation.") {
                Picker("Translation engine", selection: Binding(
                    get: { state.dictationTranslationEngine ?? TranslationEngine.dictationEffective },
                    set: { state.dictationTranslationEngine = $0 })) {
                    ForEach(TranslationEngine.primaryCases, id: \.self) { engine in
                        Text("\(engine.displayName) · recommended").tag(engine)
                    }
                    ForEach(TranslationEngine.advancedCases, id: \.self) { engine in
                        Text("\(engine.displayName) · experimental").tag(engine)
                    }
                }
                .pickerStyle(.menu)
                let engine = state.dictationTranslationEngine ?? TranslationEngine.dictationEffective
                Text(engine.summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            SettingsSection(title: "Recognition",
                            subtitle: "Choose the fastest local path or Whisper Auto for code-switched dictation.") {
                Picker("Dictation engine", selection: $state.dictationRecognizer) {
                    Text("Streaming").tag(DictationRecognizer.streaming)
                    Text("Whisper Auto").tag(DictationRecognizer.whisper)
                }
                .pickerStyle(.segmented)

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
                        ForEach(LanguageCatalog.all, id: \.code) { language in
                            Text(language.displayName).tag(language.code)
                        }
                    }
                    whisperStatus
                } else {
                    LabeledContent("Streaming model") {
                        Text(verbatim: ASREngine.dictationEffective.displayName)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            SettingsSection(title: "Cleanup details",
                            subtitle: "Choose the local cleanup model and protected vocabulary. The everyday on/off switch is on the Dictation page.") {
                cleanupModelControls
                TextField("Protected vocabulary (comma separated)", text: $vocabularyText)
                    .textFieldStyle(.roundedBorder)
                    .onChange(of: vocabularyText) { _, value in
                        DictationVocabulary.serialized = value
                    }
                Text("Optional names and technical terms keep their spelling during cleanup.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
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
                BubbleStylePresetControl(style: $state.dictationStyle, context: .dictation)
                MatchedFontSizeControl(style: $state.dictationStyle, context: .dictation)
                Text("Layout").font(.subheadline.weight(.medium))
                BubbleSurfaceControls(style: $state.dictationStyle)
                HStack {
                    Button("Preview") {
                        NotificationCenter.default.post(name: .saiityDictationPreview, object: nil)
                    }
                    .buttonStyle(.glass)
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
            Picker("Dictation profile", selection: Binding(
                get: { state.dictationProfile },
                set: { state.dictationProfile = $0 })) {
                ForEach(DictationProfile.allCases.filter { $0 != .custom }, id: \.self) { profile in
                    Text(profile.displayName).tag(profile)
                }
            }
            .pickerStyle(.segmented)
            if state.dictationProfile == .custom {
                Label("Custom settings", systemImage: "slider.horizontal.3")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Divider()

            Toggle("Translate dictated text", isOn: $state.translateDictation)
                .disabled(state.dictationTranslateTo?.isEmpty != false)
            HStack {
                Label("Target language", systemImage: "character.book.closed")
                Spacer()
                Button {
                    state.showDictationTranslationPicker = true
                } label: {
                    HStack(spacing: 5) {
                        Text(state.dictationTranslateTo.map { AppLanguage(code: $0).displayName }
                             ?? String(localized: "Off"))
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.caption2)
                    }
                }
            }

            Divider()

            Toggle("Clean up dictated text", isOn: $state.dictationCleanupEnabled)
                .disabled(state.llmModel?.isDownloaded != true)
            HStack {
                Label(state.llmModel?.label ?? String(localized: "Not ready"),
                      systemImage: state.llmModel?.isDownloaded == true
                          ? "checkmark.circle.fill" : "arrow.down.circle")
                    .foregroundStyle(state.llmModel?.isDownloaded == true
                                     ? Color.secondary : Color.orange)
                Spacer()
                Button("Models") { SettingsWindowController.selectModelsPane() }
                    .buttonStyle(.glass)
                    .controlSize(.small)
            }
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
                .disabled(whisperBusy)
            } else if ready == false {
                Button("Download") { prepareWhisper(choice) }
                    .controlSize(.small)
                    .disabled(whisperBusy)
                Button("Retry") { retryWhisper(choice) }
                    .controlSize(.small)
                    .disabled(whisperBusy)
            }
            Button("Models") { openModels() }
                .buttonStyle(.glass)
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
                    .buttonStyle(.glass)
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
        try await Self.removeAction(choice, invalidate: {
            await (NSApp.delegate as? AppDelegate)?.invalidateDictationBackend()
        }, remove: { choice in
            try await WhisperDictationBackend().removeModel(choice)
        }, refresh: { Task { await state.refreshModelsAsync(force: true) } }, setError: { state.modelError = $0.localizedDescription })
    }

    private func openPrivacySettings(_ pane: String) {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") else { return }
        NSWorkspace.shared.open(url)
    }
}

private struct DictationShortcutRecorder: NSViewRepresentable {
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
                widthAnchor.constraint(greaterThanOrEqualToConstant: 170),
                heightAnchor.constraint(equalToConstant: 28),
            ])
            wantsLayer = true
            layer?.cornerRadius = 8
            layer?.borderWidth = 0.5
            layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.45).cgColor
            refresh()
        }

        required init?(coder: NSCoder) { fatalError() }
        override var acceptsFirstResponder: Bool { true }

        func refresh() {
            label.stringValue = recording ? String(localized: "Press the full chord, then release…") : chord.displayString
            layer?.backgroundColor = (recording
                ? NSColor.controlAccentColor.withAlphaComponent(0.25)
                : NSColor.quaternaryLabelColor).cgColor
        }

        override func mouseDown(with event: NSEvent) {
            beginRecording()
        }

        private func beginRecording() {
            guard !recording else { return }
            recording = true
            capture.reset()
            NotificationCenter.default.post(name: .saiityDictationShortcutRecordingChanged,
                                            object: true)
            window?.makeFirstResponder(self)
            refresh()
        }

        private func endRecording() {
            guard recording else { return }
            recording = false
            capture.reset()
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
            return true
        }

        override func flagsChanged(with event: NSEvent) {
            guard recording else { super.flagsChanged(with: event); return }
            let key = UInt16(event.keyCode)
            let isDown = DictationChord.modifierIsDown(key, flags: event.modifierFlags)
            commitIfReady(capture.handle(.flagsChanged(key, isDown: isDown)))
        }

        override func keyDown(with event: NSEvent) {
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
    @State private var vocabularyText = DictationVocabulary.serialized
    @State private var showsProcessingDetails = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
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

    @ViewBuilder
    private var detailSettings: some View {
        VStack(alignment: .leading, spacing: 14) {
            SettingsSection(title: "Engine",
                            subtitle: "Choose the local recognizer.") {
                HStack {
                    Label("Recognition", systemImage: "waveform")
                    Spacer()
                    Text(state.engine?.displayName ?? String(localized: "Not set"))
                        .foregroundStyle(state.engine == nil ? .secondary : .primary)
                    Button("Models") { SettingsWindowController.selectModelsPane() }
                        .buttonStyle(.glass)
                        .controlSize(.small)
                }
                if let engine = state.engine {
                    Text(verbatim: engine.shortSummary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .help(engine.summary)
                    if case .only(let codes) = engine.coverage {
                        let names = codes.sorted()
                            .map { Locale.current.localizedString(forLanguageCode: $0) ?? $0 }
                        Label("Recognises \(names.joined(separator: ", ")) only. Other languages come out as nonsense rather than an error.",
                              systemImage: "exclamationmark.triangle")
                            .font(.caption).foregroundStyle(.orange)
                    }
                } else {
                    Label("No recognition model chosen yet. \(ASREngine.recommended.displayName) is the one to start with: it handles any language and identifies it from the audio. Download it under Models.",
                          systemImage: "sparkles")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if state.engine?.needsDownload == true {
                    Label("Not downloaded yet — see Models.", systemImage: "arrow.down.circle")
                        .font(.caption).foregroundStyle(.orange)
                }
            }

            if state.engine == .nemotron {
                SettingsSection(title: "Caption speed",
                                subtitle: "Choose how quickly captions update or how much context each update uses.") {
                    Picker("When captions appear", selection: $state.nemotronTier) {
                        Text(verbatim: CaptionLatencyCopy.title(chunkMs: 2240)).tag(2240)
                        Text(verbatim: CaptionLatencyCopy.title(chunkMs: 1120)).tag(1120)
                    }
                    .pickerStyle(.segmented)
                    if !NemotronEngine.isDownloaded(chunkMs: state.nemotronTier) {
                        Label {
                            Text(verbatim: CaptionLatencyCopy.missingDownload)
                        } icon: {
                            Image(systemName: "arrow.down.circle")
                        }
                        .font(.caption)
                        .foregroundStyle(.orange)
                    }
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
                              "Off by default. System audio on a call carries only the other participants — your own voice never enters the mix, so a saved transcript is missing your half of the conversation. On, sAiity also opens the microphone (macOS asks once) and mixes it into recognition. Audio still never leaves this Mac. Takes effect immediately, including mid-session: switching it off releases the microphone straight away.",
                                                            isOn: $state.includeMic)
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

            if state.translateTo != nil {
                SettingsSection(title: "Translation details",
                                subtitle: "Choose the local engine and when translated sentences are produced.") {
                    Picker("Translation engine", selection: Binding(
                        get: { state.translationEngine ?? .recommended },
                        set: { state.translationEngine = $0 })) {
                        ForEach(TranslationEngine.primaryCases, id: \.self) { e in
                            Text("\(e.displayName) · recommended").tag(e)
                        }
                        ForEach(TranslationEngine.advancedCases, id: \.self) { e in
                            Text("\(e.displayName) · experimental").tag(e)
                        }
                    }
                    .pickerStyle(.menu)
                    if let t = state.translateTo, !state.targetSupportedByEngine {
                        TargetUnsupportedNotice(state: state, target: t)
                    }
                    Picker("Translation mode", selection: $state.translationTiming) {
                        ForEach(TranslationTiming.allCases, id: \.self) { t in
                            Text(t.displayName).tag(t)
                        }
                    }
                    .pickerStyle(.segmented)
                }
            }

            SettingsSection(title: "Vocabulary",
                            subtitle: "Keep names and technical terms consistent across captions and dictation.") {
                TextField("Protected vocabulary (comma separated)", text: $vocabularyText)
                    .textFieldStyle(.roundedBorder)
                    .onChange(of: vocabularyText) { _, value in
                        DictationVocabulary.serialized = value
                    }
                Text("Shared with dictation. Recognized names and technical terms keep their spelling in captions.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
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
        VStack(alignment: .leading, spacing: 14) {
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
                HStack {
                    Label("Language", systemImage: "waveform")
                    Spacer()
                    Text(SettingsStateHonesty.languageLabel(for: state.engine))
                        .foregroundStyle(.secondary)
                    Button("Models") { SettingsWindowController.selectModelsPane() }
                        .buttonStyle(.glass)
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
                HStack {
                    Label("Translate to", systemImage: "character.book.closed")
                    Spacer()
                    Button {
                        state.showTranslationPicker = true
                    } label: {
                        HStack(spacing: 4) {
                            Text(state.translateTo.map { AppLanguage(code: $0).displayName }
                                 ?? String(localized: "Off"))
                            Image(systemName: "chevron.up.chevron.down")
                                .font(.caption2)
                        }
                    }
                    if state.translateTo != nil {
                        Button("Off") { state.translateTo = nil }
                            .controlSize(.small)
                    }
                }
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
        }
    }

    @ViewBuilder
    private var appearanceSections: some View {
        SettingsSection(title: "Bubble behavior",
                        subtitle: "Fine-tune the caption bubble and its interaction.") {
            BubbleStylePresetControl(style: $state.style, context: .captions)
            MatchedFontSizeControl(style: $state.style, context: .captions)
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
                .buttonStyle(.glass)
                Button("Reset position") {
                    NotificationCenter.default.post(name: .saiityResetBubble, object: nil)
                }
                .buttonStyle(.glass)
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

    private var selectedPreset: BubbleStylePreset? {
        style.matchingPreset(for: context)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Preset")
                    .font(.subheadline.weight(.medium))
                Spacer()
                if selectedPreset == nil {
                    Label("Custom", systemImage: "slider.horizontal.3")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 132), spacing: 8)], spacing: 8) {
                ForEach(BubbleStylePreset.allCases, id: \.self) { preset in
                    Button {
                        style = preset.applying(to: style, context: context)
                    } label: {
                        VStack(alignment: .leading, spacing: 8) {
                            presetPreview(preset)
                            HStack(spacing: 6) {
                                Text(preset.title)
                                    .font(.callout.weight(.medium))
                                    .lineLimit(1)
                                Spacer(minLength: 4)
                                if selectedPreset == preset {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundStyle(.tint)
                                }
                            }
                        }
                        .frame(maxWidth: .infinity, minHeight: 68, alignment: .leading)
                        .padding(10)
                        .contentShape(RoundedRectangle(cornerRadius: 8))
                    }
                    .buttonStyle(.plain)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(selectedPreset == preset
                                  ? Color.accentColor.opacity(0.12)
                                  : Color(nsColor: .controlBackgroundColor))
                    )
                    .overlay {
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(selectedPreset == preset
                                    ? Color.accentColor
                                    : Color.primary.opacity(0.12),
                                    lineWidth: selectedPreset == preset ? 1.5 : 1)
                    }
                    .accessibilityLabel(Text(preset.title))
                    .accessibilityAddTraits(selectedPreset == preset ? .isSelected : [])
                }
            }

            Text("Presets change appearance only. Behavior and translation settings stay unchanged.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func presetPreview(_ preset: BubbleStylePreset) -> some View {
        HStack(spacing: 3) {
            Capsule()
                .fill(preset == .readable ? Color.primary : Color.primary.opacity(0.65))
                .frame(width: preset == .readable ? 34 : 24, height: 5)
            Capsule()
                .fill(preset == .liquidGlass ? Color.accentColor : Color.secondary.opacity(0.65))
                .frame(width: preset == .minimal ? 14 : 22, height: 5)
            if preset == .liquidGlass {
                Image(systemName: "drop.fill")
                    .font(.caption2)
                    .foregroundStyle(.tint)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 8)
        .frame(height: 24)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
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
private struct ShortcutRecorder: NSViewRepresentable {
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
                widthAnchor.constraint(greaterThanOrEqualToConstant: 130),
                heightAnchor.constraint(equalToConstant: 28),
            ])
            wantsLayer = true
            layer?.cornerRadius = 8
            layer?.borderWidth = 0.5
            layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.45).cgColor
            refresh()
        }
        required init?(coder: NSCoder) { fatalError() }

        func refresh() {
            if recording {
                label.stringValue = String(localized: "Press keys…")
                layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.25).cgColor
            } else if let s = HotKeyCenter.shortcut(for: action) {
                label.stringValue = s.displayString
                layer?.backgroundColor = NSColor.controlBackgroundColor
                    .withAlphaComponent(0.72).cgColor
            } else {
                label.stringValue = String(localized: "Not set")
                layer?.backgroundColor = NSColor.controlBackgroundColor
                    .withAlphaComponent(0.72).cgColor
            }
        }

        override var acceptsFirstResponder: Bool { true }
        override func mouseDown(with event: NSEvent) {
            arm()
        }

        private func arm() {
            recording = true
            window?.makeFirstResponder(self)
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
                recording = false; onChange?(nil); refresh(); return
            }
            if event.keyCode == UInt16(kVK_Escape) {
                recording = false; refresh(); return
            }
            let mods = Shortcut.carbonModifiers(from: event.modifierFlags)
            let s = Shortcut(keyCode: UInt32(event.keyCode), modifiers: mods)
            guard s.isUsable else { return }   // keep listening until it is valid
            recording = false
            onChange?(s)
            refresh()
        }

        override func resignFirstResponder() -> Bool {
            recording = false
            refresh()
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
    @State private var viewing: SessionRef?
    @State private var retentionDays = TranscriptRetention.days
    @State private var retranslator = Retranslator()
    @State private var retranslateProgress: Retranslator.Progress?
    @State private var retranslateNote: String?
    @State private var retranslating: SessionRef?

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 14) {
            SettingsSection(title: "Recording") {
                Toggle("Save transcripts of sessions", isOn: $state.saveTranscript)
                Picker("Keep transcripts", selection: $retentionDays) {
                    ForEach(TranscriptRetention.choices, id: \.self) { d in
                        Text(TranscriptRetention.label(d)).tag(d)
                    }
                }
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
                    let n = TranscriptRetention.sweep()
                    retranslateNote = "✓ " + String(localized: "Deleted \(n) transcripts.")
                    Task { await state.refreshLibraryAsync(force: true) }
                }
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
                            viewing = hit.session
                        } label: {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(hit.session.meta.startedAt.formatted(date: .abbreviated, time: .shortened))
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
                        HStack {
                            // A real Button, not a tap gesture: the row has to
                            // open from the keyboard and VoiceOver too.
                            Button {
                                viewing = s
                            } label: {
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(s.meta.startedAt.formatted(date: .abbreviated, time: .shortened))
                                    Text("\(s.meta.lineCount) lines · \(s.meta.locale)")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .help("Open this transcript")
                            Spacer()
                            Menu("Export") {
                                Button("SRT") { export(s, "srt") }
                                Button("WebVTT") { export(s, "vtt") }
                                Button("Markdown") { export(s, "md") }
                            }
                            .controlSize(.small)
                            .fixedSize()
                            // Translate a transcript after the fact — into a
                            // language you did not choose at record time, or
                            // at all if translation was off then.
                            Menu("Translate") {
                                ForEach(state.recentTargetsForMenu, id: \.self) { code in
                                    Button(AppLanguage(code: code).displayName) {
                                        startRetranslate(s, to: code)
                                    }
                                }
                            }
                            .controlSize(.small)
                            .fixedSize()
                            .disabled(retranslator.running || state.sessions.isEmpty)
                            Button {
                                NSWorkspace.shared.activateFileViewerSelecting([s.url])
                            } label: { Image(systemName: "folder") }
                                .controlSize(.small)
                                .help("Show this transcript in Finder")
                                .accessibilityLabel("Show this transcript in Finder")
                            Button(role: .destructive) {
                                TranscriptStore.delete(s)
                                    SessionCatalog.invalidate()
                                    Task { await state.refreshLibraryAsync(force: true) }
                            } label: { Image(systemName: "trash") }
                                .controlSize(.small)
                                .help("Delete this transcript permanently")
                                .accessibilityLabel("Delete this transcript permanently")
                        }
                    }
                }
                if let p = retranslateProgress {
                    VStack(alignment: .leading, spacing: 4) {
                        ProgressView(value: Double(p.done), total: Double(max(p.total, 1)))
                        HStack {
                            Text("\(p.note) \(p.done)/\(p.total)")
                                .font(.caption).foregroundStyle(.secondary)
                            Spacer()
                            Button("Cancel") { retranslator.cancel() }
                                .controlSize(.small)
                        }
                    }
                }
                if let note = retranslateNote {
                    // Both branches boxed: a ternary mixing .secondary
                    // (HierarchicalShapeStyle) with .orange (Color) has no
                    // common type for the compiler to settle on.
                    Text(note).font(.caption)
                        .foregroundStyle(note.hasPrefix("✓")
                                         ? AnyShapeStyle(.secondary)
                                         : AnyShapeStyle(Color.orange))
                }
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
                    }
                    Button("Delete all…", role: .destructive) {
                        let a = NSAlert()
                        a.messageText = String(localized: "Delete all transcripts?")
                        a.informativeText = String(localized: "Permanently removes \(state.sessions.count) sessions.")
                        a.addButton(withTitle: String(localized: "Delete All"))
                        a.addButton(withTitle: String(localized: "Cancel"))
                        a.alertStyle = .warning
                        if a.runModal() == .alertFirstButtonReturn {
                            TranscriptStore.deleteAll()
                            SessionCatalog.invalidate()
                            Task { await state.refreshLibraryAsync(force: true) }
                        }
                    }
                    .controlSize(.small)
                }
            }

            }
            .padding(.horizontal, 24)
            .padding(.vertical, 8)
            .frame(maxWidth: 780, alignment: .leading)
        }
        .task(id: "\(trimmedQuery)|\(state.sessions.count)") {
            await refreshSearch()
        }
        .sheet(item: $viewing) { TranscriptViewerSheet(session: $0) }
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
        let result = await Task.detached(priority: .userInitiated) {
            Self.search(sessions: sessions, query: q)
        }.value
        guard !Task.isCancelled else { return }
        searchHits = result
        isSearching = false
    }

    nonisolated private static func search(sessions: [SessionRef], query: String) -> [SearchHit] {
        var out: [SearchHit] = []
        for session in sessions {
            for segment in TranscriptStore.segments(of: session) {
                if segment.text.localizedCaseInsensitiveContains(query)
                    || (segment.tr?.localizedCaseInsensitiveContains(query) ?? false) {
                    out.append(SearchHit(id: "\(session.id)#\(segment.i)",
                                          session: session,
                                          seg: segment))
                }
            }
        }
        return out
    }

    private func startRetranslate(_ s: SessionRef, to code: String) {
        retranslateNote = nil
        retranslating = s
        retranslator.run(session: s, target: code) { p in
            retranslateProgress = p
        } onFinish: { err in
            retranslateProgress = nil
            retranslating = nil
            if let err {
                retranslateNote = err
            } else {
                retranslateNote = "✓ " + String(localized: "Translated into \(AppLanguage(code: code).displayName).")
                Task { await state.refreshLibraryAsync(force: true) }
            }
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
        default: text = Export.markdown(segs, meta: s.meta)
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
    }

    private func permissionLabel(_ granted: Bool?) -> String {
        guard let granted else { return String(localized: "Checking…") }
        return granted ? String(localized: "Ready") : String(localized: "Permission required")
    }

    private func dictationStatusLabel(enabled: Bool,
                                     input: Bool?,
                                     accessibility: Bool?) -> String {
        guard enabled else { return String(localized: "Off") }
        guard input == true else { return permissionLabel(input) }
        guard let accessibility else { return String(localized: "Checking…") }
        return accessibility
            ? String(localized: "Ready")
            : String(localized: "Shortcut ready — Accessibility needed")
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
            VStack(alignment: .leading, spacing: 14) {
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
                value: dictationStatusLabel(enabled: state.dictationEnabled,
                                            input: inputMonitoringGranted,
                                            accessibility: accessibilityGranted),
                actionTitle: state.dictationEnabled
                    && (inputMonitoringGranted == false || accessibilityGranted == false)
                    ? "Open Settings" : nil) {
                    if inputMonitoringGranted == false {
                        InputMonitoringPermission.openSettings()
                    } else {
                        openAccessibilitySettings()
                    }
                }
        }

        SettingsSection(title: "Startup") {
            LabeledToggle("Start sAiity when you log in",
                          "Registers the app as a login item so captions are one keypress away after a restart. Off by default — this app can capture system audio, so being running should be your choice.",
                                                    isOn: Binding(get: { state.launchAtLogin },
                                        set: { state.setLaunchAtLogin($0) }))
            if !state.launchAtLoginNote.isEmpty {
                Text(state.launchAtLoginNote).font(.caption).foregroundStyle(.orange)
            }
        }

        SettingsSection(title: "Privacy") {
            Text("Audio never leaves this Mac. Recognition, translation, and transcripts stay on this Mac.")
                .font(.caption)
        }
    }

    @ViewBuilder
    private var detailSettings: some View {
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
                .buttonStyle(.glass)
                .controlSize(.small)
                Text("Walks through permission and models from the start.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Button("Save diagnostics…") { Diagnostics.save() }
                    .buttonStyle(.glass)
                    .controlSize(.small)
                Text("Writes one text file with the app's state and this run's log, for bug reports. Review it before sharing.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .id(diagnosticsRevision)

        SettingsSection(title: "About sAiity",
                        subtitle: "Version, licence, and the credits for the models and libraries used here.") {
            LabeledContent("Version", value: version)
            Text(credits)
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// Read a saved transcript where it lives. Before this the app recorded
/// durable transcripts and offered no way to look at one — the session row
/// showed only metadata, and reading a line meant exporting the session or
/// opening segments.jsonl in Finder.
private struct TranscriptViewerSheet: View {
    let session: SessionRef
    @State private var segments: [Segment] = []
    @State private var query = ""

    private var shown: [Segment] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return segments }
        return segments.filter {
            $0.text.localizedCaseInsensitiveContains(q)
                || ($0.tr?.localizedCaseInsensitiveContains(q) ?? false)
        }
    }

    var body: some View {
        SheetShell(title: "Transcript — \(session.meta.startedAt.formatted(date: .abbreviated, time: .shortened))",
                   subtitle: "Times count from the session start. Text can be selected and copied.",
                   width: 560, height: 560,
                   headerAccessory: {
                       TextField("Search", text: $query)
                           .textFieldStyle(.roundedBorder)
                           .frame(width: 160)
                   }) {
            VStack(spacing: 0) {
                List(shown, id: \.i) { seg in
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text(Export.clock(seg.t0))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(seg.text).textSelection(.enabled)
                            if let tr = seg.tr, !tr.isEmpty {
                                Text(tr).foregroundStyle(.secondary)
                                    .textSelection(.enabled)
                            }
                        }
                    }
                    // Extra air above a turn break — the reader sees the pause.
                    .padding(.top, seg.turn == true ? 12 : 1)
                    .padding(.bottom, 1)
                }
                .overlay {
                    if shown.isEmpty, !query.isEmpty {
                        ContentUnavailableView.search(text: query)
                    }
                }
            }
            .task {
                segments = TranscriptStore.segments(of: session)
            }
        }
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
                                LocalModel.removeCustom(m)
                                Task { await state.refreshModelsAsync(force: true) }
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
