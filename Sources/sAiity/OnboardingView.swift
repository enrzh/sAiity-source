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
    var step: OnboardingStep = .welcome
    var permissionGranted = false
    var checkingPermission = false
    var askedOnce = false

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
    var wantsTranslation = false
    var wantsAutoUpdates = false
    var target = "en"

    let state: AppState
    init(state: AppState) {
        self.state = state
        if let resume = Onboarding.resumeStep {
            step = resume
            Onboarding.resumeStep = nil
        }
    }

    func refreshPermission() async {
        checkingPermission = true
        permissionGranted = await ScreenRecordingPermission.probe()
        checkingPermission = false
    }

    /// Write the choices through the same paths Settings uses, so nothing here
    /// is a special case that can drift.
    func apply() {
        ASREngine.selected = purpose.engine
        state.engine = purpose.engine
        if wantsTranslation {
            state.translateTo = target
            // The wizard names MADLAD and offers its download, so it is also the
            // thing that should record the choice — otherwise the user finishes
            // setup with a translation target and no translator selected.
            state.translationEngine = .recommended
        } else {
            state.translateTo = nil
        }
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

    /// Everything this run should offer to download, in the order it is offered.
    ///
    /// The purpose step promises, in so many words, that the translation model
    /// is "listed on the next screen alongside the recognition model" — and it
    /// was not. The 1.86 GB then arrived mid-session on the first Start, after
    /// the recognition download, with audio capture already live.
    var assetsToOffer: [ModelAsset] {
        var out = [recognitionAsset]
        if wantsTranslation {
            out += TranslationEngine.recommended.assetDescriptors
        }
        return out
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
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                .padding(.horizontal, 28)
                .animation(.smooth(duration: 0.28), value: model.step)
            Divider()
            footer
        }
        .frame(width: 640, height: 560)
        .background(setupBackground)
    }

    /// Depth without cost. This window is redrawn on interaction, not per frame
    /// like the caption bubble, so a gradient and a material here are free —
    /// the same treatment in the bubble would be paid several times a second
    /// while a speech model and a translator are already running.
    /// Shared with Settings — see SettingsBackground. One window looking like a
    /// different app from the next is how a small app reads as unfinished.
    private var setupBackground: some View { SettingsBackground() }

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
        case .welcome: welcome
        case .permission: permission
        case .purpose: purpose
        case .models: models
        case .finish: finish
        }
    }

    // MARK: - Steps

    private var welcome: some View {
        VStack(spacing: 18) {
            // The real app icon, not a glyph: this is the first thing a new
            // user sees, and it should look like the thing they installed.
            Image(nsImage: NSApp.applicationIconImage)
                .resizable().frame(width: 96, height: 96)
                .shadow(color: .black.opacity(0.28), radius: 12, y: 5)
            VStack(spacing: 6) {
                Text("sAiity").font(.system(size: 36, weight: .semibold))
                Text("Live subtitles for anything your Mac is playing.")
                    .font(.title3).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            VStack(alignment: .leading, spacing: 12) {
                bullet("microphone.slash", "It captures the audio your Mac plays, not your microphone.")
                bullet("lock", "Everything runs on this Mac. No audio ever leaves it.")
                bullet("arrow.down.circle", "That means a one-time model download — you choose which.")
            }
            .padding(18)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14)
                        .strokeBorder(.white.opacity(0.07), lineWidth: 1))
            .padding(.top, 4)
        }
    }

    private var permission: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Allow Screen Recording").font(.title2.weight(.semibold))
            Text("macOS has no separate permission for system audio — Screen Recording is the one that gates it. sAiity records no video and takes no screenshots.")
                .foregroundStyle(.secondary)

            HStack(spacing: 8) {
                Image(systemName: model.permissionGranted
                      ? "checkmark.circle.fill" : "exclamationmark.circle")
                    .foregroundStyle(model.permissionGranted ? Color.green : Color.orange)
                Text(model.permissionGranted ? "Granted." : "Not granted yet.")
                if model.checkingPermission { ProgressView().controlSize(.small) }
            }
            .padding(.top, 4)

            if !model.permissionGranted {
                HStack {
                    Button("Allow…") {
                        // Effective only on the very first ask; after that macOS
                        // ignores it, which is why Open Settings sits next to it.
                        ScreenRecordingPermission.request()
                        model.askedOnce = true
                        Task { await model.refreshPermission() }
                    }
                    .buttonStyle(.borderedProminent)
                    Button("Open Settings") { ScreenRecordingPermission.openSettings() }
                }
                if model.askedOnce, ScreenRecordingPermission.canRelaunch {
                    Text("Already allowed it in System Settings but still showing as not granted? macOS sometimes only applies it to a fresh launch.")
                        .font(.caption).foregroundStyle(.secondary).padding(.top, 6)
                    Button("Quit & Reopen") { ScreenRecordingPermission.relaunch() }
                        .controlSize(.small)
                }
            }
            Spacer()
        }
        .task { await model.refreshPermission() }
        // Coming back from System Settings is the strongest signal there is that
        // something changed — better than polling alone.
        .onReceive(NotificationCenter.default.publisher(
            for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await model.refreshPermission() }
        }
    }

    private var purpose: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("What will you caption?").font(.title2.weight(.semibold))
            Text("This only picks a starting model. You can change it any time in Settings.")
                .foregroundStyle(.secondary)

            ForEach(OnboardingModel.Purpose.allCases, id: \.self) { p in
                choice(title: p.title, detail: p.detail, selected: model.purpose == p) {
                    model.purpose = p
                }
            }

            Divider().padding(.vertical, 4)
            Toggle("Also show a translation under each caption", isOn: $model.wantsTranslation)
            // Unconditional: with the description only visible when the toggle
            // was on, the OFF state gave no hint of what saying yes would cost.
            Text("A second line under the captions, in a language you choose. Runs on this Mac like everything else.")
                .font(.caption).foregroundStyle(.secondary)
            if model.wantsTranslation {
                // Say the cost before they commit. Translation used to lean on
                // macOS's built-in translator, which needed nothing from us;
                // now every option is a model we download, so an unqualified
                // "yes" here would be a 1.86 GB surprise on the next screen.
                Text("Translation runs on this Mac too, so it needs a model of its own — MADLAD, 1.86 GB, covering about 450 languages. It is listed on the next screen alongside the recognition model.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
        }
    }

    private var models: some View {
        VStack(alignment: .leading, spacing: 14) {
            // At most two: the recognition model, plus MADLAD when translation
            // was asked for. Saying "one" while showing two was the small
            // version of the same dishonesty as promising a row and not
            // rendering it.
            Text(model.assetsToOffer.count > 1
                 ? "Two downloads and you are set"
                 : "One download and you are set")
                .font(.title2.weight(.semibold))
            Text("Recognition always needs a model on this Mac — that is the price of not sending your audio to a server.")
                .foregroundStyle(.secondary)

            ForEach(model.assetsToOffer) { asset in
                let status = ModelRegistry.status(of: asset)
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(asset.title).font(.body.weight(.medium))
                        Text(asset.detail).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 12)
                    if status.isInstalled {
                        // Onboarding says Ready rather than offering Delete — the
                        // one place the shared control's installed state is wrong.
                        Label("Ready", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green).font(.callout)
                    } else {
                        AssetControl(state: model.state, status: status, prominent: true)
                    }
                }
                .padding(12)
                .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
            }

            if let e = model.state.modelError {
                Text(e).font(.caption).foregroundStyle(.red)
            }
            Text("You can skip this and let it download the first time you start captions — it just means waiting then instead of now.")
                .font(.caption).foregroundStyle(.secondary)
            Spacer()
        }
        .task { model.state.refreshModels() }
    }

    private var finish: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Ready").font(.title2.weight(.semibold))
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
            if model.step != .welcome {
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
        let steps = OnboardingStep.allCases
        guard let i = steps.firstIndex(of: model.step) else { return }
        if model.step == .purpose { model.apply() }
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
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 560),
                         styleMask: [.titled, .closable],
                         backing: .buffered, defer: false)
        w.title = String(localized: "Set up sAiity")
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
