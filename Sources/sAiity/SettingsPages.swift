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

    private func assets(_ family: ModelAsset.Family) -> [AssetStatus] {
        state.assets.filter { $0.asset.family == family }
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
                ForEach(assets(.system)) { assetRow($0) }
                HStack {
                    Text("Apple speech languages").font(.callout)
                    Spacer()
                    Button("Languages…") { state.showAppleLanguages = true }
                        .controlSize(.small)
                }
            } header: {
                Text("Managed by macOS")
            } footer: {
                Text("macOS installs and removes these. No app can delete them, "
                     + "so they are listed here for size only.")
                    .font(.caption)
            }

            Section {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Downloaded models: \(state.ownedTotal)")
                            .font(.callout)
                        if let stray = state.strayTotal {
                            Text("Other files: \(stray) — caches and leftovers from "
                                 + "interrupted downloads.")
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
                Text("Everything runs on this Mac, so the models live here rather than "
                     + "on a server. Removing them all frees the space; anything you "
                     + "select again is downloaded once more.")
                    .font(.caption)
            }

            if let e = state.modelError {
                Section { Text(e).font(.caption).foregroundStyle(.red) }
            }
        }
        .formStyle(.grouped)
        .task { state.refreshModels() }
        .sheet(isPresented: $state.showAppleLanguages) {
            AppleSpeechLanguagesView(state: state)
        }
    }

    @ViewBuilder
    private func assetRow(_ s: AssetStatus) -> some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(s.asset.title).font(.body.weight(.medium))
                    if s.asset.use.isSelected {
                        Text("in use").font(.caption2)
                            .padding(.horizontal, 6).padding(.vertical, 1)
                            .background(.tint.opacity(0.2), in: Capsule())
                    }
                }
                Text(s.asset.detail).font(.caption).foregroundStyle(.secondary)
                sizeLine(s)
            }
            Spacer(minLength: 12)
            trailingControl(s)
        }
        .padding(.vertical, 3)
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

    /// Progress → Remove (partial) → Delete (installed) → Download. Assets macOS
    /// owns get an explanation and a route instead of a button that would lie.
    @ViewBuilder
    private func trailingControl(_ s: AssetStatus) -> some View {
        if case .systemOnly(_, let route) = s.asset.removal {
            Button(route.label) { route.open() }
                .controlSize(.small)
        } else if state.activeDownload == s.asset.id {
            VStack(alignment: .trailing, spacing: 2) {
                if let f = state.downloadProgress?.fraction {
                    ProgressView(value: f).frame(width: 100)
                    Text("\(Int(f * 100))%").font(.caption2).foregroundStyle(.secondary)
                } else {
                    ProgressView().controlSize(.small)
                }
            }
        } else if s.isInstalled || s.isPartial {
            Button(s.isPartial ? "Remove" : "Delete", role: .destructive) {
                Task { await state.delete(s.asset) }
            }
            .controlSize(.small)
        } else if s.asset.install != nil {
            Button("Download") { Task { await state.download(s.asset) } }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(state.activeDownload != nil)
        }
    }

    /// Names the real figure before doing anything irreversible, and says up
    /// front what is NOT included — otherwise "remove all" that leaves several
    /// gigabytes of Apple assets behind reads as a bug.
    private func confirmRemoveAll() {
        let total = ModelRegistry.format(ModelRegistry.ownedTotalBytes())
        let a = NSAlert()
        a.messageText = "Remove all downloaded models?"
        a.informativeText = "This frees \(total). Apple's speech and translation "
            + "languages are not included — macOS manages those and no app can "
            + "delete them.\n\nAnything you use again will be downloaded once more."
        a.alertStyle = .warning
        a.addButton(withTitle: "Remove All")
        a.addButton(withTitle: "Cancel")
        guard a.runModal() == .alertFirstButtonReturn else { return }
        Task {
            if let freed = await state.removeAllDownloads() {
                let done = NSAlert()
                done.messageText = "Removed \(ModelRegistry.format(freed))."
                done.informativeText = "Apple's speech and translation languages are "
                    + "still installed. Only System Settings can remove those."
                done.addButton(withTitle: "OK")
                done.addButton(withTitle: SystemRoute.storage.label)
                if done.runModal() == .alertSecondButtonReturn { SystemRoute.storage.open() }
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
                    ForEach(ASREngine.allCases, id: \.self) { Text($0.displayName).tag($0) }
                }
                .pickerStyle(.segmented)
                Text(state.engine.summary).font(.caption).foregroundStyle(.secondary)
                // Stated here rather than left to be discovered, because a
                // limited engine does not fail on the wrong language — it
                // transcribes it into confident nonsense.
                if case .only(let codes) = state.engine.coverage {
                    let names = codes.sorted()
                        .map { Locale.current.localizedString(forLanguageCode: $0) ?? $0 }
                    Label("Recognises \(names.joined(separator: ", ")) only. Other languages come "
                          + "out as nonsense rather than an error.",
                          systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(.orange)
                }
                if state.engine.needsDownload {
                    Label("Not downloaded yet — see Models.", systemImage: "arrow.down.circle")
                        .font(.caption).foregroundStyle(.orange)
                }
            }

            Section("Translation") {
                LabeledContent("Translate to") {
                    Button {
                        state.showTranslationPicker = true
                    } label: {
                        HStack(spacing: 4) {
                            Text(state.translateTo.map { AppLanguage(code: $0).displayName } ?? "Off")
                            Image(systemName: "chevron.up.chevron.down")
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                }
                if state.translateTo != nil {
                    Picker("Translated by", selection: $state.translationEngine) {
                        ForEach(TranslationEngine.allCases, id: \.self) { e in
                            Text(e.displayName).tag(e)
                        }
                    }
                    .pickerStyle(.segmented)
                    Text(state.translationEngine.summary)
                        .font(.caption).foregroundStyle(.secondary)

                    // Any engine can be asked for a language it cannot do, not
                    // just Whisper — and a stored target survives an engine
                    // change, so this has to be checked rather than assumed.
                    if let t = state.translateTo, !state.targetSupportedByEngine {
                        TargetUnsupportedNotice(state: state, target: t)
                    }
                    if state.translationEngine == .qwen {
                        HStack {
                            Button("Choose model…") { state.showQwenModels = true }
                                .controlSize(.small)
                            Text("\(state.qwenModel.label) · \(state.qwenModel.sizeText)")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    if state.translationEngine != .apple {
                        Text("Licence: \(state.translationEngine.licence)")
                            .font(.caption2).foregroundStyle(.tertiary)
                    }
                }

                if state.translateTo != nil, state.translationEngine == .apple {
                    HStack {
                        Button("Language pairs…") { state.showTranslationLanguages = true }
                        if !state.translationStatus.isEmpty {
                            Text(state.translationStatus).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Text("Apple only translates between pairs whose models are on disk. One download, then it works offline.")
                        .font(.caption).foregroundStyle(.secondary)
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
        .formStyle(.grouped)
        .task(id: "\(state.translateTo ?? "")|\(state.translationEngine.rawValue)") {
            await state.refreshTargetSupport()
        }
        .sheet(isPresented: $state.showQwenModels) { QwenModelsView(state: state) }
        .sheet(isPresented: $state.showTranslationPicker) { TranslationTargetPicker(state: state) }
        .sheet(isPresented: $state.showTranslationLanguages) {
            TranslationLanguagesView(
                state: state,
                source: Locale.current.language.languageCode?.identifier ?? "en")
        }
        .translationTask(state.translationConfig) { session in
            do {
                try await session.prepareTranslation()
                await MainActor.run { state.translationStatus = "Ready." }
            } catch {
                await MainActor.run { state.translationStatus = "Failed: \(error.localizedDescription)" }
            }
        }
    }

    @ViewBuilder
    private var appearanceSections: some View {
        Section("Appearance") {
            Toggle("Show the caption bubble", isOn: Binding(
                get: { !state.style.hidden }, set: { state.style.hidden = !$0 }))
            Toggle("Show the translation line", isOn: $state.style.showTranslation)
            LabeledContent("Caption size") {
                HStack {
                    Slider(value: $state.style.fontSize, in: 16...64, step: 1)
                    Text("\(Int(state.style.fontSize))").monospacedDigit().frame(width: 26)
                }
            }
            Stepper("Maximum lines: \(state.style.maxLines)", value: $state.style.maxLines, in: 1...6)
            Picker("Glass", selection: $state.style.glassStyle) {
                Text("Regular").tag(0); Text("Clear").tag(1)
            }
            .pickerStyle(.segmented)
            HStack {
                Button("Preview") {
                    NotificationCenter.default.post(name: .saiityCaptionPreview, object: nil)
                }
                Button("Reset position") {
                    NotificationCenter.default.post(name: .saiityResetBubble, object: nil)
                }
                Button("Defaults") { state.style = CaptionStyle() }
            }
            .controlSize(.small)
            Text("Changes apply live. Preview puts sample text in the real bubble.")
                .font(.caption).foregroundStyle(.secondary)
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
                ? "That combination is already taken by another app." : nil
            state.shortcutsVersion &+= 1
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
                label.stringValue = "Press keys…"
                layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.25).cgColor
            } else if let s = HotKeyCenter.shortcut(for: action) {
                label.stringValue = s.displayString
                layer?.backgroundColor = NSColor.quaternaryLabelColor.cgColor
            } else {
                label.stringValue = "Not set"
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
                                TranscriptStore.delete(s); Task { await state.refresh() }
                            } label: { Image(systemName: "trash") }.controlSize(.small)
                        }
                    }
                    Button("Delete all…", role: .destructive) {
                        let a = NSAlert()
                        a.messageText = "Delete all transcripts?"
                        a.informativeText = "Permanently removes \(state.sessions.count) sessions."
                        a.addButton(withTitle: "Delete All"); a.addButton(withTitle: "Cancel")
                        a.alertStyle = .warning
                        if a.runModal() == .alertFirstButtonReturn {
                            TranscriptStore.deleteAll(); Task { await state.refresh() }
                        }
                    }
                    .controlSize(.small)
                }
            }

            Section("Status") {
                LabeledContent("Engine", value: state.engine.displayName)
                LabeledContent("Screen Recording",
                               value: CGPreflightScreenCaptureAccess() ? "Granted" : "Not granted")
                Text("System-audio capture is gated behind Screen Recording — macOS has no audio-only permission.")
                    .font(.caption).foregroundStyle(.secondary)
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
                Text("Model files are downloaded once: Nemotron and Parakeet from huggingface.co, Apple's speech and translation models from Apple. Nothing you say is ever uploaded.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
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

/// Which Apple translation pairs are on disk, and a way to fetch more.
///
/// Deliberately shows no Delete button: the Translation framework exposes
/// `supportedLanguages` and a per-pair `status`, but **no removal API at all**.
/// Only macOS can remove these, so the page routes there instead of offering a
/// button that cannot work.
struct TranslationLanguagesView: View {
    @Bindable var state: AppState
    let source: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Translation languages").font(.headline)
                    Text("From \(Locale.current.localizedString(forLanguageCode: source)?.capitalized ?? source) · \(state.translationLanguages.filter(\.2).count) installed")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding(14)
            Divider()

            if state.translationLanguagesLoading && state.translationLanguages.isEmpty {
                VStack { ProgressView("Checking which pairs are installed…") }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(state.translationLanguages, id: \.0) { code, name, installed in
                        HStack {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(name)
                                Text(code).font(.caption2).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if state.downloadingPair == code {
                                ProgressView().controlSize(.small)
                            } else if installed {
                                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                            } else {
                                Button("Download") {
                                    state.downloadingPair = code
                                    state.prepareTranslation(from: source, to: code)
                                }
                                .controlSize(.small)
                                .disabled(state.downloadingPair != nil)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                }
                .listStyle(.inset)
            }

            Divider()
            HStack {
                Text("Apple provides no way for an app to delete these. Remove them in System Settings.")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Open Language & Region") {
                    if let u = URL(string: "x-apple.systempreferences:com.apple.Localization-Settings.extension") {
                        NSWorkspace.shared.open(u)
                    }
                }
                .controlSize(.small)
            }
            .padding(14)
        }
        .frame(width: 460, height: 520)
        .task { await state.refreshTranslationLanguages(from: source) }
        .translationTask(state.translationConfig) { session in
            try? await session.prepareTranslation()
            await MainActor.run { state.downloadingPair = nil }
            await state.refreshTranslationLanguages(from: source)
        }
    }
}

// MARK: - Apple speech languages

/// Apple's on-device speech models. sAiity no longer transcribes with them, but
/// they still occupy real disk — over a gigabyte here — so the Models tab shows
/// them and lets you fetch more.
///
/// No Delete button, for the same reason as translation: `AssetInventory` has
/// reserve / release / status / maximumReservedLocales and **no uninstall API**,
/// and the asset directory is on the sealed system volume — `Operation not
/// permitted` even for root. Only macOS can reclaim them.
struct AppleSpeechLanguagesView: View {
    @Bindable var state: AppState
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Apple speech languages").font(.headline)
                    Text("\(state.appleInstalled.count) of \(state.appleLocales.count) installed · \(state.appleReserved.count)/\(state.appleMaxReserved) allocation slots")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding(14)
            Divider()

            if state.appleLoading && state.appleLocales.isEmpty {
                VStack { ProgressView("Asking the speech service…") }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(state.appleLocales, id: \.self) { tag in
                        HStack {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(Self.displayName(tag))
                                Text(tag).font(.caption2).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if state.appleDownloading == tag {
                                ProgressView().controlSize(.small)
                            } else if state.appleInstalled.contains(tag) {
                                if state.appleReserved.contains(tag) {
                                    Button("Release slot") {
                                        Task { await state.releaseAppleLocale(tag) }
                                    }
                                    .controlSize(.small)
                                }
                                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                            } else {
                                Button("Download") { Task { await state.downloadAppleLocale(tag) } }
                                    .controlSize(.small)
                                    .disabled(state.appleDownloading != nil)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                }
                .listStyle(.inset)
            }

            Divider()
            HStack {
                Text("These cannot be deleted by an app — the folder is on the sealed system volume. macOS removes them on its own schedule.")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Storage") { SystemRoute.storage.open() }.controlSize(.small)
            }
            .padding(14)
        }
        .frame(width: 460, height: 520)
        .task { await state.refreshAppleLocales() }
    }

    static func displayName(_ tag: String) -> String {
        let l = Locale(identifier: tag)
        let lang = l.language.languageCode?.identifier ?? tag
        let base = Locale.current.localizedString(forLanguageCode: lang)?.capitalized ?? lang
        if let r = l.region?.identifier,
           let region = Locale.current.localizedString(forRegionCode: r) {
            return "\(base) — \(region)"
        }
        return base
    }
}

// MARK: - Qwen models

/// Pick which Qwen build does the translating.
///
/// The 0.8B is deliberately shown with a warning rather than hidden: it is the
/// fastest option and people will reach for it, but a sub-billion instruct model
/// invents and drops meaning badly enough that a wrong translation is worse than
/// none. Saying so is more useful than quietly omitting it.
struct QwenModelsView: View {
    @Bindable var state: AppState
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Qwen models").font(.headline)
                    Text("All Apache-2.0 · one is used at a time")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding(14)
            Divider()

            List {
                ForEach(QwenModel.all) { m in
                    HStack(alignment: .top) {
                        Image(systemName: m == state.qwenModel ? "largecircle.fill.circle" : "circle")
                            .foregroundStyle(m == state.qwenModel ? Color.accentColor : Color.secondary)
                            .onTapGesture { state.qwenModel = m }
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
                        if let asset = state.assets.first(where: { $0.id == "mt.qwen.\(m.file)" }) {
                            if state.activeDownload == asset.id {
                                if let f = state.downloadProgress?.fraction {
                                    ProgressView(value: f).frame(width: 90)
                                } else {
                                    ProgressView().controlSize(.small)
                                }
                            } else if asset.isInstalled || asset.isPartial {
                                Button(asset.isPartial ? "Remove" : "Delete", role: .destructive) {
                                    Task { await state.delete(asset.asset) }
                                }
                                .controlSize(.small)
                            } else {
                                Button("Download") { Task { await state.download(asset.asset) } }
                                    .controlSize(.small)
                                    .disabled(state.activeDownload != nil)
                            }
                        }
                    }
                    .contentShape(Rectangle())
                    .onTapGesture { state.qwenModel = m }
                    .padding(.vertical, 3)
                }
            }
            .listStyle(.inset)

            if let e = state.modelError {
                Divider()
                Text(e).font(.caption).foregroundStyle(.red).padding(14)
            }
        }
        .frame(width: 480, height: 480)
    }
}
