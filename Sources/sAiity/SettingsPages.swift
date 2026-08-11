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
                LabeledToggle("End a sentence on a pause",
                              "Most of what the multilingual engine emits carries no punctuation, so a pause is what tells the app a thought has finished — and a finished sentence is what gets translated. Off, sentences close only on real punctuation and on the length cap, which suits a speaker who pauses mid-thought.",
                              isOn: $state.speechGapEnabled)
                if state.speechGapEnabled {
                    slider("Pause length", $state.speechGapHoldMs,
                           Double(SpeechGap.range.lowerBound)...Double(SpeechGap.range.upperBound),
                           "%.0f ms")
                    Text("Clause pauses in ordinary speech run 200–500 ms and the pause at the end of a sentence is longer, so \(SpeechGap.defaultHoldMs) ms is the measured default. Shorter splits sentences at commas and hands the translator fragments; longer delays every translation and eventually lets the length cap cut one mid-word.")
                        .font(.caption).foregroundStyle(.secondary)
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
            recording = true
            window?.makeFirstResponder(self)
            refresh()
        }

        override func keyDown(with event: NSEvent) {
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

// MARK: - Library

/// Transcripts, recording, and the honest status of the app in one place.
/// Previously "Transcripts" and "Status" were separate tabs; they are the same
/// subject — what this app has stored and what it can see.
struct LibraryView: View {
    @Bindable var state: AppState

    var body: some View {
        Form {
            Section("Recording") {
                Toggle("Save transcripts of sessions", isOn: $state.saveTranscript)
                Text("Off by default. A transcript is a durable record of a conversation other people were part of, and system audio captures everyone on the call.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Saved sessions") {
                if state.sessions.isEmpty {
                    Text("Nothing saved yet.").foregroundStyle(.secondary)
                } else {
                    ForEach(state.sessions, id: \.id) { s in
                        HStack {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(s.meta.startedAt.formatted(date: .abbreviated, time: .shortened))
                                Text("\(s.meta.lineCount) lines · \(s.meta.locale)")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("SRT") { export(s, "srt") }.controlSize(.small)
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

            Section("Status") {
                LabeledContent("Engine", value: state.engine?.displayName ?? String(localized: "None chosen"))
                LabeledContent("Screen Recording",
                               value: CGPreflightScreenCaptureAccess()
                                   ? String(localized: "Granted")
                                   : String(localized: "Not granted"))
                Text("System-audio capture is gated behind Screen Recording — macOS has no audio-only permission.")
                    .font(.caption).foregroundStyle(.secondary)
                LabeledToggle("Start sAiity when you log in",
                              "Registers the app as a login item so captions are one keypress away after a restart. Off by default — this app can capture system audio, so being running should be your choice.",
                              isOn: Binding(get: { state.launchAtLogin },
                                            set: { state.setLaunchAtLogin($0) }))
                if !state.launchAtLoginNote.isEmpty {
                    Text(state.launchAtLoginNote).font(.caption).foregroundStyle(.orange)
                }
                HStack {
                    Button("Run setup again…") {
                        Onboarding.reset()
                        OnboardingWindowController.shared.show(state: state)
                    }
                    .controlSize(.small)
                    Text("Walks through permission and models from the start.")
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
    }

    private func export(_ s: SessionRef, _ kind: String) {
        let segs = TranscriptStore.segments(of: s)
        let text = kind == "srt" ? Export.srt(segs) : Export.markdown(segs, meta: s.meta)
        if let url = Export.write(text, named: "transcript.\(kind)", in: s.url) {
            NSWorkspace.shared.activateFileViewerSelecting([url])
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
