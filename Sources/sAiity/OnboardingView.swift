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
            case .anyLanguage: return .nemotron
            case .englishOnly: return .parakeetEou
            }
        }
    }

    var purpose: Purpose = .anyLanguage
    var wantsAutoUpdates = false

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
                .transition(.push(from: model.goingBack ? .leading : .trailing))
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                .padding(.horizontal, 28)
                .animation(.smooth(duration: 0.28), value: model.step)
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
        return HStack(spacing: 6) {
            ForEach(Array(steps.enumerated()), id: \.element) { i, step in
                Capsule()
                    .fill(i <= current ? AnyShapeStyle(.tint) : AnyShapeStyle(.quaternary))
                    .frame(height: 4)
                    .animation(.smooth(duration: 0.3), value: model.step)
                    .accessibilityHidden(true)
            }
        }
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
                .font(.system(size: 38, weight: .regular))
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
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: granted ? "checkmark.circle.fill" : symbol)
                    .foregroundStyle(granted ? Color.green : Color.orange)
                Text(title).font(.body.weight(.medium))
                Spacer()
                Text(granted ? "Granted." : "Not granted yet.")
                    .foregroundStyle(.secondary)
            }
            if !granted {
                Text(explanation)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack {
                    Button("Allow…", action: request)
                        .buttonStyle(.borderedProminent)
                    Button("Open Settings", action: openSettings)
                }
            }
        }
        .padding(12)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
    }

    private var setup: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                header("sparkles",
                       "What for",
                       "Choose what you want to use. You can change this later in Settings.")

                ForEach(OnboardingModel.UseCase.allCases, id: \.self) { useCase in
                    choice(title: useCase.title,
                           detail: useCase.includesCaptions && useCase.includesDictation
                               ? String(localized: "One download and you are set")
                               : useCase.includesCaptions
                                   ? String(localized: "It captures the audio your Mac plays — the microphone stays off unless you later opt in under Settings → Captions.")
                                   : String(localized: "Dictation is separate from live captions. It never starts the caption service and is not saved as a meeting transcript."),
                           selected: model.useCase == useCase) {
                        model.useCase = useCase
                    }
                }

                Divider().padding(.vertical, 4)
                Text("Choose a recognition model")
                    .font(.headline)
                Text("Pick the language coverage you need. You can change it later in Settings.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                ForEach(OnboardingModel.Purpose.allCases, id: \.self) { p in
                    choice(title: p.title, detail: p.detail, selected: model.purpose == p) {
                        model.purpose = p
                    }
                }

                Divider().padding(.vertical, 4)
                ForEach(model.assetsToOffer) { asset in
                    let status = ModelRegistry.status(of: asset)
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(asset.title).font(.body.weight(.medium))
                            Text(asset.detail).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 12)
                        if status.isInstalled {
                            Label("Ready", systemImage: "checkmark.circle.fill")
                                .foregroundStyle(.green).font(.callout)
                        } else {
                            AssetControl(state: model.state, status: status, prominent: true)
                        }
                    }
                    .padding(10)
                    .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
                }
                if let e = model.state.modelError {
                    Text(e).font(.caption).foregroundStyle(.red)
                }
            }
        }
        .task { model.state.refreshModels() }
    }

    private var finish: some View {
        VStack(alignment: .leading, spacing: 14) {
            header("checkmark.seal",
                   "Ready",
                   "Everything is in place.")
            Toggle("Check for updates automatically", isOn: $model.wantsAutoUpdates)
            Text("Asks aiity.de about once a day whether a newer version exists. The check sends no audio, no transcripts and no identifiers — but it is a network request, so it is off unless you want it. You can always check by hand from the menu bar.")
                .font(.caption).foregroundStyle(.secondary)
            Divider().padding(.vertical, 2)
            // Read the live binding rather than the default: it is user-editable,
            // and telling someone the wrong shortcut is worse than telling them none.
            // Two whole sentences rather than one built by concatenation: a
            // LocalizedStringKey interpolating \(shortcut) becomes the key
            // "…, or press %@." and stays translatable. Gluing the tail on at
            // runtime produced a String, which localizes to nothing at all.
            if let shortcut = HotKeyCenter.shortcut(for: .toggleCaptions)?.displayString {
                bullet("captions.bubble",
                       "Start captions from the sAiity icon in the menu bar, or press \(shortcut).")
            } else {
                bullet("captions.bubble", "Start captions from the sAiity icon in the menu bar.")
            }
            bullet("slider.horizontal.3", "Change engine, language and appearance in Settings.")
            bullet("lock", "Nothing you caption is sent anywhere.")
            Spacer()
        }
    }

    // MARK: - Chrome

    private var footer: some View {
        HStack {
            Text(model.step.title).font(.caption).foregroundStyle(.secondary)
            Spacer()
            if model.step != OnboardingStep.allCases.first {
                Button("Back") { back() }
            }
            Button(model.step == .finish ? "Done" : "Continue") { advance() }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(model.step == .permission && !model.permissionGranted)
        }
        .padding(14)
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

    private func choice(title: String, detail: String, selected: Bool,
                        action: @escaping () -> Void) -> some View {
        // A Button rather than a tap gesture, so the wizard is operable by
        // keyboard and announced properly — first-run is exactly the moment a
        // VoiceOver user must not hit a dead end.
        Button(action: action) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(selected ? Color.accentColor : .secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.body.weight(.medium))
                    Text(detail).font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .padding(10)
            .background(selected ? AnyShapeStyle(.tint.opacity(0.12)) : AnyShapeStyle(.clear),
                        in: RoundedRectangle(cornerRadius: 8))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
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
        // Closing without finishing is a decision, not a completion.
        if Onboarding.needsRun { Onboarding.dismiss() }
        ForegroundActivation.end()
        window = nil
    }
}
