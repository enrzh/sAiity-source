import AppKit
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

    var body: some View {
        Form {
            Section("Recognition") {
                ForEach(assets(.recognition)) { assetRow($0) }
            }

            Section {
                ForEach(assets(.translation)) { assetRow($0) }
            } header: {
                Text("Translation")
            } footer: {
                Text("Only one translator runs at a time — pick it under Captions.")
                    .font(.caption)
            }

            Section {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Downloaded models: \(state.ownedTotal)")
                            .font(.callout)
                        if let stray = state.strayTotal {
                            Text("Other files: \(stray) — caches and leftovers from interrupted downloads.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    Button("Remove All…", role: .destructive) { confirmRemoveAll() }
                        .controlSize(.small)
                        .disabled(ModelRegistry.ownedTotalBytes() == 0)
                }
            } header: {
                Text("Storage")
            } footer: {
                Text("Everything runs on this Mac, so the models live here rather than on a server. Removing them all frees the space; anything you select again is downloaded once more.")
                    .font(.caption)
            }

            if let e = state.modelError {
                Section { Text(e).font(.caption).foregroundStyle(.red) }
            }
        }
        .scrollContentBackground(.hidden)
        .formStyle(.grouped)
        .task { state.refreshModels() }
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
            Text("Partial download — \(ModelRegistry.format(s.bytesOnDisk)), incomplete")
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

    /// Names the real figure before doing anything irreversible, and says up
    /// front what is NOT included — otherwise "remove all" that leaves several
    /// gigabytes of Apple assets behind reads as a bug.
    private func confirmRemoveAll() {
        let total = ModelRegistry.format(ModelRegistry.ownedTotalBytes())
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

struct DictationView: View {
    @Bindable var state: AppState

    private var accessibilityGranted: Bool { AXIsProcessTrusted() }

    var body: some View {
        Form {
            Section {
                Toggle("Press-to-talk dictation", isOn: $state.dictationEnabled)
                Text("Hold Control while speaking. Release it to transcribe on this Mac and paste the result into the app that currently has focus.")
                    .font(.caption).foregroundStyle(.secondary)
            } header: {
                Text("Dictation")
            }

            Section {
                LabeledContent("Gesture") {
                    Text("Hold Control")
                        .foregroundStyle(.secondary)
                }
                LabeledContent("Microphone") {
                    Text("Opened only while dictating")
                        .foregroundStyle(.secondary)
                }
                LabeledContent("Processing") {
                    Text("On this Mac")
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("Privacy")
            } footer: {
                Text("Dictation is separate from live captions. It never starts the caption service and is not saved as a meeting transcript.")
                    .font(.caption)
            }

            Section {
                if accessibilityGranted {
                    Label("Accessibility access is enabled", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.secondary)
                } else {
                    Label("Accessibility access is required to detect Control globally and paste into the focused app.",
                          systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(.orange)
                    Button("Open Accessibility Settings") {
                        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
                        NSWorkspace.shared.open(url)
                    }
                    .controlSize(.small)
                }
            } header: {
                Text("Permissions")
            }

            Section {
                HStack(spacing: 12) {
                    Image(systemName: "rectangle.and.pencil.and.ellipsis")
                        .font(.title2).foregroundStyle(.tint)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("A small toast confirms each step")
                            .font(.body.weight(.medium))
                        Text("Dictating, transcribing, and the final insertion result appear briefly above the bottom edge of the screen.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text("Feedback")
            }
        }
        .scrollContentBackground(.hidden)
        .formStyle(.grouped)
    }
}

/// Everything about producing a caption, on one page: which engine, what
/// language, how it looks, and how to toggle it. Previously this was spread
/// across four tabs, which made a simple app feel like a control panel.
struct CaptionsView: View {
    @Bindable var state: AppState

    var body: some View {
        Form {
            Section("Engine") {
                Picker("Recognition", selection: $state.engine) {
                    // Optional tags, so "nothing chosen" is a state the control
                    // can express. A segmented picker always paints one segment,
                    // which is how a fresh install came to claim an engine it had
                    // not downloaded; with a nil selection it paints none.
                    ForEach(ASREngine.allCases, id: \.self) {
                        Text($0.displayName).tag(Optional($0))
                    }
                }
                .pickerStyle(.segmented)
                if let engine = state.engine {
                    Text(engine.summary).font(.caption).foregroundStyle(.secondary)
                    // Stated here rather than left to be discovered, because a
                    // limited engine does not fail on the wrong language — it
                    // transcribes it into confident nonsense.
                    if case .only(let codes) = engine.coverage {
                        let names = codes.sorted()
                            .map { Locale.current.localizedString(forLanguageCode: $0) ?? $0 }
                        Label("Recognises \(names.joined(separator: ", ")) only. Other languages come out as nonsense rather than an error.",
                              systemImage: "exclamationmark.triangle")
                            .font(.caption).foregroundStyle(.orange)
                    }
                } else {
                    // Nothing chosen. Name the good option instead of quietly
                    // making the choice — a suggestion the user can act on.
                    Label("No recognition model chosen yet. \(ASREngine.recommended.displayName) is the one to start with: it handles any language and identifies it from the audio. Download it under Models.",
                          systemImage: "sparkles")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if state.engine == .nemotron {
                    Picker("Caption latency", selection: $state.nemotronTier) {
                        Text("Balanced").tag(2240)
                        Text("Fast").tag(1120)
                    }
                    .pickerStyle(.segmented)
                    Text(state.nemotronTier == 1120
                         ? "Captions roughly twice as often, for about double the recognition work per second of audio — noticeable on battery."
                         : "The default. Captions arrive about every 2 seconds at the lowest recognition cost.")
                        .font(.caption).foregroundStyle(.secondary)
                    if !NemotronEngine.isDownloaded(chunkMs: state.nemotronTier) {
                        Label("This tier is its own ~640 MB download — each latency has the chunk size baked into its model. Fetch it under Models.",
                              systemImage: "arrow.down.circle")
                            .font(.caption).foregroundStyle(.orange)
                    }
                }
                if state.engine?.needsDownload == true {
                    Label("Not downloaded yet — see Models.", systemImage: "arrow.down.circle")
                        .font(.caption).foregroundStyle(.orange)
                }
            }

            Section {
                Picker("Capture audio from", selection: $state.captureApp) {
                    Text("Everything the Mac plays").tag(String?.none)
                    ForEach(state.runningApps, id: \.bundleID) { app in
                        Text(app.name).tag(Optional(app.bundleID))
                    }
                }
                LabeledToggle("Include my microphone",
                              "Off by default. System audio on a call carries only the other participants — your own voice never enters the mix, so a saved transcript is missing your half of the conversation. On, sAiity also opens the microphone (macOS asks once) and mixes it into recognition. Audio still never leaves this Mac. Takes effect immediately, including mid-session: switching it off releases the microphone straight away.",
                              isOn: $state.includeMic)
            } header: {
                Text("Capture")
            } footer: {
                // A footer, not a caption row: the explanation describes the
                // whole section, and the footer is where the OS's own settings
                // put exactly this kind of text.
                Text(state.captureApp == nil
                     ? "The whole system mix — notification sounds and every other app land in the captions too. Scope to one app to caption a meeting or a film without interference."
                     : "Only this app's audio reaches the captions; notification sounds, other videos and games stay out. Takes effect when captions next start, and Start will say so if the app is not running.")
                    .font(.caption)
            }

            Section {
                LabeledToggle("End a sentence on a pause",
                              "Most of what the multilingual engine emits carries no punctuation, so a pause is what tells the app a thought has finished — and a finished sentence is what gets translated. Off, sentences close only on real punctuation and on the length cap, which suits a speaker who pauses mid-thought.",
                              isOn: $state.speechGapEnabled)
                if state.speechGapEnabled {
                    slider("Pause length", $state.speechGapHoldMs,
                           Double(SpeechGap.range.lowerBound)...Double(SpeechGap.range.upperBound),
                           "%.0f ms")
                    Text("Clause pauses in ordinary speech run 200–500 ms and the pause at the end of a sentence is longer, so \(SpeechGap.defaultHoldMs) ms is the measured default. Shorter splits sentences at commas and hands the translator fragments; longer delays every translation and eventually lets the length cap cut one mid-word.")
                        .font(.caption).foregroundStyle(.secondary)
                    // The slider applies live to the running session; this is
                    // the feedback loop it never had. Tuning used to mean
                    // dragging blind and watching captions for a minute.
                    if let r = state.gapReadout {
                        Label("Live: quietest \(Int(r.floorDb)) dBFS in the last 5 s · pause threshold \(Int(r.thresholdDb)) dBFS",
                              systemImage: r.fires > 0 ? "checkmark.circle" : "waveform")
                            .font(.caption).foregroundStyle(.secondary)
                        if r.fires > 0 {
                            Text("\(r.fires) sentences ended on a pause this session.")
                                .font(.caption).foregroundStyle(.secondary)
                        } else if r.floorDb > r.thresholdDb {
                            Label("This audio has not dropped below the threshold yet — sentences will close on the length cap instead. A longer pause length will not help; scoping capture to one app might.",
                                  systemImage: "exclamationmark.triangle")
                                .font(.caption).foregroundStyle(.orange)
                        }
                    }
                }
            } header: {
                HStack {
                    Text("Sentences")
                    Spacer()
                    ResetButton {
                        state.speechGapEnabled = true
                        state.speechGapHoldMs = Double(SpeechGap.defaultHoldMs)
                    }
                }
            }

            Section("Translation") {
                LabeledContent("Translate to") {
                    Button {
                        state.showTranslationPicker = true
                    } label: {
                        HStack(spacing: 4) {
                            Text(state.translateTo.map { AppLanguage(code: $0).displayName }
                                 ?? String(localized: "Off"))
                            Image(systemName: "chevron.up.chevron.down")
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                }
                if state.translateTo != nil {
                    Picker("Translated by", selection: $state.translationEngine) {
                        ForEach(TranslationEngine.allCases, id: \.self) { e in
                            Text(e.displayName).tag(Optional(e))
                        }
                    }
                    .pickerStyle(.segmented)
                    if let te = state.translationEngine {
                        Text(te.summary).font(.caption).foregroundStyle(.secondary)
                    } else {
                        Label("No translator chosen yet. \(TranslationEngine.recommended.displayName) is the one to start with: fastest of the two, and it only ever translates. Download it under Models.",
                              systemImage: "sparkles")
                            .font(.caption).foregroundStyle(.secondary)
                    }

                    // Any engine can be asked for a language it cannot do, not
                    // just Whisper — and a stored target survives an engine
                    // change, so this has to be checked rather than assumed.
                    if let t = state.translateTo, !state.targetSupportedByEngine {
                        TargetUnsupportedNotice(state: state, target: t)
                    }
                    if state.translationEngine == .qwen {
                        HStack {
                            Button("Choose model…") { state.showLocalModels = true }
                                .controlSize(.small)
                            if let m = state.llmModel {
                                // Say whether the bytes are here. The advertised
                                // size alone read as "installed and this big".
                                Text(m.isDownloaded
                                     ? "\(m.label) · \(m.sizeText)"
                                     : "\(m.label) · \(m.sizeText) — not downloaded yet")
                                    .font(.caption)
                                    .foregroundStyle(m.isDownloaded ? .secondary : Color.orange)
                            } else if let s = LocalModel.suggested {
                                Text("No model chosen — \(s.label) is the one to start with")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    Picker("Translation mode", selection: $state.translationTiming) {
                        ForEach(TranslationTiming.allCases, id: \.self) { t in
                            Text(t.displayName).tag(t)
                        }
                    }
                    .pickerStyle(.segmented)
                    Text(state.translationTiming == .live
                         ? "Retranslates the sentence as it grows, so a rough translation appears within a couple of seconds and settles when the sentence closes. Noticeably more translator work — with a local LLM every update takes a second or more, so this suits MADLAD."
                         : "One translation per sentence, when the pause or the punctuation closes it. Best quality for the least work — the translator always sees the whole thought.")
                        .font(.caption).foregroundStyle(.secondary)
                    if let te = state.translationEngine {
                        Text("Licence: \(te.licence)")
                            .font(.caption2).foregroundStyle(.tertiary)
                    }
                }
            }

            appearanceSections

            Section("Shortcuts") {
                ForEach(HotKeyCenter.Action.allCases, id: \.self) { action in
                    HStack {
                        Text(action.title)
                        Spacer()
                        ShortcutRecorder(action: action, state: state)
                    }
                }
                Text("System-wide. Click a field and press the combination; ⌫ clears. Needs ⌃, ⌥ or ⌘.")
                    .font(.caption).foregroundStyle(.secondary)
                if let e = state.shortcutError {
                    Text(e).font(.caption).foregroundStyle(.orange)
                }
            }
        }
        .scrollContentBackground(.hidden)
        .formStyle(.grouped)
        .task(id: "\(state.translateTo ?? "")|\(state.translationEngine?.rawValue ?? "none")") {
            await state.refreshTargetSupport()
        }
        .sheet(isPresented: $state.showLocalModels) { LocalModelsView(state: state) }
        .sheet(isPresented: $state.showTranslationPicker) { TranslationTargetPicker(state: state) }
    }

    @ViewBuilder
    private var appearanceSections: some View {
        Section {
            LabeledToggle("Show the caption bubble",
                          "Hides the subtitles without stopping recognition, so you can keep a transcript running with nothing on screen.",
                          isOn: Binding(get: { !state.style.hidden },
                                        set: { state.style.hidden = !$0 }))
            LabeledToggle("Let clicks pass through the bubble",
                          "On, only the bubble's top strip can be grabbed and everything else clicks straight through to the video underneath — which matters, because the bubble sits over the scrubber. Off, you can drag it by any part of it.",
                          isOn: $state.captionClickThrough)
            LabeledToggle("Announce captions to VoiceOver",
                          "Off by default. Each finished sentence is posted as a VoiceOver announcement, which also reaches a connected braille display. In-progress text is never announced — it would arrive faster than speech or braille can render it.",
                          isOn: $state.announceCaptions)
            Picker("Background", selection: $state.style.glassStyle) {
                Text("Glass").tag(0); Text("Clear").tag(1); Text("Solid").tag(2)
            }
            .pickerStyle(.segmented)
            Text("Solid is the readable choice over bright video — glass leaves white text on a white scene at roughly 2:1 contrast.")
                .font(.caption).foregroundStyle(.secondary)
            ColorPicker("Background tint", selection: Binding(
                get: { Color(nsColor: state.style.tintColor ?? .black) },
                set: { state.style.tintHex = CaptionStyle.hex(from: NSColor($0)) }))
            slider("Corner radius", $state.style.cornerRadius, 0...40, "%.0f")
            slider("Width", $state.style.widthFraction, 0.3...1.0, "%.0f%%", scale: 100)
            slider("Gap to screen edge", $state.style.screenMargin, 0...160, "%.0f")
            Text("Width is a setting rather than something measured from the text — that is what stops the bubble resizing and re-centring on every line. Drag an edge to override it; a dragged width may go right to the screen edge.")
                .font(.caption).foregroundStyle(.secondary)
        } header: {
            HStack {
                Text("Bubble")
                Spacer()
                ResetButton {
                    let d = CaptionStyle()
                    state.style.glassStyle = d.glassStyle
                    state.style.tintHex = d.tintHex
                    state.style.cornerRadius = d.cornerRadius
                    state.style.widthFraction = d.widthFraction
                    state.style.screenMargin = d.screenMargin
                    state.style.hidden = d.hidden
                    state.captionClickThrough = true
                    NotificationCenter.default.post(name: .saiityResetBubble, object: nil)
                }
            }
        }

        textStyleSection("Original text", $state.style.original,
                         note: "The recognised speech. It is dimmed while the engine may still revise it — that is the second opacity below.",
                         volatile: true,
                         reset: { state.style.original = .original })

        Section {
            LabeledToggle("Show the translation line",
                          "The second line under each caption. Turning this off keeps translation running for the transcript but hides it on screen.",
                          isOn: $state.style.showTranslation)
        } header: {
            HStack {
                Text("Translated text")
                Spacer()
                ResetButton {
                    state.style.translation = .translation
                    state.style.showTranslation = true
                }
            }
        }
        textStyleControls($state.style.translation, volatile: false)
        Section {
            slider("Gap between the lines", $state.style.lineGap, 0...24, "%.0f")
            HStack {
                Button("Preview") {
                    NotificationCenter.default.post(name: .saiityCaptionPreview, object: nil)
                }
                Button("Reset position") {
                    NotificationCenter.default.post(name: .saiityResetBubble, object: nil)
                }
                ResetButton("Reset everything") { state.style = CaptionStyle() }
            }
            .controlSize(.small)
            Text("Changes apply live. Preview puts sample text in the real bubble.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    /// One group of text controls, used for both roles so they cannot drift.
    @ViewBuilder
    private func textStyleSection(_ title: LocalizedStringKey, _ style: Binding<TextStyle>,
                                  note: LocalizedStringKey, volatile: Bool,
                                  reset: @escaping () -> Void) -> some View {
        Section {
            textStyleControls(style, volatile: volatile)
        } header: {
            HStack {
                Text(title)
                Spacer()
                ResetButton(action: reset)
            }
        } footer: {
            Text(note).font(.caption)
        }
    }

    @ViewBuilder
    private func textStyleControls(_ style: Binding<TextStyle>, volatile: Bool) -> some View {
        slider("Size", style.fontSize, 12...72, "%.0f")
        Picker("Weight", selection: style.weight) {
            Text("Light").tag(-0.4); Text("Regular").tag(0.0)
            Text("Medium").tag(0.23); Text("Semibold").tag(0.3); Text("Bold").tag(0.4)
        }
        .pickerStyle(.segmented)
        ColorPicker("Colour", selection: Binding(
            get: { Color(nsColor: style.wrappedValue.color) },
            set: { style.colorHex.wrappedValue = CaptionStyle.hex(from: NSColor($0)) }))
        slider("Opacity", style.opacity, 0.2...1.0, "%.0f%%", scale: 100)
        if volatile {
            slider("Opacity while still being revised", style.volatileOpacity, 0.2...1.0,
                   "%.0f%%", scale: 100)
        }
        Stepper("Maximum lines: \(style.wrappedValue.maxLines)", value: style.maxLines, in: 1...8)
    }

    /// Sliders here are always label + track + read-out; writing that out five
    /// times invites them to drift apart.
    @ViewBuilder
    private func slider(_ title: LocalizedStringKey, _ value: Binding<Double>,
                        _ range: ClosedRange<Double>, _ format: String,
                        scale: Double = 1) -> some View {
        LabeledContent(title) {
            HStack {
                Slider(value: value, in: range)
                Text(String(format: format, value.wrappedValue * scale))
                    // 44 was sized for "22" and "62%"; "750 ms" wrapped onto two
                    // lines. Right-aligned, so the extra width costs the slider
                    // a few points and nothing else.
                    .monospacedDigit().fixedSize()
                    .frame(width: 62, alignment: .trailing)
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
        Button(title, action: action)
            .controlSize(.small)
            .help("Put this section back to its defaults.")
    }
}

/// A toggle with the explanation directly under it.
///
/// Every switch in this app now carries one: a bare label leaves the user to
/// guess what turning it off costs, and several of these have real consequences
/// (a durable transcript, clicks reaching the video behind).
struct LabeledToggle: View {
    // Both are LocalizedStringKey. As String they would reach Text's verbatim
    // overload, which is how every one of these explanations stayed English
    // in the German build while the surrounding section was translated.
    let title: LocalizedStringKey
    let note: LocalizedStringKey
    @Binding var isOn: Bool

    init(_ title: LocalizedStringKey, _ note: LocalizedStringKey, isOn: Binding<Bool>) {
        self.title = title
        self.note = note
        self._isOn = isOn
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Toggle(title, isOn: $isOn)
            Text(note).font(.caption).foregroundStyle(.secondary)
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
            HotKeyCenter.shared.rebind(action)
            state.shortcutError = (s != nil && HotKeyCenter.shortcut(for: action) == nil)
                ? String(localized: "That combination is already taken by another app.") : nil
            ()
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
                heightAnchor.constraint(equalToConstant: 24),
            ])
            wantsLayer = true
            layer?.cornerRadius = 6
            refresh()
        }
        required init?(coder: NSCoder) { fatalError() }

        func refresh() {
            if recording {
                label.stringValue = String(localized: "Press keys…")
                layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.25).cgColor
            } else if let s = HotKeyCenter.shortcut(for: action) {
                label.stringValue = s.displayString
                layer?.backgroundColor = NSColor.quaternaryLabelColor.cgColor
            } else {
                label.stringValue = String(localized: "Not set")
                layer?.backgroundColor = NSColor.quaternaryLabelColor.cgColor
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
    /// The session open in the transcript viewer sheet.
    @State private var viewing: SessionRef?
    @State private var retentionDays = TranscriptRetention.days
    @State private var retranslator = Retranslator()
    @State private var retranslateProgress: Retranslator.Progress?
    @State private var retranslateNote: String?
    @State private var retranslating: SessionRef?

    var body: some View {
        Form {
            Section {
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
                    Task { await state.refresh() }
                }
            } header: {
                Text("Recording")
            } footer: {
                Text("Off by default. A transcript is a durable record of a conversation other people were part of, and system audio captures everyone on the call. Nothing is ever deleted unless you choose an age above.")
                    .font(.caption)
            }

            Section("Saved sessions") {
                if state.sessions.isEmpty {
                    ContentUnavailableView(
                        "Nothing saved yet",
                        systemImage: "text.document",
                        description: Text("Turn on “Save transcripts of sessions” and every captioned session appears here."))
                } else {
                    TextField("Search all transcripts", text: $query)
                        .textFieldStyle(.roundedBorder)
                }
                if !state.sessions.isEmpty, !trimmedQuery.isEmpty {
                    let found = hits
                    if found.isEmpty {
                        // The framework's own empty state, which localizes and
                        // themes itself.
                        ContentUnavailableView.search(text: query)
                    }
                    ForEach(found) { hit in
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
                            } label: { Image(systemName: "folder") }.controlSize(.small)
                            Button(role: .destructive) {
                                TranscriptStore.delete(s)
                                    SessionCatalog.invalidate()
                                    Task { await state.refresh() }
                            } label: { Image(systemName: "trash") }.controlSize(.small)
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
                        Text("Writes every saved session into one folder.")
                            .font(.caption).foregroundStyle(.secondary)
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
                            Task { await state.refresh() }
                        }
                    }
                    .controlSize(.small)
                }
            }

        }
        .scrollContentBackground(.hidden)
        .formStyle(.grouped)
        .sheet(item: $viewing) { TranscriptViewerSheet(session: $0) }
    }

    private var trimmedQuery: String {
        query.trimmingCharacters(in: .whitespaces)
    }

    private struct SearchHit: Identifiable {
        let id: String
        let session: SessionRef
        let seg: Segment
    }

    /// Every line in every saved session matching the query, original or
    /// translation. Read fresh per keystroke — sessions are local JSONL files
    /// and the working set is a person's own meetings, not a corpus.
    private var hits: [SearchHit] {
        let q = trimmedQuery
        guard !q.isEmpty else { return [] }
        var out: [SearchHit] = []
        for s in state.sessions {
            for seg in TranscriptStore.segments(of: s)
            where seg.text.localizedCaseInsensitiveContains(q)
                || (seg.tr?.localizedCaseInsensitiveContains(q) ?? false) {
                out.append(SearchHit(id: "\(s.id)#\(seg.i)", session: s, seg: seg))
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
                Task { await state.refresh() }
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

    var body: some View {
        Form {
            Section {
                LabeledContent("Engine", value: state.engine?.displayName ?? String(localized: "None chosen"))
                LabeledContent("Screen Recording",
                               value: CGPreflightScreenCaptureAccess()
                                   ? String(localized: "Granted")
                                   : String(localized: "Not granted"))
            } header: {
                Text("Status")
            } footer: {
                Text("System-audio capture is gated behind Screen Recording — macOS has no audio-only permission.")
                    .font(.caption)
            }

            Section("Startup") {
                LabeledToggle("Start sAiity when you log in",
                              "Registers the app as a login item so captions are one keypress away after a restart. Off by default — this app can capture system audio, so being running should be your choice.",
                              isOn: Binding(get: { state.launchAtLogin },
                                            set: { state.setLaunchAtLogin($0) }))
                if !state.launchAtLoginNote.isEmpty {
                    Text(state.launchAtLoginNote).font(.caption).foregroundStyle(.orange)
                }
            }

            Section("Troubleshooting") {
                HStack {
                    Button("Run setup again…") {
                        Onboarding.reset()
                        OnboardingWindowController.shared.show(state: state)
                    }
                    .controlSize(.small)
                    Text("Walks through permission and models from the start.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                HStack {
                    Button("Save diagnostics…") { Diagnostics.save() }
                        .controlSize(.small)
                    Text("Writes one text file with the app's state and this run's log, for bug reports. Review it before sharing.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                // Moved off the menu bar, which had grown into a second copy
                // of the app. It still has to live somewhere: this panel is
                // where the third-party licences and credits are shown.
                HStack {
                    Button("About sAiity") {
                        NotificationCenter.default.post(name: .saiityShowAbout, object: nil)
                    }
                    .controlSize(.small)
                    Text("Version, licence, and the credits for the models and libraries this app is built on.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            Section("Privacy") {
                Text("Audio never leaves this Mac. Recognition, translation and transcripts are all processed and stored locally — no account, no API key.")
                    .font(.caption)
                Text("Model files are downloaded once from huggingface.co. Nothing you say is ever uploaded.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .scrollContentBackground(.hidden)
        .formStyle(.grouped)
        .task { await state.refresh() }
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
                   width: 560, height: 480,
                   headerAccessory: {
                       TextField("Search", text: $query)
                           .textFieldStyle(.roundedBorder)
                           .frame(width: 160)
                   }) {
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
            .task { segments = TranscriptStore.segments(of: session) }
        }
    }
}

// MARK: - Translation languages



// MARK: - Qwen models

/// Pick which Qwen build does the translating.
///
/// The 0.8B is deliberately shown with a warning rather than hidden: it is the
/// fastest option and people will reach for it, but a sub-billion instruct model
/// invents and drops meaning badly enough that a wrong translation is worse than
/// none. Saying so is more useful than quietly omitting it.
struct LocalModelsView: View {
    @Bindable var state: AppState
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        SheetShell(title: "Local LLM models",
                   subtitle: "Qwen, Gemma, or your own GGUF · one is used at a time",
                   width: 520, height: 560) {
            List {
                ForEach(LocalModel.all) { m in
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
                                state.refreshModels()
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
                state.refreshModels()
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
                state.refreshModels()
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
