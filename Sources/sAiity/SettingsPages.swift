import AppKit
import AVFoundation
import ApplicationServices
import Carbon.HIToolbox
import CoreGraphics
import SwiftUI
import UniformTypeIdentifiers

struct DictationShortcutRecorder: NSViewRepresentable {
    @Bindable var state: AppState
    /// Why the last attempt was not used, or nil. Shown under the row.
    var onMessage: (String?) -> Void = { _ in }

    func makeNSView(context: Context) -> RecorderView {
        let view = RecorderView()
        view.chord = state.dictationChord
        view.onChange = { state.dictationChord = $0 }
        view.onMessage = onMessage
        return view
    }

    func updateNSView(_ view: RecorderView, context: Context) {
        view.chord = state.dictationChord
        view.onMessage = onMessage
        view.refresh()
    }

    final class RecorderView: NSView {
        var chord = DictationChord.current
        var onChange: ((DictationChord) -> Void)?
        var onMessage: ((String?) -> Void)?
        /// Injectable so tests do not depend on this Mac's keyboard shortcuts.
        var systemConflict: (DictationChord) -> String? = { SystemShortcuts.conflict(for: $0) }
        private var recording = false
        private var capture = DictationChordCaptureState()
        private var eventMonitor: Any?
        private let label = NSTextField(labelWithString: "")

        override init(frame: NSRect) {
            super.init(frame: frame)
            label.alignment = .center
            label.font = .systemFont(ofSize: 13, weight: .medium)
            label.translatesAutoresizingMaskIntoConstraints = false
            addSubview(label)
            NSLayoutConstraint.activate([
                label.centerXAnchor.constraint(equalTo: centerXAnchor),
                label.centerYAnchor.constraint(equalTo: centerYAnchor),
                // Fixed, not a minimum. A `greaterThanOrEqualTo` inside an HStack
                // with a Spacer expanded to fill the row, so the recorder ran to
                // ~450 pt to hold five characters of key chord. A control the size
                // of its content is also a control, not a banner.
                widthAnchor.constraint(equalToConstant: 150),
                heightAnchor.constraint(equalToConstant: 26),
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
            // Keys were down when the window lost focus: macOS acted on the
            // chord itself (Spotlight, Finder search) and took the window away.
            if recording, !capture.captured.isEmpty {
                onMessage?(String(localized: "macOS used that shortcut for something else. Choose another one."))
            }
            endRecording()
        }

        func refresh() {
            let assigned = chord.displayString
            let text = ShortcutRecorderChrome.label(
                assigned: assigned.isEmpty ? nil : assigned,
                recording: recording)
            label.stringValue = recording
                ? (capture.captured.isEmpty
                    ? String(localized: "Press the full chord, then release…")
                    : DictationChord(keyCodes: capture.captured).displayString)
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
            onMessage?(nil)
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
            refresh()
        }

        override func keyUp(with event: NSEvent) {
            guard recording else { super.keyUp(with: event); return }
            commitIfReady(capture.handle(.keyUp(UInt16(event.keyCode))))
        }

        private func commitIfReady(_ chord: DictationChord?) {
            guard let chord else {
                if capture.lastRejected != nil {
                    onMessage?(String(localized: "Use two modifier keys, such as ⌃⌥, or a modifier with another key."))
                }
                refresh()
                return
            }
            if let use = systemConflict(chord) {
                onMessage?(String(localized: "macOS already uses \(chord.displayString) for \(use). Choose another shortcut."))
                refresh()
                return
            }
            onMessage?(nil)
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
            label.font = .systemFont(ofSize: 13, weight: .medium)
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
        Form {
            Section {
                Toggle(isOn: $state.saveTranscript) {
                    Text("Save transcripts")
                    Text("Each captioned session is kept on this Mac, with its translation.")
                }
                Picker("Keep transcripts", selection: $retentionDays) {
                    ForEach(TranscriptRetention.choices, id: \.self) { d in
                        Text(TranscriptRetention.label(d)).tag(d)
                    }
                }
                .disabled(CaptionSession.shared.isProcessingTranscript || summarizing != nil)
                .onChange(of: retentionDays) { old, new in
                    // Ask first: choosing a shorter period deletes everything
                    // already older than it, immediately and irreversibly.
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

            Section {
                if state.sessions.isEmpty {
                    ContentUnavailableView(
                        "Nothing saved yet",
                        systemImage: "text.document",
                        description: Text("Turn on “Save transcripts” and every captioned session appears here."))
                        .frame(maxWidth: .infinity)
                } else {
                    TextField(text: $query, prompt: Text("Search all transcripts")) {
                        Text("Search")
                    }
                }
                if !state.sessions.isEmpty, !trimmedQuery.isEmpty {
                    if isSearching {
                        HStack(spacing: 8) {
                            ProgressView()
                                .controlSize(.small)
                            Text("Searching saved transcripts…")
                                .foregroundStyle(.secondary)
                        }
                    } else if searchHits.isEmpty {
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
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help("Open this transcript")
                    }
                    // Keep a running session and its Cancel reachable during search.
                    if let s = summarizing { sessionRow(s) }
                    if let s = retranslating { sessionRow(s) }
                } else if !state.sessions.isEmpty {
                    ForEach(state.sessions, id: \.id) { s in
                        sessionRow(s)
                    }
                }
                if let p = retranslateProgress, retranslating == nil {
                    TranscriptProgressRow(label: "\(p.note) \(p.done)/\(p.total)",
                                          done: p.done, total: p.total)
                }
                if let note = retranslateNote {
                    Text(verbatim: note)
                        .foregroundStyle(note.hasPrefix("✓")
                                         ? AnyShapeStyle(.secondary)
                                         : AnyShapeStyle(Color.orange))
                }
            } header: {
                Text("Saved sessions")
            }

            if !state.sessions.isEmpty, trimmedQuery.isEmpty {
                Section {
                    LabeledContent("Export") {
                        Menu("Export All…") {
                            Button("Plain text") { exportLibrary("txt") }
                            Button("Markdown") { exportLibrary("md") }
                            Button("SRT") { exportLibrary("srt") }
                            Button("WebVTT") { exportLibrary("vtt") }
                        }
                        .fixedSize()
                        .disabled(retranslateProgress != nil || retranslating != nil || summarizing != nil)
                    }
                    LabeledContent("Delete") {
                        Button("Delete All…", role: .destructive) {
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
                        .disabled(CaptionSession.shared.isProcessingTranscript || summarizing != nil || retranslating != nil)
                    }
                }
            }
        }
        .formStyle(.grouped)
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
