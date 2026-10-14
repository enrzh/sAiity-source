#if SAIITY_TEST_HOOKS
import AppKit
import Carbon.HIToolbox
import Foundation
import SwiftUI

/// Lets the app photograph its own settings window, one PNG per pane.
///
/// ## Why this exists
///
/// The GUI had never been looked at before design work started on it, and the
/// obvious route to seeing it is blocked: `screencapture` needs Screen
/// Recording permission, which belongs to whichever process is running the
/// tests. Granting that to a terminal does not help an agent whose commands run
/// from somewhere else entirely, and the grant is also cached per process, so it
/// needs a restart to take effect. That is a lot of ceremony for a screenshot.
///
/// An app can always capture its own windows — no TCC involvement at all — so
/// the app does it to itself. Offscreen `ImageRenderer` is the other option and
/// it does not work here: it renders a trivial view fine, but every settings
/// pane comes back as SwiftUI's "view not supported in this context" placeholder
/// (`RendererCapabilityTests` pins that down). A real laid-out `NSWindow` is
/// what the content actually needs.
///
/// ## Scope and honesty
///
/// This captures the window's **content view**, not the full window frame, so the
/// titlebar and traffic lights are not in the output. Every design decision
/// under review lives in the content.
///
/// ### What it cannot show
///
/// **A prominent button's accent fill.** `.buttonStyle(.borderedProminent)`
/// captures as an unaccented grey capsule, so a capture makes the app's primary
/// action look like the quietest control on the pane. Proved by tinting the
/// button `.red` and getting an identical grey — the fill is not composited, so
/// this is a limit of `cacheDisplay`, not a defect in the app. Anything drawn as
/// a material or effect view is affected; plain layer content, including the
/// accent-coloured shortcut-recorder text, captures correctly.
///
/// Check a primary action by running the app. Do not conclude from a capture that
/// it is quiet.
///
/// Compiled out of a release build by `SAIITY_TEST_HOOKS`, like every other hook.
///
/// Usage:
///
///   SAIITY_CAPTURE_DIR=/tmp/shots ./sAiity.app/Contents/MacOS/sAiity
enum SelfCapture {
    /// Where the PNGs go. Nil disables the whole facility.
    static var directory: URL? {
        ProcessInfo.processInfo.environment["SAIITY_CAPTURE_DIR"]
            .map { URL(fileURLWithPath: $0, isDirectory: true) }
    }

