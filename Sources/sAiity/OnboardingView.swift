import AppKit
import SwiftUI

/// The first-run wizard.
///
/// What it replaces: a fresh install used to open to an idle menu-bar icon with
/// no explanation. Clicking "Start captions" then began a silent 634 MB download
/// and finished by failing on a permission the user had never been asked for,
/// with the error shown only inside a caption bubble.
@MainActor
@Observable
final class OnboardingModel {
    var step: OnboardingStep = .setup
    var screenRecordingGranted = false
    var inputMonitoringGranted = false
    var checkingPermission = false
    var askedOnce = false

    enum UseCase: String, CaseIterable {
        case captions, dictation, both

        var title: String {
            switch self {
            case .captions: return String(localized: "Captions")
            case .dictation: return String(localized: "Dictation")
            case .both: return String(localized: "Captions + Dictation")
            }
        }

        var detail: String {
            switch self {
            case .captions: return String(localized: "Subtitles for anything your Mac plays, optionally translated.")
            case .dictation: return String(localized: "Hold a shortcut and speak; the text appears where you type.")
            case .both: return String(localized: "Dictation and captions share one speech model.")
            }
        }

        var includesCaptions: Bool { self == .captions || self == .both }
        var includesDictation: Bool { self == .dictation || self == .both }
    }

    var useCase: UseCase = .both

    /// What the user says they need, which decides what gets downloaded.
    enum Purpose: String, CaseIterable {
        case anyLanguage, englishOnly

        /// The old English-only choice remains representable for migration, but
        /// onboarding now offers the single supported recognition path.
        static var allCases: [Purpose] { [.anyLanguage] }

        var title: String {
            switch self {
            case .anyLanguage: return String(localized: "Any language")
            case .englishOnly: return String(localized: "English only")
            }
        }
        var detail: String {
            switch self {
            case .anyLanguage:
                return String(localized: "One multilingual model that works out which language is being spoken. 634 MB.")
            case .englishOnly:
                return String(localized: "A smaller, faster English-only model. 437 MB. Other languages come out as nonsense, so only pick this if English is all you need.")
            }
        }
        var engine: ASREngine {
            switch self {
            case .anyLanguage, .englishOnly: return .nemotron
            }
        }
    }

    var purpose: Purpose = .anyLanguage
    var wantsAutoUpdates: Bool
    var trial: UseCase?
    var trialBusy = false
    var trialRecording = false
    var trialStatus = ""
    var trialText = ""
    var trialPermissionPane: String?
    var trialInputHealth: DictationInputHealth?
    var trialMicrophoneName: String?

    func openTrial(_ kind: UseCase) {
        guard !trialBusy else { return }
        step = .finish
        trial = kind
    }

    /// Which way the last step change went, so the transition can match it.
    var goingBack = false
    /// When the permission step advanced itself. A Continue click already in
    /// flight when that happens would land on the NEXT step's button — same
    /// place, different meaning — and silently skip the purpose choice.
    var lastAutoAdvance: Date?

    let state: AppState
    init(state: AppState, defaults: UserDefaults = .standard) {
        self.state = state
        wantsAutoUpdates = defaults.bool(forKey: "SUEnableAutomaticChecks")
        if let resume = defaults.string(forKey: Onboarding.resumeKey).flatMap(OnboardingStep.init(rawValue:)) {
            switch resume {
            case .purpose, .models: step = .setup
            case .welcome: step = .permission
            default: step = resume
            }
            defaults.removeObject(forKey: Onboarding.resumeKey)
        }
    }

    var needsScreenRecording: Bool { useCase.includesCaptions }
    var needsInputMonitoring: Bool { useCase.includesDictation }
    var permissionGranted: Bool {
        (!needsScreenRecording || screenRecordingGranted)
            && (!needsInputMonitoring || inputMonitoringGranted)
    }

