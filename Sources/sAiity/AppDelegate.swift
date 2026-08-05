import AppKit
import AVFoundation
import CoreGraphics
import Foundation
import NaturalLanguage
import Speech

/// Menu-bar app. No dock icon, no main window — just the caption bar.
///
/// Isolated to the main actor as a whole. Everything here is AppKit or drives
/// AppKit, and the alternative — a nonisolated class with `assumeIsolated` at
/// each entry point — let `beginRecording()` and `endRecording()` mutate an
/// NSView hierarchy and the status-item image from a cooperative-pool thread
/// after their first `await`. The compiler warned about it; nothing enforced it.
/// Class-level isolation makes that a build error instead.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private let overlay = OverlayWindow()
    private let capture = SystemAudioCapture()
    private var engine = ASREngine.current
    private var backend: TranscriptionBackend = AppDelegate.makeActiveBackend()

    /// Recognition is always the selected ASR engine.
    ///
    /// Whisper used to be able to replace it — speech straight to English in one
    /// model pass — which is why this was a function rather than a property.
    /// That engine was cut: it stopped emitting finals about 25 seconds into
    /// every session (its sliding window slid but its commit index never
    /// rebased), and it was slower than Nemotron plus a real translator anyway.
    static func makeActiveBackend() -> TranscriptionBackend {
        ASREngine.current.makeBackend()
    }

    private let translator = Translator()
    private var activeTranslator: Translating? = TranslationEngine.current.makeTranslator()
    private var translatorReady = false

    /// Load (and if necessary download) the selected translator. This was the
    /// missing link: the translator object was constructed but `prepare()` was
    /// never called, so MADLAD and Qwen never downloaded their weights and
    /// `translate()` quietly returned nil forever.
    @MainActor
    private func prepareTranslatorIfNeeded() async {
        guard let target = translateTo,
              let engine = activeTranslator, !translatorReady else { return }
        let src = detectedLanguage ?? locale.identifier(.bcp47)
        NSLog("sAiity translator: selected=\(TranslationEngine.current.rawValue) object=\(engine.name) src=\(src) dst=\(target)")
        do {
            try await engine.prepare(from: src, to: target) { [weak self] msg in
                NSLog("sAiity translator progress: \(msg)")
                Task { @MainActor in self?.setStatus(msg) }
            }
            translatorReady = true
            setStatus("Translating with \(TranslationEngine.current.displayName)")
        } catch {
            translatorReady = false
            setStatus("Translation unavailable: \(error.localizedDescription)")
            NSLog("sAiity translator prepare failed: \(error.localizedDescription)")
        }
    }

    /// Where the capture session is in its lifecycle.
    ///
    /// A Bool could not express `starting`, and that gap was the bug: `start()`
    /// set `running = true` and then did the real work — model load, possibly a
    /// 634 MB download — in a Task nobody held. `stop()` flipped the flag and
    /// tore down a backend that had not started yet, and the start Task
    /// afterwards went right on to bring up the audio stream. The result was
    /// system audio being captured, with the recording indicator lit, while the
    /// menu said "Start captions".
    enum SessionState: Equatable {
        case idle, starting, running, stopping

        /// What the menu offers, and what a caller may do next.
        var isActive: Bool { self == .starting || self == .running }
    }

    private var state: SessionState = .idle {
        didSet {
            guard state != oldValue else { return }
            // The Settings window gates model deletion on this: deleting weights
            // out from under a loading engine is exactly as bad as under a
            // running one, so `starting` counts as busy.
            CaptionSession.shared.setRunning(state.isActive)
        }
    }

    /// The in-flight start. Held so `stopAsync()` can cancel it and wait for it
    /// to actually leave the engine before tearing anything down.
    private var sessionTask: Task<Void, Never>?

    private var locale = Locale(identifier: "en-US")
    /// BCP-47, nil = off. Persisted — it was previously an in-memory var, so the
    /// chosen target silently reset to "off" on every launch, which is one of the
    /// two reasons translation appeared not to work at all.
    private var translateTo: String? = UserDefaults.standard.string(forKey: "translateTo") {
        didSet { UserDefaults.standard.set(translateTo, forKey: "translateTo") }
    }
    private var translateNote = ""
    private var statusLine = "Idle"
    private var showedAnyCaption = false

    // Recording is deliberately separate from captioning and defaults to OFF:
    // captions are ephemeral, a transcript is a durable record of a conversation
    // other people were part of.
    private var saveTranscript = UserDefaults.standard.bool(forKey: "saveTranscript")
    private var recordingSince: Date?
    private var recordedLines = 0
    /// Untruncated, unlike the overlay label — never copy from the view.
    private var lastFinalText = ""
    private var lastVolatileText = ""
    private var sessionLines: [Segment] = []

    // Auto language detection. `autoLanguage` controls whether a confident
    // detection also SWITCHES the recogniser; the detected language is always
    // tracked, because translation needs a real source language rather than
    // whatever locale happens to be selected.
    private var detector = LanguageDetector()
    private var detectedLanguage: String?
    /// The PCM format the capture stream is currently converting into. If a
    /// language switch changes it, capture has to be restarted too or we would
    /// feed the new engine buffers in the old engine's format.
    private var captureFormat: AVAudioFormat?

    /// Recently chosen targets, so the menu stays short without being a fixed
    /// list that ignores what this person actually uses.
    private var recentTargets: [String] {
        get { UserDefaults.standard.stringArray(forKey: "recentTranslateTargets") ?? [] }
        set {
            UserDefaults.standard.set(Array(newValue.prefix(6)), forKey: "recentTranslateTargets")
        }
    }

    private func rememberTarget(_ code: String) {
        var r = recentTargets.filter { $0 != code }
        r.insert(code, at: 0)
        recentTargets = r
    }

    @objc private func showLanguagePicker() {
        SettingsWindowController.show()
        SettingsWindowController.state.showTranslationPicker = true
    }

    /// An LSUIElement app has no App menu, so this is the ONLY route to the
    /// version string and to the third-party notices the licences require to
    /// travel with the binary.
    @objc private func showAbout() {
        let credits: NSAttributedString
        if let url = Bundle.main.url(forResource: "Credits", withExtension: "txt"),
           let text = try? String(contentsOf: url, encoding: .utf8) {
            credits = NSAttributedString(
                string: text,
                attributes: [.font: NSFont.monospacedSystemFont(ofSize: 10, weight: .regular)])
        } else {
            credits = NSAttributedString(string: "Credits file missing from this build.")
        }
        ForegroundActivation.begin()
        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationName: "sAiity",
            .credits: credits,
            .init(rawValue: "Copyright"): "MIT licensed. On-device live subtitles.",
        ])
        // The standard About panel has no close callback, so give up the Dock
        // presence when the app next loses focus. One-shot: the token has to be
        // held to be removed, and re-registering on every About would leak an
        // observer per invocation.
        guard aboutResignObserver == nil else { return }
        aboutResignObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated {
                    ForegroundActivation.end()
                    if let t = self.aboutResignObserver {
                        NotificationCenter.default.removeObserver(t)
                        self.aboutResignObserver = nil
                    }
                }
            }
    }

    private var aboutResignObserver: NSObjectProtocol?

    func applicationDidFinishLaunching(_ note: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let img = NSImage(systemSymbolName: "captions.bubble", accessibilityDescription: "sAiity") {
            img.isTemplate = true
            statusItem.button?.image = img
        } else {
            statusItem.button?.title = "CC"
        }
        statusItem.button?.toolTip = "sAiity — on-device live subtitles"
        overlay.onCopy = { [weak self] in self?.copyCurrentLine() }
        overlay.onOpenWindow = { SettingsWindowController.show() }
        NotificationCenter.default.addObserver(
            self, selector: #selector(saveTranscriptChangedExternally(_:)),
            name: .saiitySaveTranscriptChanged, object: nil)
        rebuildMenu()

        // Lets the Settings window stop the session and drop loaded models
        // before it deletes their files.
        CaptionSession.shared.releaseModels = { [weak self] in await self?.releaseModels() }
        // Leftovers from an interrupted download; nothing else cleans these up.
        FileDownloader.sweepPartials(in: ModelRegistry.root)

        NSLog("sAiity launch: screenCapture=\(CGPreflightScreenCaptureAccess())")

        NotificationCenter.default.addObserver(forName: .saiityResetBubble, object: nil,
                                               queue: .main) { [weak self] _ in
            self?.overlay.resetPosition()
        }

        HotKeyCenter.shared.register(.toggleCaptions) { [weak self] in
            self?.toggle()
        }
        HotKeyCenter.shared.register(.copyLastLine) { [weak self] in
            self?.copyCurrentLine()
        }

        if let t = translateTo {
            Task { @MainActor in
                await translator.setTarget(Locale.Language(identifier: t))
            }
        }

        // Keep the menu-bar picker and the window in step — they write the same
        // preference, so without this they silently disagree.
        NotificationCenter.default.addObserver(forName: .saiityTranslateTargetChanged, object: nil,
                                               queue: .main) { [weak self] note in
            let t = note.userInfo?["target"] as? String
            MainActor.assumeIsolated {
                guard let self else { return }
                self.translateTo = t
                self.translateNote = ""
                self.activeTranslator = TranslationEngine.current.makeTranslator()
                self.translatorReady = false
                Task { @MainActor in
                    await self.translator.setTarget(t.map { Locale.Language(identifier: $0) })
                    // Hold the row open for as long as translation is on, so the
                    // bubble does not change height every time a translation
                    // lands and clears.
                    self.overlay.reservesTranslationRow = t != nil
                    if t == nil { self.overlay.showTranslation("") }
                    await self.refreshTranslateNote()
                    // Changing the translation target no longer changes which
                    // recognition engine runs — that was only ever true for
                    // Whisper, which has been cut.
                    self.rebuildMenu()
                    await self.prepareTranslatorIfNeeded()
                }
            }
        }

        NotificationCenter.default.addObserver(forName: .saiityEngineChanged, object: nil,
                                               queue: .main) { [weak self] note in
            guard let raw = note.userInfo?["engine"] as? String,
                  let e = ASREngine(rawValue: raw) else { return }
            // Delivered on .main, but the closure itself is nonisolated.
            MainActor.assumeIsolated { self?.engineChanged(to: e) }
        }

        // Nemotron is one multilingual model that identifies the language from
        // audio, so there is no locale to choose and nothing to query. This used
        // to round-trip the system speech daemon on every launch.
        statusLine = "Idle"
        rebuildMenu()
        // First run: explain, get the permission, and download deliberately —
        // rather than the old behaviour of doing all three silently behind a
        // "Start captions" click and then failing.
        //
        // Skipped under SAIITY_AUTOSTART, which is the headless/e2e path and
        // must not put a window on screen.
        let autostart = TestHooks.autostart
        if Onboarding.needsRun && !autostart {
            OnboardingWindowController.shared.show(state: SettingsWindowController.state)
        }
        if autostart { start() }
        // Sibling of SAIITY_AUTOSTART: this is a menu-bar app, so there is no
        // way to reach the settings window from a script, which makes checking
        // its layout after a change needlessly manual.
        if TestHooks.openSettings {
            SettingsWindowController.show()
        }
    }

    /// Launching an already-running menu-bar app (double-clicking it in Finder,
    /// or `open -a`) otherwise does nothing at all, which reads as broken.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        SettingsWindowController.show()
        return true
    }

    /// Close the transcript cleanly on quit, otherwise the last lines are on
    /// disk but meta.json still says the session never ended.
    func applicationWillTerminate(_ note: Notification) {
        guard recordingSince != nil else { return }
        let sem = DispatchSemaphore(value: 0)
        Task.detached {
            try? await TranscriptStore.shared.end()
            sem.signal()
        }
        _ = sem.wait(timeout: .now() + 2)
    }

    // MARK: - Menu

    private func rebuildMenu() {
        let menu = NSMenu()
        let header = NSMenuItem(title: backend.name, action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        if let rl = recordingLine {
            let r = NSMenuItem(title: rl, action: nil, keyEquivalent: "")
            r.isEnabled = false
            menu.addItem(r)
        }
        let s = NSMenuItem(title: statusLine, action: nil, keyEquivalent: "")
        s.isEnabled = false
        menu.addItem(s)
        menu.addItem(.separator())
        let toggleItem = NSMenuItem(title: state.isActive ? "Stop captions" : "Start captions",
                                    action: #selector(toggle), keyEquivalent: "")
        if let sc = HotKeyCenter.shortcut(for: .toggleCaptions), sc.isUsable {
            // Shown for discoverability. The real binding is the global hot key —
            // a menu keyEquivalent only fires while this app is frontmost, which
            // a menu-bar app never is.
            toggleItem.title += "  (\(sc.displayString))"
        }
        menu.addItem(toggleItem)

        menu.addItem(translationMenuItem())

        menu.addItem(.separator())
        let copyLine = NSMenuItem(title: "Copy current line", action: #selector(copyCurrentLine),
                                  keyEquivalent: "c")
        copyLine.isEnabled = !(lastFinalText.isEmpty && lastVolatileText.isEmpty)
        menu.addItem(copyLine)
        let copyAll = NSMenuItem(title: "Copy whole session", action: #selector(copyWholeSession),
                                 keyEquivalent: "C")
        copyAll.isEnabled = !sessionLines.isEmpty
        menu.addItem(copyAll)

        let rec = NSMenuItem(title: "Save transcript", action: #selector(toggleSaveTranscript),
                             keyEquivalent: "")
        rec.state = saveTranscript ? .on : .off
        rec.toolTip = "Write this session to disk. Off by default."
        menu.addItem(rec)
        menu.addItem(transcriptsMenuItem())

        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Open sAiity…", action: #selector(openMainWindow),
                                keyEquivalent: ","))
        menu.addItem(NSMenuItem(title: "About sAiity", action: #selector(showAbout),
                                keyEquivalent: ""))
        // terminate(_:) lives on NSApplication, not on this delegate. Without an
        // explicit target, assignTargets below would point it at AppDelegate,
        // which does not implement it — and the item silently does nothing.
        let quit = NSMenuItem(title: "Quit sAiity", action: #selector(NSApplication.terminate(_:)),
                              keyEquivalent: "q")
        quit.target = NSApp
        menu.addItem(quit)
        assignTargets(menu)
        statusItem.menu = menu
    }


    private func translationMenuItem() -> NSMenuItem {
        let item = NSMenuItem(title: "Translate to", action: nil, keyEquivalent: "")
        let menu = NSMenu()
        let off = NSMenuItem(title: "Off", action: #selector(pickTranslation(_:)), keyEquivalent: "")
        off.representedObject = ""
        off.state = translateTo == nil ? .on : .off
        menu.addItem(off)
        menu.addItem(.separator())

        // A short, relevant menu plus a route to all ~450, rather than a
        // hardcoded twelve. The old list also disagreed with the one in
        // Settings, so the languages on offer depended on where you looked.
        var shown: [String] = []
        func add(_ code: String) {
            guard !shown.contains(code) else { return }
            shown.append(code)
            let mi = NSMenuItem(title: AppLanguage(code: code).displayName,
                                action: #selector(pickTranslation(_:)), keyEquivalent: "")
            mi.representedObject = code
            mi.state = (code == translateTo) ? .on : .off
            menu.addItem(mi)
        }
        if let current = translateTo { add(current) }
        recentTargets.forEach(add)
        // What this Mac is actually set up for beats any list we could guess.
        for tag in Locale.preferredLanguages.prefix(4) {
            add(Locale(identifier: tag).language.languageCode?.identifier ?? tag)
        }
        for code in ["en", "de"] where shown.count < 8 { add(code) }

        menu.addItem(.separator())
        let all = NSMenuItem(title: "All languages…", action: #selector(showLanguagePicker),
                             keyEquivalent: "")
        menu.addItem(all)

        if !translateNote.isEmpty {
            menu.addItem(.separator())
            let n = NSMenuItem(title: translateNote, action: nil, keyEquivalent: "")
            n.isEnabled = false
            menu.addItem(n)
        }
        assignTargets(menu)
        item.submenu = menu
        return item
    }

    /// Only claim items that have not already chosen a target — otherwise this
    /// steals actions meant for NSApp.
    private func assignTargets(_ menu: NSMenu) {
        for item in menu.items where item.action != nil && item.target == nil {
            item.target = self
        }
    }

    private func setStatus(_ text: String) {
        statusLine = text
        rebuildMenu()
    }

    /// Prefixed to the status line so "this is being written down" is the first
    /// thing the menu says.
    private var recordingLine: String? {
        guard let since = recordingSince else { return nil }
        let m = Int(Date().timeIntervalSince(since) / 60)
        return "● Recording · \(m) min · \(recordedLines) lines"
    }

    // MARK: - Actions

    /// Past sessions, newest first. Everything is local; "Reveal in Finder" is
    /// there so what exists on disk is never a mystery.
    private func transcriptsMenuItem() -> NSMenuItem {
        let item = NSMenuItem(title: "Transcripts", action: nil, keyEquivalent: "")
        let menu = NSMenu()
        let sessions = TranscriptStore.list()

        if sessions.isEmpty {
            let n = NSMenuItem(title: "No saved transcripts", action: nil, keyEquivalent: "")
            n.isEnabled = false
            menu.addItem(n)
        }
        let df = DateFormatter()
        df.dateStyle = .medium
        df.timeStyle = .short
        for s in sessions.prefix(15) {
            let mins = Int((s.meta.endedAt ?? s.meta.startedAt)
                .timeIntervalSince(s.meta.startedAt) / 60)
            let mi = NSMenuItem(
                title: "\(df.string(from: s.meta.startedAt)) · \(s.meta.lineCount) lines · \(mins) min",
                action: nil, keyEquivalent: "")
            let sub = NSMenu()
            for (title, sel) in [("Copy as text", #selector(exportCopy(_:))),
                                 ("Save as Markdown", #selector(exportMarkdown(_:))),
                                 ("Save as SRT", #selector(exportSRT(_:))),
                                 ("Reveal in Finder", #selector(revealSession(_:))),
                                 ("Delete", #selector(deleteSession(_:)))] {
                let a = NSMenuItem(title: title, action: sel, keyEquivalent: "")
                a.representedObject = s.id
                sub.addItem(a)
            }
            assignTargets(sub)
            mi.submenu = sub
            menu.addItem(mi)
        }
        if !sessions.isEmpty {
            menu.addItem(.separator())
            menu.addItem(NSMenuItem(title: "Delete all transcripts…",
                                    action: #selector(deleteAllSessions), keyEquivalent: ""))
        }
        assignTargets(menu)
        item.submenu = menu
        return item
    }

    private func session(for sender: NSMenuItem) -> SessionRef? {
        guard let id = sender.representedObject as? String else { return nil }
        return TranscriptStore.list().first { $0.id == id }
    }

    @objc private func exportCopy(_ sender: NSMenuItem) {
        guard let s = session(for: sender) else { return }
        Clipboard.copy(Export.txt(TranscriptStore.segments(of: s)))
        setStatus("Transcript copied")
    }

    @objc private func exportMarkdown(_ sender: NSMenuItem) {
        guard let s = session(for: sender) else { return }
        let out = Export.markdown(TranscriptStore.segments(of: s), meta: s.meta)
        if let url = Export.write(out, named: "transcript.md", in: s.url) {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
    }

    @objc private func exportSRT(_ sender: NSMenuItem) {
        guard let s = session(for: sender) else { return }
        let out = Export.srt(TranscriptStore.segments(of: s))
        if let url = Export.write(out, named: "transcript.srt", in: s.url) {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
    }

    @objc private func revealSession(_ sender: NSMenuItem) {
        guard let s = session(for: sender) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([s.url])
    }

    @objc private func deleteSession(_ sender: NSMenuItem) {
        guard let s = session(for: sender) else { return }
        TranscriptStore.delete(s)
        setStatus("Transcript deleted")
    }

    @objc private func deleteAllSessions() {
        TranscriptStore.deleteAll()
        setStatus("All transcripts deleted")
    }

    @objc private func toggleSaveTranscript() {
        applySaveTranscript(!saveTranscript)
    }

    @objc private func saveTranscriptChangedExternally(_ note: Notification) {
        guard let on = note.userInfo?["on"] as? Bool, on != saveTranscript else { return }
        applySaveTranscript(on)
    }

    /// The single place recording is turned on or off, wherever the request
    /// came from.
    private func applySaveTranscript(_ on: Bool) {
        saveTranscript = on
        UserDefaults.standard.set(saveTranscript, forKey: "saveTranscript")

        // Say the quiet part once, the first time it is switched on.
        if saveTranscript, !UserDefaults.standard.bool(forKey: "recordingNoticeShown") {
            UserDefaults.standard.set(true, forKey: "recordingNoticeShown")
            let a = NSAlert()
            a.messageText = "Transcripts are saved to this Mac"
            a.informativeText = """
                Sessions are written to ~/Library/Application Support/de.aiity.saiity \
                and never leave the device.

                System audio includes everyone on a call. Recording other people may \
                require their consent, or be regulated where you are — it is worth \
                telling them.
                """
            a.addButton(withTitle: "OK")
            a.alertStyle = .informational
            a.runModal()
        }

        if state.isActive {
            Task { @MainActor in
                if saveTranscript { await beginRecording() } else { await endRecording() }
                rebuildMenu()
            }
        } else {
            rebuildMenu()
        }
    }

    @objc private func copyCurrentLine() {
        let line = lastFinalText.isEmpty ? lastVolatileText : lastFinalText
        guard !line.isEmpty else { return }
        Clipboard.copy(line)
        setStatus("Line copied")
    }

    @objc private func copyWholeSession() {
        guard !sessionLines.isEmpty else { return }
        Clipboard.copy(Export.txt(sessionLines))
        setStatus("Session copied (\(sessionLines.count) lines)")
    }

    private func beginRecording() async {
        do {
            try await TranscriptStore.shared.begin(locale: locale.identifier(.bcp47),
                                                   translateTo: translateTo)
            recordingSince = Date()
            recordedLines = 0
            overlay.isRecording = true
            updateStatusItemIcon()
        } catch {
            NSLog("sAiity recording failed to start: \(error.localizedDescription)")
            setStatus("Could not start recording")
        }
    }

    private func endRecording() async {
        try? await TranscriptStore.shared.end()
        recordingSince = nil
        overlay.isRecording = false
        updateStatusItemIcon()
    }

    /// The menu-bar icon fills in while a transcript is being written, so the
    /// state is never ambiguous.
    private func updateStatusItemIcon() {
        let name = overlay.isRecording ? "captions.bubble.fill" : "captions.bubble"
        if let img = NSImage(systemSymbolName: name, accessibilityDescription: "sAiity") {
            img.isTemplate = true
            statusItem.button?.image = img
        }
    }

    /// Swap engines live. Recognition restarts; capture keeps running, so no
    /// audio is lost beyond the model-load gap.
    @MainActor
    private func engineChanged(to new: ASREngine) {
        guard new != engine else { return }
        engine = new
        ASREngine.current = new
        let wasRunning = state.isActive
        Task { @MainActor in
            if wasRunning { await backend.stop() }
            backend = new.makeBackend()
            setStatus("Engine: \(new.displayName)")
            if wasRunning { restartRecognition() }
            rebuildMenu()
        }
    }

    @objc private func openMainWindow() {
        Task { @MainActor in SettingsWindowController.show() }
    }



    /// Picking from the menu bar only announces the choice. The notification
    /// handler is the single place that rebuilds the translator, so the menu and
    /// the Settings window cannot drift apart or do the work twice.
    @objc private func pickTranslation(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        let target = id.isEmpty ? nil : id
        guard target != translateTo else { return }
        if let target { rememberTarget(target) }
        NotificationCenter.default.post(name: .saiityTranslateTargetChanged, object: nil,
                                        userInfo: ["target": target as Any])
    }

    /// Whether Apple still has to fetch this pair. Worth saying plainly: the
    /// framework cannot raise its own download prompt from a menu-bar app, so
    /// the user has to go to Settings for it.
    @MainActor
    private func refreshTranslateNote() async {
        guard translateTo != nil, TranslationEngine.current == .apple else {
            translateNote = ""
            return
        }
        let src = Locale.Language(identifier: locale.identifier(.bcp47))
        translateNote = await translator.availability(from: src) == .needsDownload
            ? "Download in Settings → Translation Languages" : ""
        rebuildMenu()
    }

    @objc private func toggle() {
        state.isActive ? stop() : start()
    }

    private func start() {
        // Ignore a second Start while one is already in flight. Without this,
        // two starts each brought up their own SCStream and their own ASR pump,
        // and two pumps calling process() concurrently is the exact overlap
        // StreamingASRBackend documents as a reproduced crash.
        guard state == .idle else { return }
        state = .starting
        showedAnyCaption = false
        overlay.reservesTranslationRow = translateTo != nil
        sessionLines.removeAll()
        lastFinalText = ""
        lastVolatileText = ""
        detector.reset()
        detectedLanguage = nil
        setStatus("Starting…")
        overlay.show(text: "starting…", isFinal: false)

        sessionTask = Task { @MainActor in
            do {
                NSLog("sAiity engine: preparing \(backend.name)")
                try await backend.prepare(locale: locale) { msg in
                    Task { @MainActor [self] in
                        guard self.state == .starting else { return }
                        self.setStatus(msg)
                        self.overlay.show(text: msg, isFinal: false)
                    }
                }
                // Every await below is a place the user may have pressed Stop —
                // prepare() alone can be a multi-gigabyte download. Bail before
                // touching the microphone-equivalent, not after.
                try Task.checkCancellation()

                try await backend.start { chunk in
                    Task { @MainActor [self] in self.render(chunk) }
                }
                try Task.checkCancellation()

                guard let fmt = await backend.inputFormat else {
                    throw BackendError.notPrepared
                }
                try Task.checkCancellation()
                captureFormat = fmt
                let activeBackend = backend
                try await capture.start(
                    targetFormat: fmt,
                    // Capture the backend we are starting WITH, rather than
                    // reading self.backend on each buffer. This closure runs on
                    // the capture queue ~50×/s while the main actor may be
                    // reassigning that property during an engine swap — an
                    // unsynchronised read/write of a class reference. Binding it
                    // once also guarantees the audio goes to the engine the
                    // stream was configured for.
                    onBuffer: { [activeBackend] buf in activeBackend.feed(buf) },
                    onState: { audio in
                        Task { @MainActor [self] in self.captureStateChanged(audio) }
                    })

                if saveTranscript { await beginRecording() }
                state = .running
                setStatus("Listening · \(Self.coverageNote())")
                NSLog("sAiity engine: started; preparing translator")
                await prepareTranslatorIfNeeded()
                overlay.show(text: "listening…", isFinal: false)
            } catch is CancellationError {
                // stopAsync() is awaiting us; it owns the teardown from here.
                NSLog("sAiity engine: start cancelled before capture began")
            } catch {
                state = .idle
                let msg = error.localizedDescription
                setStatus("Error")
                overlay.show(text: msg, isFinal: true)
                NSLog("sAiity start failed: \(msg)")
            }
        }
    }

    /// Acts on a confirmed language change.
    ///
    /// Switching the recogniser is deliberately conservative. The locale is more
    /// a decoding hint than a model selector — the de-* and en-* transcribers
    /// share one multilingual model, and English audio transcribes verbatim
    /// through a German locale — so a restart usually buys nothing and costs a
    /// gap in the captions. We only switch when a model for the detected
    /// language is genuinely installed and differs from the current one.
    /// Report the detected language. With a single multilingual engine there
    /// is nothing to switch — the value's real job is telling the translator
    /// what the source language actually is.
    @MainActor
    /// What the running engine can hear, said up front.
    ///
    /// This has to be proactive, because the reactive check cannot work for the
    /// case that matters: an English-only engine fed German does not emit
    /// German, it emits English-shaped gibberish ("decuts on shout altem
    /// fenster" — measured). The text detector reads that as English and never
    /// fires, and Parakeet has no audio-level language identification to ask.
    /// So the constraint is stated when captions start, not discovered later.
    private static func coverageNote() -> String {
        switch ASREngine.current.coverage {
        case .manyDetectedFromAudio:
            return "detecting language"
        case .only(let codes):
            let names = codes.sorted().map {
                Locale.current.localizedString(forLanguageCode: $0) ?? $0
            }
            return "\(names.joined(separator: ", ")) only"
        }
    }

    private func languageDetected(_ code: String) {
        let name = Locale.current.localizedString(forLanguageCode: code) ?? code
        // An engine that cannot hear this language does not fail — it produces
        // fluent nonsense, which looks like the app working badly rather than
        // being pointed at the wrong model. Say so plainly.
        let engine = ASREngine.current
        guard engine.canHear(code) else {
            setStatus("\(engine.displayName) recognises English only — this sounds like \(name)")
            overlay.show(text: "\(engine.displayName) only recognises English. "
                             + "This sounds like \(name) — switch engine in Settings → Captions.",
                         isFinal: true)
            return
        }
        setStatus("Listening · \(name)")
    }

    /// Swap the recogniser without dropping the capture stream or the session.
    private func restartRecognition() {
        Task { @MainActor in
            await backend.stop()
            do {
                try await backend.prepare(locale: locale) { _ in }
                try await backend.start { chunk in
                    Task { @MainActor [self] in self.render(chunk) }
                }
                // Rebuild capture only if the engine now wants a different
                // format; normally it does not, and restarting it needlessly
                // would drop audio.
                if let fmt = await backend.inputFormat, fmt != captureFormat {
                    await capture.stop()
                    captureFormat = fmt
                    let activeBackend = backend
                    try await capture.start(
                        targetFormat: fmt,
                        onBuffer: { [activeBackend] buf in activeBackend.feed(buf) },
                        onState: { [weak self] st in
                            Task { @MainActor in self?.captureStateChanged(st) }
                        })
                }
                setStatus("Listening · \(Self.coverageNote())")
            } catch {
                setStatus("Could not switch language")
                NSLog("sAiity language switch failed: \(error.localizedDescription)")
            }
        }
    }

    private func stop() {
        Task { @MainActor in await stopAsync() }
    }

    /// The awaitable form. `stop()` deliberately returns immediately for the
    /// menu, but anything that needs the models actually released — deleting
    /// them, for one — has to be able to wait for the teardown.
    private func stopAsync() async {
        guard state != .stopping else { return }
        state = .stopping
        setStatus("Idle")

        // Cancel an in-flight start and WAIT for it. Cancellation alone is not
        // enough: the start Task may be suspended inside a model download, and
        // if we tore down here without waiting it would resume afterwards and
        // bring the audio stream up behind our back — capture running with the
        // menu reading "Start captions".
        sessionTask?.cancel()
        await sessionTask?.value
        sessionTask = nil

        await capture.stop()
        await backend.stop()
        await activeTranslator?.stop()
        translatorReady = false
        await endRecording()
        overlay.clear()
        state = .idle
    }

    /// Stop and drop every loaded model, so their files can be removed for real.
    @MainActor
    private func releaseModels() async {
        await stopAsync()
        // Rebuild rather than reuse: a backend that has been stopped is not
        // guaranteed to restart cleanly, and this path is rare.
        backend = AppDelegate.makeActiveBackend()
        activeTranslator = TranslationEngine.current.makeTranslator()
        translatorReady = false
    }

    /// Silence is not the same as a broken pipeline, and the UI must not let the
    /// two look alike. With nothing playing, capture keeps running perfectly and
    /// delivers pure zeros forever; if the buffers themselves stop, the stream
    /// died and that is a real error.
    @MainActor
    private func captureStateChanged(_ audio: SystemAudioCapture.State) {
        // Named `audio` rather than `state` so it cannot be confused with the
        // session state below — they mean very different things, and the
        // original shadowing hid which one this guard was testing.
        guard state == .running else { return }
        if TestHooks.verboseLogging {
            NSLog("sAiity capture state: \(audio)")
        }
        let tag = locale.identifier(.bcp47)
        switch audio {
        case .audible:
            setStatus("Listening · \(tag)")
        case .silent:
            // Utterance boundary: commit the volatile tail so it reaches the
            // transcript and the translator.
            Task { await backend.flushPending() }
            setStatus("Listening · nothing is playing")
            if !showedAnyCaption { overlay.show(text: "nothing is playing", isFinal: false) }
        case .stalled:
            setStatus("Audio stream stopped — press Stop, then Start")
            overlay.show(text: "audio stream stopped", isFinal: true)
        }
    }

    /// Render the chunk as-is. Volatile results are *cumulative for the current
    /// utterance* — they grow from "Die" to the full sentence — so appending them
    /// to the previous final would print the sentence twice. The last final simply
    /// stays on screen until the next utterance's first volatile replaces it.
    @MainActor
    private func render(_ chunk: TranscriptChunk) {
        let text = chunk.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        // After committing a sentence the engine often emits a lone "." as the
        // start of the next one; showing that would blank the bar to a dot.
        guard text.rangeOfCharacter(from: .alphanumerics) != nil else { return }
        if TestHooks.verboseLogging {
            NSLog("sAiity chunk final=\(chunk.isFinal): \(text)")
        }
        showedAnyCaption = true
        if chunk.isFinal { lastFinalText = text } else { lastVolatileText = text }
        overlay.show(text: String(text.suffix(220)), isFinal: chunk.isFinal)

        guard chunk.isFinal else { return }

        // Detection runs on the ACCUMULATED transcript, never a single line:
        // one-word lines are noise ("Ja." reads as Finnish, "Okay." as English).
        if let changed = detector.add(text) {
            if TestHooks.verboseLogging {
                NSLog("sAiity detected language: \(changed)")
            }
            detectedLanguage = changed
            languageDetected(changed)
        } else if detectedLanguage == nil {
            // The text detector needs 60 characters and two agreeing readings.
            // Nemotron identifies the language from the audio itself and has an
            // answer within a couple of seconds, which is the difference between
            // warning about a wrong engine now and warning about it a paragraph
            // from now. It latches once per session, so the text detector still
            // owns any later switch.
            Task { @MainActor [weak self] in
                guard let self, self.detectedLanguage == nil,
                      let audio = await self.backend.detectedLanguage() else { return }
                let code = audio.split(separator: "-").first.map(String.init) ?? audio
                self.detectedLanguage = code
                self.languageDetected(code)
            }
        }

        // Skip translation when the line is already in the target language —
        // cheaper than asking any engine, and it silences both Apple's
        // "cannot translate this pair" and an LLM's temptation to paraphrase.
        // Applies to every engine, which is why it lives here.
        if chunk.isFinal, let target = translateTo, text.count >= 12 {
            let r = NLLanguageRecognizer()
            r.processString(text)
            if let lang = r.dominantLanguage?.rawValue.split(separator: "-").first,
               let want = target.split(separator: "-").first,
               lang == want {
                return
            }
        }

        // Translate only committed lines: partial phrases translate badly, and
        // re-translating every volatile update would be wasteful. The source is
        // the DETECTED language when we have one — the selected locale is only a
        // decoding hint and may not be what is actually being spoken.
        let srcCode = detectedLanguage ?? locale.identifier(.bcp47)
        Task { @MainActor in
            var translated: String?
            if let target = translateTo, let engine = activeTranslator,
               let out = await engine.translate(text, from: srcCode, to: target) {
                if TestHooks.verboseLogging {
                    NSLog("sAiity translated [\(TranslationEngine.current.rawValue)]: \(out)")
                }
                translated = out
                overlay.showTranslation(out)
            }
            // Only finals are stored: volatile results are cumulative since the
            // last final, so persisting them would duplicate whole paragraphs.
            sessionLines.append(Segment(i: sessionLines.count, t0: chunk.start, t1: chunk.end,
                                        text: text, loc: locale.identifier(.bcp47),
                                        tr: translated, trLoc: translateTo,
                                        words: chunk.words.isEmpty ? nil : chunk.words))
            if await TranscriptStore.shared.isRecording {
                await TranscriptStore.shared.append(chunk, locale: locale.identifier(.bcp47),
                                                    translation: translated,
                                                    translateTo: translateTo)
                recordedLines += 1
            }
        }
    }
}
