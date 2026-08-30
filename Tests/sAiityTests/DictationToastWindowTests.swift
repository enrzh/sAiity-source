import AppKit
import Testing

@testable import sAiity

@MainActor
@Suite struct DictationToastWindowTests {
    @Test("real drag updates and persists the borderless panel frame")
    func realDragPersistsFrame() {
        let window = makeWindow()
        window.setFrame(NSRect(x: 200, y: 220, width: 240, height: 36), display: false)
        window.orderFrontRegardless()
        let number = window.windowNumber
        let down = NSEvent.mouseEvent(with: .leftMouseDown, location: NSPoint(x: 210, y: 230), modifierFlags: [], timestamp: 0, windowNumber: number, context: nil, eventNumber: 1, clickCount: 1, pressure: 1)!
        let move = NSEvent.mouseEvent(with: .leftMouseDragged, location: NSPoint(x: 260, y: 280), modifierFlags: [], timestamp: 0, windowNumber: number, context: nil, eventNumber: 2, clickCount: 1, pressure: 1)!
        let up = NSEvent.mouseEvent(with: .leftMouseUp, location: NSPoint(x: 260, y: 280), modifierFlags: [], timestamp: 0, windowNumber: number, context: nil, eventNumber: 3, clickCount: 1, pressure: 1)!
        window.mouseDown(with: down)
        window.mouseDragged(with: move)
        window.mouseUp(with: up)
        #expect(window.frame.origin == NSPoint(x: 250, y: 270))
        #expect(FrameStore.loadDictation() == window.frame)
        window.dismiss()
    }

    @Test("reset button invokes the production callback")
    func resetButtonUsesCallback() {
        let window = makeWindow()
        var called = false
        window.onResetPosition = { called = true }
        window.performResetButtonAction()
        #expect(called)
    }

    @Test("toast remains nonactivating and has a stable accessibility label")
    func nonactivatingAccessibility() {
        let window = makeWindow()
        #expect(window.styleMask.contains(.nonactivatingPanel))
        #expect(!window.canBecomeKey)
        #expect(!window.canBecomeMain)
        window.show(phase: .cleaning)
        #expect(window.accessibilityRole() == .status)
        #expect(window.accessibilityLabel() == "Dictation")
        window.dismiss()
    }

    @Test("saved toast frames restore and clamp through the window seam")
    func restoresSavedFrame() {
        FrameStore.resetDictation()
        FrameStore.saveDictation(NSRect(x: 5000, y: 5000, width: 240, height: 36))
        let window = makeWindow()
        #expect(window.frame.width == 240)
        #expect(window.frame.maxX <= (NSScreen.main?.visibleFrame.maxX ?? .greatestFiniteMagnitude))
        FrameStore.resetDictation()
        window.dismiss()
    }

    @Test("accessibility preferences are injectable and update surfaces")
    func accessibilityPreferences() {
        DictationToastWindow.accessibilityPreferences = { (true, true, true) }
        defer { DictationToastWindow.accessibilityPreferences = DictationToastWindow.systemAccessibilityPreferences }
        let window = makeWindow()
        window.show(phase: .cleaning)
        #expect(window.isOpaque)
        #expect(window.contentView?.layer?.borderWidth == 1)
        window.dismiss()
    }
    @Test("dictation toast persists its own frame key")
    func dictationFramePersistenceIsIndependent() {
        FrameStore.resetDictation()
        let frame = NSRect(x: 111, y: 222, width: 240, height: 36)
        FrameStore.saveDictation(frame)
        #expect(FrameStore.loadDictation() == frame)
        #expect(UserDefaults.standard.string(forKey: "captionFrame") == nil)
        FrameStore.resetDictation()
    }

    @Test("toast drag saves its frame and reset clears the production action")
    func dragSaveAndReset() {
        let window = makeWindow()
        window.setFrame(NSRect(x: 200, y: 220, width: 240, height: 36), display: false)
        window.saveDraggedFrame()
        #expect(FrameStore.loadDictation() == window.frame)
        window.resetPosition()
        #expect(FrameStore.loadDictation() == nil)
        window.dismiss()
    }

    @Test("announcements use the injected element and notification")
    func announcementSeam() {
        var received: (Any, NSAccessibility.Notification)?
        DictationToastWindow.postAccessibility = { received = ($0, $1) }
        defer { DictationToastWindow.postAccessibility = NSAccessibility.post(element:notification:) }
        let window = makeWindow()
        window.show(phase: .cleaning)
        #expect(received?.0 as AnyObject? === window)
        #expect(received?.1 == .announcementRequested)
        window.dismiss()
    }
    @Test("dictation phases map to stable accessible status values")
    func phasePresentationIsStable() {
        #expect(DictationPhase.waitingForInputMonitoring.toastPresentation.label == "Dictation")
        #expect(DictationPhase.preparing.toastPresentation.value == "Preparing")
        #expect(DictationPhase.dictating.toastPresentation.value == "Recording")
        #expect(DictationPhase.transcribing.toastPresentation.value == "Transcribing")
        #expect(DictationPhase.cleaning.toastPresentation.value == "Cleaning")
        #expect(DictationPhase.translating.toastPresentation.value == "Translating")
        #expect(DictationPhase.inserting.toastPresentation.value == "Inserting")
        #expect(DictationPhase.result("Done").toastPresentation.value == "Done")
        #expect(DictationPhase.limit.toastPresentation.value == "Limit reached")
        #expect(DictationPhase.failure("No model").toastPresentation.value == "No model")
        #expect(DictationPhase.recovery("Retry").toastPresentation.value == "Retry")
    }

