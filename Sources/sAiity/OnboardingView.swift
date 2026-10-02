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
    var wantsAutoUpdates = false
    var trial: UseCase?
    var trialBusy = false
    var trialRecording = false
    var trialStatus = ""
    var trialText = ""
    var trialPermissionPane: String?

    /// Which way the last step change went, so the transition can match it.
    var goingBack = false
    /// When the permission step advanced itself. A Continue click already in
    /// flight when that happens would land on the NEXT step's button — same
    /// place, different meaning — and silently skip the purpose choice.
    var lastAutoAdvance: Date?

    let state: AppState
    init(state: AppState) {
        self.state = state
        if let resume = Onboarding.resumeStep {
            switch resume {
            case .purpose, .models: step = .setup
            case .welcome: step = .permission
            default: step = resume
            }
            Onboarding.resumeStep = nil
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

    var body: some View {
        VStack(spacing: 0) {
            stepIndicator
                .padding(.horizontal, 28)
                .padding(.top, 22)
                .padding(.bottom, 4)
            // Centred rather than pinned to the top. Every step used to sit in
            // the top third with two thirds of the window empty under it, which
            // reads as a screen that has not finished loading.
            //
            // Push, not crossfade: an assistant moves forward through pages,
            // and the motion should say so.
            content
                .id(model.step)
                .transition(reduceMotion ? .opacity : .push(from: model.goingBack ? .leading : .trailing))
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                .padding(.horizontal, 28)
                .animation(reduceMotion ? nil : .smooth(duration: 0.28), value: model.step)
            Divider()
            footer
        }
        .frame(width: 640, height: 600)
        // The window's own translucency, not a painted gradient — the same
        // material Settings uses, so the two windows read as one app. See
        // VibrantBackground for why this is the honest version of "fancy".
        .background(VibrantBackground())
    }

    /// Where you are, and how much is left. The step name alone in the corner
    /// answered neither.
    private var stepIndicator: some View {
        let steps = OnboardingStep.allCases
        let current = steps.firstIndex(of: model.step) ?? 0
        return ProgressView(value: Double(current + 1), total: Double(steps.count))
            .progressViewStyle(.linear)
            .tint(.accentColor)
            .accessibilityElement()
            .accessibilityLabel(Text("Step \(current + 1) of \(steps.count)"))
    }

    @ViewBuilder
    private var content: some View {
        switch model.step {
        case .permission: permission
        case .setup: setup
        case .welcome, .purpose, .models: setup
        case .finish: finish
        }
    }

    // MARK: - Steps

    /// The setup-assistant header every step past the welcome shares: symbol
    /// over title over subtitle, centred — the grammar Apple's own assistants
    /// use, so each page answers "where am I and why" before any control.
    private func header(_ symbol: String, _ title: LocalizedStringKey,
                        _ subtitle: LocalizedStringKey) -> some View {
        VStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 34, weight: .medium))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.tint)
                .accessibilityHidden(true)
            Text(title).font(.title2.weight(.semibold))
            Text(subtitle)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 460)
        }
        .frame(maxWidth: .infinity)
        .padding(.bottom, 16)
    }

    private var permission: some View {
        VStack(alignment: .leading, spacing: 14) {
            header("lock.shield",
                   "Permission",
                   "Everything runs on this Mac. No audio ever leaves it.")

            if model.needsScreenRecording {
                permissionRow(
                    title: "Screen Recording",
                    symbol: "rectangle.dashed.badge.record",
                    granted: model.screenRecordingGranted,
                    explanation: "macOS has no separate permission for system audio — Screen Recording is the one that gates it. sAiity records no video and takes no screenshots.") {
                        ScreenRecordingPermission.request()
                        model.askedOnce = true
                        Task { await model.refreshPermission() }
                    } openSettings: {
                        ScreenRecordingPermission.openSettings()
                    }
                if model.askedOnce, ScreenRecordingPermission.canRelaunch,
                   !model.screenRecordingGranted {
                    Button("Quit & Reopen") { ScreenRecordingPermission.relaunch() }
                        .controlSize(.small)
                }
            }

            if model.needsInputMonitoring {
                permissionRow(
                    title: "Input Monitoring",
                    symbol: "keyboard",
                    granted: model.inputMonitoringGranted,
                    explanation: "Required to detect your dictation shortcut in other apps.") {
                        InputMonitoringPermission.request()
                        model.askedOnce = true
                        Task { await model.refreshPermission() }
                    } openSettings: {
                        InputMonitoringPermission.openSettings()
                    }
            }

            if model.needsInputMonitoring {
                Label("Accessibility is requested only when dictation inserts text into another app.",
                      systemImage: "info.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if model.checkingPermission { ProgressView().controlSize(.small) }
            Spacer()
        }
        .task { await model.refreshPermission() }
        // Coming back from System Settings is the strongest signal there is that
        // something changed — better than polling alone.
        .onReceive(NotificationCenter.default.publisher(
            for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await model.refreshPermission() }
        }
        // When the permission arrives, take the step: the user's only next
        // action was Continue, and making them find it after a round-trip
        // through System Settings is friction with no decision inside it. The
        // beat is so the "Granted" checkmark is seen, not skipped past.
        .onChange(of: model.permissionGranted) { _, granted in
            guard granted, model.step == .permission else { return }
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 600_000_000)
                guard model.permissionGranted, model.step == .permission else { return }
                model.lastAutoAdvance = Date()
                model.goingBack = false
                let steps = OnboardingStep.allCases
                if let i = steps.firstIndex(of: model.step) {
                    model.step = steps[min(i + 1, steps.count - 1)]
                }
            }
        }
    }

    @ViewBuilder
    private func permissionRow(title: LocalizedStringKey,
                               symbol: String,
                               granted: Bool,
                               explanation: LocalizedStringKey,
                               request: @escaping () -> Void,
                               openSettings: @escaping () -> Void) -> some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(granted ? String(localized: "Granted.") : String(localized: "Not granted yet."))
                        .foregroundStyle(granted ? AnyShapeStyle(.green) : AnyShapeStyle(.secondary))
                    Spacer()
                }
                if !granted {
                    Text(explanation)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    HStack {
                        Button("Allow…", action: request)
                            .buttonStyle(.glassProminent)
                        Button("Open Settings", action: openSettings)
                    }
                }
            }
        } label: {
            Label {
                Text(title)
            } icon: {
                Image(systemName: granted ? "checkmark.circle.fill" : symbol)
                    .foregroundStyle(granted ? AnyShapeStyle(.green) : AnyShapeStyle(.orange))
            }
        }
    }

    private var setup: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                header("sparkles",
                       "What for",
                       "Choose what you want to use. You can change this later in Settings.")

                Picker("Use case", selection: $model.useCase) {
                    ForEach(OnboardingModel.UseCase.allCases, id: \.self) { useCase in
                        Text(verbatim: useCase.title).tag(useCase)
                    }
                }
                .pickerStyle(.segmented)
                Text(verbatim: model.useCase.includesCaptions && model.useCase.includesDictation
                     ? String(localized: "One download and you are set")
                     : model.useCase.includesCaptions
                         ? String(localized: "It captures the audio your Mac plays — the microphone stays off unless you later opt in under Settings → Captions.")
                         : String(localized: "Dictation is separate from live captions. It never starts the caption service and is not saved as a meeting transcript."))
                    .font(.callout)
                    .foregroundStyle(.secondary)

                Divider().padding(.vertical, 4)
                GroupBox {
                    HStack(spacing: 10) {
                        Image(systemName: "waveform")
                            .font(.title3)
                            .foregroundStyle(.tint)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(verbatim: ASREngine.nemotron.displayName)
                                .font(.headline)
                            Text(verbatim: ASREngine.nemotron.shortSummary)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                } label: {
                    Text("Recognition model")
                }

                Divider().padding(.vertical, 4)
                ForEach(model.assetsToOffer) { asset in
                    let status = model.state.assets.first { $0.asset.id == asset.id }
                    GroupBox {
                        HStack(alignment: .top, spacing: 12) {
                            Text(verbatim: asset.detail)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Spacer(minLength: 12)
                            if status?.isInstalled == true {
                                Label("Ready", systemImage: "checkmark.circle.fill")
                                    .foregroundStyle(.green).font(.callout)
                            } else if let status {
                                AssetControl(state: model.state, status: status, prominent: true)
                            } else {
                                HStack(spacing: 8) {
                                    ProgressView()
                                        .controlSize(.small)
                                    Text("Checking download…")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    } label: {
                        Text(verbatim: asset.title)
                            .font(.headline)
                    }
                }
                if let e = model.state.modelError {
                    Text(e).font(.caption).foregroundStyle(.red)
                }
            }
        }
        .task { await model.state.refreshModelsAsync(force: true) }
    }

    private var finish: some View {
        ScrollView {
        VStack(alignment: .leading, spacing: 14) {
            header("checkmark.seal",
                   "Try it out",
                   "An optional check before you finish setup.")
            GroupBox {
                VStack(alignment: .leading, spacing: 10) {
                    Text("For dictation, record a short sentence, then stop to see the result here. For captions, play speech on your Mac.")
                        .font(.callout).foregroundStyle(.secondary)
                    HStack {
                        if model.useCase.includesDictation {
                            Button(model.trial == .dictation && model.trialRecording ? "Stop & Transcribe" : "Try Dictation") {
                                Task { await (NSApp.delegate as? AppDelegate)?.tryOnboarding(.dictation, model: model) }
                            }
                            .buttonStyle(.bordered)
                            .disabled(model.trialBusy && !(model.trial == .dictation && model.trialRecording))
                        }
                        if model.useCase.includesCaptions {
                            Button(model.trial == .captions && model.trialBusy ? "Stop Captions" : "Try Captions") {
                                Task { await (NSApp.delegate as? AppDelegate)?.tryOnboarding(.captions, model: model) }
                            }
                            .buttonStyle(.bordered)
                            .disabled(model.trialBusy && model.trial != .captions)
                        }
                    }
                    if !model.trialStatus.isEmpty {
                        Text(model.trialStatus).font(.callout)
                            .accessibilityAddTraits(.updatesFrequently)
                    }
                    if !model.trialText.isEmpty {
                        Text(model.trialText).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(10).background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
                    }
                    Text("The dictation trial leaves your clipboard and other apps untouched. Stop captions or close setup to end the trial.")
                        .font(.caption).foregroundStyle(.secondary)
                    if !model.trialBusy, !model.trialStatus.isEmpty, model.trialText.isEmpty {
                        HStack {
                            if let pane = model.trialPermissionPane {
                                Button("Open Settings") {
                                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") {
                                        NSWorkspace.shared.open(url)
                                    }
                                }
                            }
                            Button("Review setup") { model.step = .setup }
                        }
                    }
                }
            } label: { Text("Check recognition") }
            GroupBox {
                VStack(alignment: .leading, spacing: 6) {
                    Toggle("Check for updates automatically", isOn: $model.wantsAutoUpdates)
                    Text("Asks aiity.de about once a day whether a newer version exists. The check sends no audio, no transcripts and no identifiers — but it is a network request, so it is off unless you want it. You can always check by hand from the menu bar.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            } label: {
                Label("Updates", systemImage: "arrow.triangle.2.circlepath")
            }
            Divider().padding(.vertical, 2)
            // Read the live binding rather than the default: it is user-editable,
            // and telling someone the wrong shortcut is worse than telling them none.
            // Two whole sentences rather than one built by concatenation: a
            // LocalizedStringKey interpolating \(shortcut) becomes the key
            // "…, or press %@." and stays translatable. Gluing the tail on at
            // runtime produced a String, which localizes to nothing at all.
            if model.useCase.includesCaptions,
               let shortcut = HotKeyCenter.shortcut(for: .toggleCaptions)?.displayString {
                bullet("captions.bubble",
                       "Start captions from the sAiity icon in the menu bar, or press \(shortcut).")
            } else if model.useCase.includesCaptions {
                bullet("captions.bubble", "Start captions from the sAiity icon in the menu bar.")
            }
            if model.useCase.includesDictation {
                let shortcut = model.state.dictationChord.displayString
                bullet("keyboard", "For everyday dictation, hold \(shortcut) while speaking, then release.")
            }
            bullet("slider.horizontal.3", "Change engine, language and appearance in Settings.")
            bullet("lock", "Nothing you caption is sent anywhere.")
            Spacer()
        }
        }
    }

    // MARK: - Chrome

    private var footer: some View {
        HStack {
            Text(model.step.title).font(.caption).foregroundStyle(.secondary)
            Spacer()
            if model.step != OnboardingStep.allCases.first {
                Button("Back") { back() }
                    .buttonStyle(.bordered)
            }
            Button(model.step == .finish ? "Done" : "Continue") { advance() }
                .buttonStyle(.glassProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(model.step == .permission && !model.permissionGranted)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(.regularMaterial)
    }

    /// `text` is a LocalizedStringKey, not a String, and that is the whole
    /// point: `Text(someString)` resolves to SwiftUI's VERBATIM overload, so a
    /// literal handed through a String parameter never becomes a localization
    /// key. These three bullets sat in the catalog fully translated and still
    /// rendered in English on a German system for exactly that reason.
    private func bullet(_ symbol: String, _ text: LocalizedStringKey) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol).frame(width: 20).foregroundStyle(.tint)
            Text(text)
            Spacer(minLength: 0)
        }
    }

    private func advance() {
        // A click that arrives right after the permission step advanced
        // itself was aimed at the step that just left — the primary button
        // does not move, so the user cannot have meant this one.
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

    func show(state: AppState) {
        if let w = window {
            ForegroundActivation.begin()
            w.makeKeyAndOrderFront(nil)
            return
        }
        let model = OnboardingModel(state: state)
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 600),
                         styleMask: [.titled, .closable],
                         backing: .buffered, defer: false)
        w.title = String(localized: "Set up sAiity")
        // Without this the material in the view above is inert: an opaque
        // window paints its solid backgroundColor over the blur before it is
        // ever composited. Settings needs the same call — the two windows have
        // to be told separately, which is precisely how this was missed here.
        w.makeVibrant()
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
        window = nil
    }
}