    func refreshPermission() async {
        checkingPermission = true
        screenRecordingGranted = needsScreenRecording
            ? await ScreenRecordingPermission.probe()
            : true
        inputMonitoringGranted = needsInputMonitoring
            ? InputMonitoringPermission.preflight
            : true
        checkingPermission = false
    }

    /// Write the choices through the same paths Settings uses, so nothing here
    /// is a special case that can drift.
    func apply() {
        ASREngine.selected = purpose.engine
        state.engine = purpose.engine
        state.dictationEnabled = useCase.includesDictation
    }

    /// The asset onboarding offers to download: the engine's currently-selected
    /// variant. Nemotron has two latency tiers; a fresh install gets the
    /// default (balanced) one, so `.first` matching the selection is right.
    var recognitionAsset: ModelAsset {
        let all = purpose.engine.assetDescriptors
        // `?? all.first { $0.recommended }` and not `?? all[0]`: with nothing
        // selected yet, index 0 is the fast tier — the ~640 MB variant whose own
        // description warns it costs roughly double the encoder work.
        return all.first { $0.use.isSelected }
            ?? all.first { $0.recommended }
            ?? all[0]
    }

    /// First-run keeps the download decision to recognition. Translation is an
    /// optional follow-up in Settings, so setup stays quick and predictable.
    var assetsToOffer: [ModelAsset] {
        [recognitionAsset]
    }
}