    @Test("phase updates do not reposition the toast")
    func phaseUpdatesPreserveFrame() {
        let window = makeWindow()
        window.setFrameOrigin(NSPoint(x: 321, y: 222))
        let frame = window.frame
        window.show(phase: .transcribing)
        #expect(window.frame == frame)
        window.dismiss()
    }

    @Test("toast exposes a stable status accessibility surface")
    func accessibilitySurface() {
        let window = makeWindow()
        window.show(phase: .cleaning)
        #expect(window.accessibilityRole() == .status)
        #expect(window.accessibilityLabel() == "Dictation")
        #expect((window.accessibilityValue() as? String) == "Cleaning")
        #expect(window.isAccessibilityEnabled())
        window.dismiss()
    }

    @Test("reset position action is exposed by the toast")
    func resetPositionAction() {
        let window = makeWindow()
        var called = false
        window.onResetPosition = { called = true }
        #expect(window.performResetPosition())
        #expect(called)
    }

    private func makeWindow() -> DictationToastWindow {
        DictationToastWindow(contentRect: .zero, styleMask: [.borderless],
                             backing: .buffered, defer: false)
    }

    @Test("initial dictation setup waits for the window server to settle")
    func initialSetupRunsAfterLaunchTurn() async {
        var events: [String] = []

        AppDelegate.scheduleAfterLaunch {
            events.append("dictation setup")
        }
        events.append("launch returned")

        #expect(events == ["launch returned"])
        try? await Task.sleep(for: .milliseconds(50))
        #expect(events == ["launch returned"])
        try? await Task.sleep(for: .milliseconds(300))
        #expect(events == ["launch returned", "dictation setup"])
    }

    @Test("dictation feedback stays above full-screen apps and across Spaces")
    func staysVisibleOutsideTheApp() {
        let window = DictationToastWindow(contentRect: .zero,
                                          styleMask: [.borderless],
                                          backing: .buffered,
                                          defer: false)

        #expect(window.level == .screenSaver)
        #expect(window.collectionBehavior.contains(.canJoinAllSpaces))
        #expect(window.collectionBehavior.contains(.fullScreenAuxiliary))
        #expect(window.hidesOnDeactivate == false)
        #expect(window.styleMask.contains(.nonactivatingPanel))
    }

    @Test("show raises a toast even when AppKit already reports it visible")
    func showRaisesAnAlreadyVisibleToast() {
        let window = DictationToastWindow(contentRect: NSRect(x: 40, y: 40, width: 240, height: 36),
                                          styleMask: [.borderless],
                                          backing: .buffered,
                                          defer: false)
        window.orderFrontRegardless()
        #expect(window.isVisible)

        window.show(text: "Ready to Dictate", animated: false)

        #expect(window.orderFrontCallsForTests == 1)

        window.orderOut(nil)
    }

    @Test("ready feedback stays visible until dictation starts")
    func readyFeedbackPersists() {
        #expect(!DictationPhase.ready.automaticallyDismissesToast)
        #expect(!DictationPhase.dictating.automaticallyDismissesToast)
        #expect(DictationPhase.result("Copied").automaticallyDismissesToast)
        #expect(DictationPhase.failure("Unavailable").automaticallyDismissesToast)
    }

    @Test("ready feedback fades away after its inactivity timeout")
    func readyFeedbackFadesAwayAfterInactivity() async {
        let window = DictationToastWindow(contentRect: .zero,
                                          styleMask: [.borderless],
                                          backing: .buffered,
                                          defer: false)

        window.show(text: "Ready to Dictate", animated: false,
                    autoDismissAfter: .milliseconds(20))
        #expect(window.isVisible)

        // The full Swift Testing run schedules all @MainActor suites together;
        // wait for the AppKit animation to complete instead of assuming a
        // fixed one-second turn is enough for its completion handler.
        for _ in 0..<40 where window.isVisible {
            try? await Task.sleep(for: .milliseconds(100))
        }
        #expect(!window.isVisible)
    }

    @Test("new dictation feedback cancels an older ready timeout")
    func newFeedbackCancelsOlderTimeout() async {
        let window = DictationToastWindow(contentRect: .zero,
                                          styleMask: [.borderless],
                                          backing: .buffered,
                                          defer: false)

        window.show(text: "Ready to Dictate", animated: false,
                    autoDismissAfter: .milliseconds(20))
        try? await Task.sleep(for: .milliseconds(100))
        window.show(text: "Dictating…", animated: true)

        try? await Task.sleep(for: .seconds(1))
        #expect(window.isVisible)
        #expect(window.alphaValue == 1)
        window.dismiss()
    }
}