    /// Walk every pane, let it lay out, photograph it, then quit.
    ///
    /// Runs on the main actor and drives the run loop between panes on purpose:
    /// `cacheDisplay(in:to:)` renders whatever is currently laid out, so asking
    /// for pixels before the hosting view has settled photographs an empty
    /// rectangle rather than a slow one.
    @MainActor
    static func runAfterLaunch() {
        guard let directory else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let everyday = ProcessInfo.processInfo.environment["SAIITY_CAPTURE_EVERYDAY"] == "1"
        let trials = ProcessInfo.processInfo.environment["SAIITY_CAPTURE_TRIALS"] == "1"
        if ProcessInfo.processInfo.environment["SAIITY_CAPTURE_SHORTCUTS"] == "1" {
            Task { await verifyShortcutInput() }
            return
        }
        if ProcessInfo.processInfo.environment["SAIITY_CAPTURE_FOCUS"] == "1" {
            Task { await verifyFeedbackFocus() }
            return
        }
        if ProcessInfo.processInfo.environment["SAIITY_CAPTURE_HOLD"] == "1" {
            SettingsWindowController.selectedPane = .transcripts
            SettingsWindowController.show()
            return
        }
        // Keep the existing pre-launch library-routing flag enabled for an
        // everyday capture too; it need not open the transcript fixture views.
        if ProcessInfo.processInfo.environment["SAIITY_CAPTURE_TRANSCRIPTS"] == "1", !everyday {
            Task {
                await captureTranscripts(into: directory)
                exit(EXIT_SUCCESS)
            }
            return
        }

        // Focus the everyday-layout pass without opening onboarding or writing
        // sample preferences. The caller must use an isolated preview bundle
        // domain and library, just as for other SelfCapture runs.
        let panes: [SettingsPane] = trials ? [] : everyday ? [.captions, .dictation] : SettingsPane.allCases
        for pane in panes {
            // Post the navigation notification rather than only assigning
            // `SettingsWindowController.selectedPane`. That property is read once,
            // when the root view is constructed, and the window is created on the
            // first `show()` — so assigning it afterwards leaves the already-built
            // view showing whichever pane happened to be first, and every capture
            // comes back byte-identical. The notification is the path the real UI
            // uses and it updates the live selection binding.
            SettingsWindowController.selectedPane = pane
            NotificationCenter.default.post(name: .saiitySelectSettingsPane, object: pane.rawValue)
            SettingsWindowController.show()
            // `show()` kicks off `Task { await state.refresh() }`, which walks the
            // model registry and stats every installed directory. Too short a wait
            // photographs the page *before* that lands — which looks exactly like an
            // empty Models page and is not one. Overridable so the wait can be
            // tuned without a rebuild.
            let settle = ProcessInfo.processInfo.environment["SAIITY_CAPTURE_SETTLE"]
                .flatMap(Double.init) ?? 1.5
            RunLoop.main.run(until: Date().addingTimeInterval(settle))
            captureWindow(named: pane.rawValue, into: directory)
            if everyday, let window = settingsWindow {
                for width in [760, 860, 980] {
                    window.setContentSize(NSSize(width: width, height: 760))
                    RunLoop.main.run(until: Date().addingTimeInterval(0.3))
                    captureWindow(named: "\(pane.rawValue)-\(width)", into: directory)
                }
            }
        }
        if everyday, !trials { exit(EXIT_SUCCESS) }
        for useCase in OnboardingModel.UseCase.allCases {
            let model = OnboardingModel(state: SettingsWindowController.state)
            model.useCase = useCase
            model.step = .finish
            model.trialStatus = "Setup trial preview"
            model.trialText = "Das ist ein Test and this result stays in the setup window."
            if useCase.includesDictation {
                model.trial = .dictation
                model.trialMicrophoneName = "Synthetic microphone"
                model.trialInputHealth = .init(sampleCount: 48_000, rmsDBFS: -60,
                                              clippedSampleFraction: 0, observedDuration: 3)
            }
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 600),
                                  styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.makeOpaqueSettingsSurface()
            window.contentViewController = NSHostingController(rootView: OnboardingView(model: model, onFinish: {}))
            window.center()
            window.orderFront(nil)
            RunLoop.main.run(until: Date().addingTimeInterval(0.5))
            captureWindow(named: "onboarding-\(useCase.rawValue)", into: directory, window: window)
            window.close()
        }
        let state = SettingsWindowController.state
        SettingsWindowController.selectedPane = .dictation
        NotificationCenter.default.post(name: .saiitySelectSettingsPane, object: SettingsPane.dictation.rawValue)
        SettingsWindowController.show()
        state.recentDictations = [.init(id: UUID(), completedAt: Date(),
            result: .init(rawText: "待って！ Café e\u{301} — العربية עברית ไทย हिन्दी 2026-10-09 −1,234",
                          outputText: "Wait! Café e\u{301} — العربية עברית ไทย हिन्दी 2026-10-09 −1,234",
                          wasCleaned: false, wasTranslated: true),
            delivery: .init(outcome: .copied))]
        state.showsRecentDictations = true
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        if let sheet = settingsWindow?.attachedSheet {
            captureWindow(named: "recent-dictations", into: directory, window: sheet)
            settingsWindow?.endSheet(sheet)
        }
        for width in [480, 640] {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 560),
                                  styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentViewController = NSHostingController(rootView: ScrollView {
                VocabularyEditor().padding(24)
            }.frame(width: CGFloat(width), height: 560))
            window.orderFront(nil)
            RunLoop.main.run(until: Date().addingTimeInterval(0.3))
            captureWindow(named: "vocabulary-\(width)", into: directory, window: window)
            window.close()
        }
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        // `NSApp.terminate` is deferred when called from inside a run loop, which
        // is where this runs, so the process would linger as a menu-bar app. This
        // is a capture tool: leave immediately and let the caller read the files.
        exit(EXIT_SUCCESS)
    }

    /// Synthetic spoken lines in a disposable library; never read or mutate a
    /// user's sessions, install a model, or run inference for a layout check.
    @MainActor
    private static func captureTranscripts(into directory: URL) async {
        let library = directory.appendingPathComponent("fixture-sessions", isDirectory: true)
        try? FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)
        var lines = ["We agreed to ship on Friday.", "Can you bitte die Rechnung öffnen?", "Send the notes after the meeting."]
        lines += (3..<80).map { "Synthetic transcript line \($0)." }
        lines.append("Late match — 待って！ ｶﾀｶﾅ Café e\u{301} العربية עברית ไทย हिन्दी 2026-10-09 −1,234")
        let segments = lines.enumerated().map { index, text in
            Segment(i: index, t0: Double(index * 5), t1: Double(index * 5 + 4), text: text,
                    loc: "en", tr: nil, trLoc: nil, words: nil)
        }
        guard let session = try? TranscriptStore.saveSession(segments, locale: "en", translateTo: nil),
              let _ = try? TranscriptStore.saveSession(segments, locale: "de", translateTo: nil) else { return }
        try? await TranscriptStore.shared.renameSession(session, title: "製品レビュー — Café 👩🏽‍💻")
        let summary = TranscriptSummary(recap: "The team agreed to ship Friday and share the notes.",
                                        decisions: ["Ship on Friday."], actions: ["Send the meeting notes."],
                                        omittedLineCount: 0, createdAt: Date())
        try? TranscriptSummaryStore.write(summary, to: session)
        SettingsWindowController.selectedPane = .transcripts
        NotificationCenter.default.post(name: .saiitySelectSettingsPane, object: SettingsPane.transcripts.rawValue)
        SettingsWindowController.show()
        await SettingsWindowController.state.refreshLibraryAsync(force: true)
        try? await Task.sleep(for: .seconds(1))
        captureWindow(named: "transcripts", into: directory)

        let displayedSession = SettingsWindowController.state.sessions.first(where: { $0.id == session.id }) ?? session
        for variant in ["summary", "missing-model", "progress", "failure", "search-match"] {
            if variant == "missing-model" { try? TranscriptSummaryStore.remove(session) }
            else { try? TranscriptSummaryStore.write(summary, to: session) }
            let progress = variant == "progress" ? TranscriptSummarizer.Progress(done: 2, total: 3, note: "Summarizing…") : nil
            let viewer = TranscriptViewerSheet(
                session: displayedSession, summaryProgress: progress, isSummarizing: progress != nil,
                summaryFailure: variant == "failure" ? String(localized: "The summary did not finish. The transcript is unchanged.") : nil,
                modelAvailable: variant != "missing-model", summaryUnavailable: progress != nil,
                onSummarize: {}, onCancel: {}, onRemove: {}, onShowDictation: {},
                initialSegmentIndex: variant == "search-match" ? 80 : nil)
            let parent = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 860, height: 760),
                                  styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            parent.isReleasedWhenClosed = false
            parent.contentViewController = NSHostingController(rootView:
                Text(verbatim: "Transcript layout preview").sheet(isPresented: .constant(true)) { viewer })
            parent.orderFront(nil)
            try? await Task.sleep(for: .milliseconds(600))
            if let sheet = parent.attachedSheet {
                guard sheet.styleMask.contains(.resizable) else {
                    NSLog("SelfCapture: FAILED — transcript sheet is not resizable")
                    exit(EXIT_FAILURE)
                }
                NSLog("SelfCapture: transcript sheet resizable=%@ size=%@ min=%@ max=%@",
                      sheet.styleMask.contains(.resizable) ? "yes" : "no", NSStringFromSize(sheet.contentView?.bounds.size ?? .zero),
                      NSStringFromSize(sheet.contentMinSize), NSStringFromSize(sheet.contentMaxSize))
                captureWindow(named: "transcript-\(variant)", into: directory, window: sheet)
                sheet.setContentSize(NSSize(width: 560, height: 480))
                try? await Task.sleep(for: .milliseconds(200))
                captureWindow(named: "transcript-\(variant)-compact", into: directory, window: sheet)
                sheet.setContentSize(NSSize(width: 820, height: 800))
                try? await Task.sleep(for: .milliseconds(200))
                guard let size = sheet.contentView?.bounds.size,
                      abs(size.width - 820) < 1, abs(size.height - 800) < 1 else {
                    NSLog("SelfCapture: FAILED — transcript sheet did not expand")
                    exit(EXIT_FAILURE)
                }
                captureWindow(named: "transcript-\(variant)-large", into: directory, window: sheet)
                parent.endSheet(sheet)
            } else {
                NSLog("SelfCapture: FAILED — transcript sheet did not open")
                exit(EXIT_FAILURE)
            }
            parent.close()
        }
    }

    @MainActor
    private static func verifyShortcutInput() async {
        let app = NSApplication.shared
        _ = app.setActivationPolicy(.regular)
        let state = SettingsWindowController.state
        let window = NSWindow(contentRect: NSRect(x: 80, y: 80, width: 420, height: 180),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Synthetic shortcut input check"
        window.contentView = NSHostingView(rootView: VStack(spacing: 24) {
            ShortcutRecorder(action: .copyLastLine, state: state)
            DictationShortcutRecorder(state: state)
        }.padding(24))
        app.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        for _ in 0..<40 where !app.isActive || !window.isKeyWindow {
            try? await Task.sleep(for: .milliseconds(25))
            if app.isActive { window.makeKeyAndOrderFront(nil) }
        }
        guard app.isActive, window.isKeyWindow, let content = window.contentView else {
            NSLog("SAIITY_SHORTCUT_PROOF SETUP_FAILED")
            exit(EXIT_FAILURE)
        }
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        let views = descendants(content)
        guard let captions = views.compactMap({ $0 as? ShortcutRecorder.RecorderView }).first,
              let dictation = views.compactMap({ $0 as? DictationShortcutRecorder.RecorderView }).first else {
            NSLog("SAIITY_SHORTCUT_PROOF SETUP_FAILED missing native recorders")
            exit(EXIT_FAILURE)
        }
        var failures = 0
        func check(_ passed: Bool, _ name: String) {
            NSLog("SAIITY_SHORTCUT_PROOF %@ %@", passed ? "PASS" : "FAIL", name)
            if !passed { failures += 1 }
        }
        func click(_ view: NSView) async {
            let point = view.convert(NSPoint(x: view.bounds.midX, y: view.bounds.midY), to: nil)
            for type: NSEvent.EventType in [.leftMouseDown, .leftMouseUp] {
                if let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                                                 timestamp: ProcessInfo.processInfo.systemUptime,
                                                 windowNumber: window.windowNumber, context: nil,
                                                 eventNumber: 0, clickCount: 1, pressure: 1) {
                    app.postEvent(event, atStart: false)
                }
                try? await Task.sleep(for: .milliseconds(80))
            }
            NSLog("SAIITY_SHORTCUT_PROOF responder=%@", String(describing: window.firstResponder.map { type(of: $0) }))
        }
        func key(_ type: NSEvent.EventType, _ code: Int, _ flags: NSEvent.ModifierFlags) async {
            if let event = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: flags,
                                           timestamp: ProcessInfo.processInfo.systemUptime,
                                           windowNumber: window.windowNumber, context: nil,
                                           characters: "k", charactersIgnoringModifiers: "k", isARepeat: false,
                                           keyCode: UInt16(code)) {
                app.postEvent(event, atStart: false)
            }
            try? await Task.sleep(for: .milliseconds(80))
        }
        await click(captions)
        check(captions.accessibilityValue() as? String == String(localized: "Press keys…"), "mouse arms hosted caption recorder")
        await key(.flagsChanged, kVK_Command, .command)
        await key(.keyDown, kVK_ANSI_K, .command)
        await key(.keyUp, kVK_ANSI_K, .command)
        await key(.flagsChanged, kVK_Command, [])
        check(HotKeyCenter.shortcut(for: .copyLastLine) == Shortcut(keyCode: UInt32(kVK_ANSI_K), modifiers: UInt32(cmdKey)),
              "application event loop records and persists caption Command chord")
        await click(dictation)
        check(dictation.accessibilityValue() as? String == String(localized: "Press the full chord, then release…"), "mouse arms hosted dictation recorder")
        await key(.flagsChanged, kVK_Command, .command)
        await key(.keyDown, kVK_ANSI_K, .command)
        await key(.keyUp, kVK_ANSI_K, .command)
        await key(.flagsChanged, kVK_Command, [])
        check(state.dictationChord == DictationChord(keyCodes: [UInt16(kVK_Command), UInt16(kVK_ANSI_K)]),
              "application event loop records and persists full dictation Command chord")
        window.orderOut(nil)
        NSLog("SAIITY_SHORTCUT_PROOF finished failures=%d", failures)
        exit(failures == 0 ? EXIT_SUCCESS : EXIT_FAILURE)
    }

    @MainActor
    private static func verifyFeedbackFocus() async {
        let app = NSApplication.shared
        _ = app.setActivationPolicy(.regular)
        let peer = NSWindow(contentRect: NSRect(x: 60, y: 60, width: 300, height: 120),
                            styleMask: [.titled], backing: .buffered, defer: false)
        peer.title = "Synthetic focus peer"
        app.activate(ignoringOtherApps: true)
        peer.makeKeyAndOrderFront(nil)
        for _ in 0..<40 where !app.isActive || !peer.isKeyWindow {
            try? await Task.sleep(for: .milliseconds(25))
            if app.isActive { peer.makeKeyAndOrderFront(nil) }
        }
        guard app.isActive, peer.isKeyWindow else {
            NSLog("SAIITY_FOCUS_PROOF SETUP_FAILED active=%@ peerKey=%@", app.isActive.description, peer.isKeyWindow.description)
            exit(EXIT_FAILURE)
        }
        let preferences = DictationToastWindow.accessibilityPreferences
        DictationToastWindow.accessibilityPreferences = { (true, false, false) }
        let toast = DictationToastWindow(contentRect: .zero, styleMask: [.borderless], backing: .buffered, defer: false)
        var failures = 0
        let check: (Bool, String) -> Void = { passed, name in
            NSLog("SAIITY_FOCUS_PROOF %@ %@", passed ? "PASS" : "FAIL", name)
            if !passed { failures += 1 }
        }
        toast.show(phase: .dictating)
        check(!toast.canBecomeKey && !toast.isKeyWindow && peer.isKeyWindow, "recording preserves target focus")
        toast.show(resultText: "Synthetic live draft", autoDismissAfter: nil, allowsKeyboardFocus: false)
        check(!toast.canBecomeKey && !toast.isKeyWindow && peer.isKeyWindow, "live draft preserves target focus")
        toast.show(resultText: "Synthetic completed result", autoDismissAfter: nil)
        toast.stopArmingTickForTests()
        check(peer.isKeyWindow && !toast.isKeyWindow, "result presentation preserves target focus")
        let text = toast.resultTextViewForTests
        _ = toast.makeFirstResponder(text)
        text.setSelectedRange(NSRange(location: 0, length: 0))
        toast.setAccessibilityFocused(false)
        text.setAccessibilityFocused(false)
        toast.updateMouseArming(atContentPoint: NSPoint(x: -1_000, y: -1_000))
        check(!toast.isInteractingWithFeedback, "stored responder allows idle dismissal")
        check(toast.canBecomeKey, "completed result permits intentional keyboard focus")
        toast.makeKeyAndOrderFront(nil)
        check(toast.isKeyWindow && toast.isInteractingWithFeedback, "real keyboard focus protects result")
        peer.makeKeyAndOrderFront(nil)
        check(peer.isKeyWindow && !toast.isInteractingWithFeedback, "focus leaving resumes idle")
        toast.setAccessibilityFocused(true)
        check(toast.isInteractingWithFeedback, "accessibility focus protects non-key result")
        toast.setAccessibilityFocused(false)
        check(!toast.isInteractingWithFeedback, "accessibility focus leaving resumes idle")
        toast.show(phase: .dictating)
        check(!toast.canBecomeKey && peer.isKeyWindow, "new recording preserves target focus")
        toast.dismiss()
        peer.orderOut(nil)
        DictationToastWindow.accessibilityPreferences = preferences
        NSLog("SAIITY_FOCUS_PROOF finished failures=%d", failures)
        exit(failures == 0 ? EXIT_SUCCESS : EXIT_FAILURE)
    }

    /// The settings window, found through the app's own window list.
    ///
    /// `SettingsWindowController.window` is private, and this does not need it
    /// widened: the controller stamps every settings window with a stable
    /// identifier, so the window is findable without touching its access level.
    private static var settingsWindow: NSWindow? {
        NSApp.windows.first {
            $0.identifier == SettingsWindowController.settingsWindowIdentifier
        }
    }

    @MainActor
    private static func captureWindow(named name: String, into directory: URL, window: NSWindow? = nil) {
        guard let view = (window ?? settingsWindow)?.contentView else {
            NSLog("SelfCapture: no settings content view for \(name)")
            return
        }
        view.layoutSubtreeIfNeeded()
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
            NSLog("SelfCapture: could not make a bitmap for \(name)")
            return
        }
        view.cacheDisplay(in: view.bounds, to: rep)
        guard let png = rep.representation(using: .png, properties: [:]) else {
            NSLog("SelfCapture: no PNG for \(name)")
            return
        }
        let url = directory.appendingPathComponent("settings-\(name).png")
        do {
            try png.write(to: url)
            NSLog("SelfCapture: wrote \(url.path) (\(png.count) bytes, \(rep.pixelsWide)x\(rep.pixelsHigh))")
        } catch {
            NSLog("SelfCapture: could not write \(url.path): \(error.localizedDescription)")
        }
    }
}
#endif