struct OnboardingView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Bindable var model: OnboardingModel
    let onFinish: () -> Void
    @State private var permissions = PermissionMonitor()
    @State private var tryText = ""
    @FocusState private var tryFieldFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            content
                .id(model.step)
                .transition(reduceMotion ? .opacity : .push(from: model.goingBack ? .leading : .trailing))
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .animation(reduceMotion ? nil : .smooth(duration: 0.28), value: model.step)
            Divider()
            footer
        }
        .frame(width: 620, height: 640)
        .task { await permissions.watch() }
    }

    @ViewBuilder
    private var content: some View {
        switch model.step {
        case .permission: permission
        case .setup, .welcome, .purpose, .models: setup
        case .finish: finish
        }
    }

    /// App icon, title and one line: where the user is and why.
    private func header(_ title: LocalizedStringKey, _ subtitle: LocalizedStringKey) -> some View {
        VStack(spacing: 6) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 64, height: 64)
                .accessibilityHidden(true)
            Text(title).font(.title2.weight(.semibold))
            Text(subtitle)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 440)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 24)
        .padding(.bottom, 4)
    }

    // MARK: - Steps

    private var setup: some View {
        VStack(spacing: 0) {
            header("Welcome to Syllivra",
                   "Dictation and live captions that run entirely on your Mac.")
            Form {
                Section {
                    Picker("Use Syllivra for", selection: $model.useCase) {
                        ForEach(OnboardingModel.UseCase.allCases, id: \.self) { useCase in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(verbatim: useCase.title)
                                Text(verbatim: useCase.detail)
                                    .font(.callout)
                                    .foregroundStyle(.secondary)
                            }
                            .tag(useCase)
                        }
                    }
                    .pickerStyle(.radioGroup)
                    .labelsHidden()
                } header: {
                    Text("Use Syllivra for")
                }
                Section {
                    ForEach(model.assetsToOffer) { asset in
                        let status = model.state.assets.first { $0.asset.id == asset.id }
                        LabeledContent {
                            if status?.isInstalled == true {
                                Text("Downloaded").foregroundStyle(.secondary)
                            } else if let status {
                                AssetControl(state: model.state, status: status, prominent: true)
                            } else {
                                ProgressView().controlSize(.small)
                            }
                        } label: {
                            Text(verbatim: ASREngine.nemotron.displayName)
                            Text(verbatim: ASREngine.nemotron.shortSummary)
                        }
                    }
                    if let e = model.state.modelError {
                        Text(verbatim: e).foregroundStyle(.red)
                    }
                } header: {
                    Text("Speech model")
                } footer: {
                    Text("Downloaded once from Hugging Face. After that, nothing leaves this Mac.")
                        .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
        }
        .task { await model.state.refreshModelsAsync(force: true) }
    }

    private var neededPermissions: [AppPermission] {
        AppPermission.allCases.filter {
            ($0.feature == .dictation && model.useCase.includesDictation)
                || ($0.feature == .captions && model.useCase.includesCaptions)
        }
    }

    private var permissionsGranted: Bool {
        neededPermissions.allSatisfy { permissions.status($0) == .granted }
    }

    private var permission: some View {
        VStack(spacing: 0) {
            header("Allow access",
                   "macOS asks you to confirm each one. Syllivra uses them only for what is written here.")
            Form {
                Section {
                    ForEach(neededPermissions) { permission in
                        PermissionRow(permission: permission, status: permissions.status(permission))
                    }
                } footer: {
                    if !permissionsGranted {
                        Text("After you switch Syllivra on in System Settings, come back here. Each row updates by itself.")
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .formStyle(.grouped)
        }
        .onChange(of: permissionsGranted) { _, granted in
            model.screenRecordingGranted = permissions.status(.screenRecording) == .granted
            model.inputMonitoringGranted = permissions.status(.inputMonitoring) == .granted
            guard granted, model.step == .permission else { return }
            NSApp.activate()
        }
    }

    private var dictationShortcut: String { model.state.dictationChord.displayString }

    private var finish: some View {
        VStack(spacing: 0) {
            header("Try it",
                   "A quick check before you start.")
            Form {
                if model.useCase.includesDictation {
                    Section {
                        Text("Click in the box, hold \(dictationShortcut), say a sentence, then let go.")
                        TextEditor(text: $tryText)
                            .font(.body)
                            .frame(minHeight: 80)
                            .focused($tryFieldFocused)
                            .accessibilityLabel(Text("Try dictation here"))
                        LabeledContent {
                            Button(model.trial == .dictation && model.trialRecording
                                   ? String(localized: "Stop & Transcribe")
                                   : String(localized: "Test Without Shortcut")) {
                                Task { await (NSApp.delegate as? AppDelegate)?.tryOnboarding(.dictation, model: model) }
                            }
                            .disabled(model.trialBusy && !(model.trial == .dictation && model.trialRecording))
                        } label: {
                            Text("Microphone check")
                            Text("Records one sentence and shows the result here, without the shortcut.")
                        }
                        if model.trial == .dictation {
                            trialFeedback
                        }
                    } header: {
                        Text("Dictation")
                    }
                }
                if model.useCase.includesCaptions {
                    Section {
                        LabeledContent {
                            Button(model.trial == .captions && model.trialBusy
                                   ? String(localized: "Stop Captions")
                                   : String(localized: "Try Captions")) {
                                Task { await (NSApp.delegate as? AppDelegate)?.tryOnboarding(.captions, model: model) }
                            }
                            .disabled(model.trialBusy && model.trial != .captions)
                        } label: {
                            Text("Play a video with speech, then start captions.")
                            if let shortcut = HotKeyCenter.shortcut(for: .toggleCaptions)?.displayString {
                                Text("Later, start them from the menu bar or with \(shortcut).")
                            } else {
                                Text("Later, start them from the menu bar.")
                            }
                        }
                        if model.trial == .captions, !model.trialStatus.isEmpty {
                            Text(model.trialStatus).foregroundStyle(.secondary)
                        }
                    } header: {
                        Text("Captions")
                    }
                }
                Section {
                    Toggle(isOn: $model.wantsAutoUpdates) {
                        Text("Check for updates automatically")
                        Text("About once a day. Sends no audio, text or identifiers.")
                    }
                }
            }
            .formStyle(.grouped)
        }
        .onAppear { tryFieldFocused = model.useCase.includesDictation }
    }

    @ViewBuilder
    private var trialFeedback: some View {
        if !model.trialStatus.isEmpty {
            Text(model.trialStatus)
                .foregroundStyle(.secondary)
                .accessibilityAddTraits(.updatesFrequently)
        }
        if model.trialRecording || model.trialInputHealth != nil {
            LabeledContent {
                EmptyView()
            } label: {
                Text(verbatim: model.trialMicrophoneName ?? String(localized: "Microphone name unavailable"))
                Text(verbatim: model.trialInputHealth?.trialHint
                     ?? String(localized: "Speak a short sentence to check this microphone."))
            }
        }
        if !model.trialText.isEmpty {
            Text(model.trialText)
                .textSelection(.enabled)
        }
        if !model.trialBusy, let pane = model.trialPermissionPane {
            LabeledContent("Permission") {
                Button("Open Settings…") {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") {
                        NSWorkspace.shared.open(url)
                    }
                }
            }
        }
    }

    // MARK: - Chrome

    private var footer: some View {
        let steps = OnboardingStep.allCases
        let index = (steps.firstIndex(of: model.step) ?? 0) + 1
        return HStack {
            Text("Step \(index) of \(steps.count)")
                .foregroundStyle(.secondary)
            Spacer()
            if model.step != steps.first {
                Button("Back") { back() }
            }
            Button(primaryTitle) { advance() }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    private var primaryTitle: LocalizedStringKey {
        switch model.step {
        case .finish: "Done"
        case .permission where !permissionsGranted: "Skip for Now"
        default: "Continue"
        }
    }

    private func advance() {
        if let auto = model.lastAutoAdvance, Date().timeIntervalSince(auto) < 0.7 {
            return
        }
        let steps = OnboardingStep.allCases
        guard let i = steps.firstIndex(of: model.step) else { return }
        model.goingBack = false
        if model.step == .setup { model.apply() }
        if model.step == .finish {
            // Sparkle reads this defaults key itself; no updater API needed.
            UserDefaults.standard.set(model.wantsAutoUpdates, forKey: "SUEnableAutomaticChecks")
            Onboarding.complete()
            onFinish()
            return
        }
        model.step = steps[min(i + 1, steps.count - 1)]
    }

    private func back() {
        let steps = OnboardingStep.allCases
        guard let i = steps.firstIndex(of: model.step), i > 0 else { return }
        model.goingBack = true
        model.step = steps[i - 1]
    }
}

/// Hosts the wizard in a real window, and puts the app in the Dock while it is
/// up — see `ForegroundActivation` for why an agent app has to.
@MainActor
final class OnboardingWindowController: NSObject, NSWindowDelegate {
    static let shared = OnboardingWindowController()
    private var window: NSWindow?
    private var model: OnboardingModel?

    func show(state: AppState, initialStep: OnboardingStep? = nil, trial: OnboardingModel.UseCase? = nil) {
        if let w = window {
            if let initialStep, model?.trialBusy != true { model?.step = initialStep }
            if let trial { model?.openTrial(trial) }
            NSApp.activate()
            w.makeKeyAndOrderFront(nil)
            return
        }
        let model = OnboardingModel(state: state)
        if let initialStep { model.step = initialStep }
        if let trial { model.openTrial(trial) }
        self.model = model
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 620, height: 640),
                         styleMask: [.titled, .closable],
                         backing: .buffered, defer: false)
        w.title = String(localized: "Set up Syllivra")
        // Give the native titlebar and window controls a solid system surface.
        w.makeOpaqueSettingsSurface()
        w.center()
        w.isReleasedWhenClosed = false
        w.delegate = self
        w.contentViewController = NSHostingController(
            rootView: OnboardingView(model: model) { [weak self] in self?.close() })
        window = w
        ForegroundActivation.begin()
        w.makeKeyAndOrderFront(nil)
    }

    private func close() {
        window?.close()
    }

    func windowWillClose(_ notification: Notification) {
        (NSApp.delegate as? AppDelegate)?.cancelOnboardingTrial()
        // Closing without finishing is a decision, not a completion.
        if Onboarding.needsRun { Onboarding.dismiss() }
        ForegroundActivation.end()
        model = nil
        window = nil
    }
}
