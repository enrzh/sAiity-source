import AppKit
import Testing

@testable import sAiity

@MainActor
@Suite(.serialized) struct DictationToastWindowTests {
    @Test func firstShowUsesActiveScreenWithoutSavedFrame() {
        FrameStore.resetDictation()
        DictationToastWindow.visibleFramesForTests = { [NSRect(x: 0, y: 0, width: 800, height: 600)] }
        DictationToastWindow.activeFrameForTests = { NSRect(x: 700, y: 500, width: 1, height: 1) }
        defer { DictationToastWindow.visibleFramesForTests = nil; DictationToastWindow.activeFrameForTests = nil }
        let window = makeWindow(); window.show(phase: .ready)
        #expect(window.frame.midX > 350); window.dismiss()
    }

    @Test func firstShowPlacesAnAppKitSizedWindowOnTheActiveScreen() {
        FrameStore.resetDictation()
        DictationToastWindow.visibleFramesForTests = { [NSRect(x: 0, y: 0, width: 800, height: 600)] }
        DictationToastWindow.activeFrameForTests = { NSRect(x: 700, y: 500, width: 1, height: 1) }
        defer { DictationToastWindow.visibleFramesForTests = nil; DictationToastWindow.activeFrameForTests = nil }
        let window = makeWindow()
        window.setFrame(NSRect(x: 0, y: 700, width: 179, height: 16), display: false)

        window.show(phase: .ready)

        #expect(window.frame.midX > 350)
        #expect(window.frame.maxY <= 600)
        window.dismiss()
    }

    @Test func firstShowPlacesAPartiallyOffscreenWindowOnTheActiveScreen() {
        FrameStore.resetDictation()
        DictationToastWindow.visibleFramesForTests = { [NSRect(x: 0, y: 0, width: 800, height: 600)] }
        DictationToastWindow.activeFrameForTests = { NSRect(x: 700, y: 500, width: 1, height: 1) }
        defer { DictationToastWindow.visibleFramesForTests = nil; DictationToastWindow.activeFrameForTests = nil }
        let window = makeWindow()
        window.setFrame(NSRect(x: 700, y: 300, width: 179, height: 16), display: false)

        window.show(phase: .ready)

        #expect(window.frame.maxX <= 800)
        window.dismiss()
    }

    @Test func savedFramePrefersItsExistingScreen() {
        FrameStore.resetDictation(); let saved = NSRect(x: 100, y: 120, width: 240, height: 36)
        FrameStore.saveDictation(saved); let window = makeWindow()
        #expect(window.frame.origin == saved.origin); window.dismiss(); FrameStore.resetDictation()
    }

    @Test func missingSavedScreenFallsBackAndClampsToActiveScreen() {
        FrameStore.resetDictation(); FrameStore.saveDictation(NSRect(x: 5000, y: 5000, width: 240, height: 36))
        DictationToastWindow.visibleFramesForTests = { [NSRect(x: 0, y: 0, width: 800, height: 600)] }
        DictationToastWindow.activeFrameForTests = { NSRect(x: 700, y: 500, width: 1, height: 1) }
        defer { DictationToastWindow.visibleFramesForTests = nil; DictationToastWindow.activeFrameForTests = nil; FrameStore.resetDictation() }
        let window = makeWindow(); #expect(window.frame.maxX <= 800 && window.frame.maxY <= 600); window.dismiss()
    }

    @Test func reduceMotionDirectDismissesWithoutAnimation() async {
        DictationToastWindow.accessibilityPreferences = { (true, false, false) }
        defer { DictationToastWindow.accessibilityPreferences = DictationToastWindow.systemAccessibilityPreferences }
        let window = makeWindow(); window.show(text: "Ready", animated: false, autoDismissAfter: .milliseconds(1))
        try? await Task.sleep(for: .milliseconds(200)); #expect(!window.isVisible)
    }

    @Test func reduceTransparencyOnOff() {
        DictationToastWindow.accessibilityPreferences = { (false, true, false) }
        let opaque = makeWindow(); opaque.show(text: "x", animated: false); #expect(opaque.isOpaque); opaque.dismiss()
        DictationToastWindow.accessibilityPreferences = { (false, false, false) }
        let clear = makeWindow(); clear.show(text: "x", animated: false); #expect(!clear.isOpaque); clear.dismiss()
        DictationToastWindow.accessibilityPreferences = DictationToastWindow.systemAccessibilityPreferences
    }

    @Test func increaseContrastOnOff() {
        DictationToastWindow.accessibilityPreferences = { (false, false, true) }
        let high = makeWindow(); high.show(text: "x", animated: false); #expect(high.contentView?.layer?.borderWidth == 1); high.dismiss()
        DictationToastWindow.accessibilityPreferences = { (false, false, false) }
        let normal = makeWindow(); normal.show(text: "x", animated: false); #expect(normal.contentView?.layer?.borderWidth == 0); normal.dismiss()
        DictationToastWindow.accessibilityPreferences = DictationToastWindow.systemAccessibilityPreferences
    }

    @Test func resetEventUsesActualButtonBoundsAndInvokesOnce() {
        FrameStore.saveDictation(NSRect(x: 200, y: 200, width: 240, height: 36)); let window = makeWindow(); window.orderFrontRegardless()
        window.onResetPosition = { window.resetPosition() }
        let b = window.resetButtonBoundsForTests; let p = NSPoint(x: b.midX, y: b.midY)
        let e = NSEvent.mouseEvent(with: .leftMouseDown, location: p, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1)!
        let u = NSEvent.mouseEvent(with: .leftMouseUp, location: p, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 2, clickCount: 1, pressure: 1)!
        window.sendEvent(e); window.sendEvent(u); #expect(window.resetCallbackCountForTests == 1); #expect(FrameStore.loadDictation() == nil); window.dismiss()
    }

    @Test func appDelegateBindingResetsToastThroughActualAction() {
        FrameStore.saveDictation(NSRect(x: 200, y: 200, width: 240, height: 36))
        let delegate = AppDelegate(); let window = delegate.dictationToastForTests
        window.orderFrontRegardless(); let b = window.resetButtonBoundsForTests
        let p = NSPoint(x: b.midX, y: b.midY)
        let e = NSEvent.mouseEvent(with: .leftMouseDown, location: p, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 3, clickCount: 1, pressure: 1)!
        let u = NSEvent.mouseEvent(with: .leftMouseUp, location: p, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 4, clickCount: 1, pressure: 1)!
        window.sendEvent(e); window.sendEvent(u)
        #expect(FrameStore.loadDictation() == nil); window.dismiss()
    }

    @Test func phaseChangesPreserveExactCallerFrame() {
        let window = makeWindow(); let frame = NSRect(x: 31, y: 42, width: 320, height: 80)
        window.setFrame(frame, display: false); window.show(phase: .preparing); #expect(window.frame == frame)
        window.show(phase: .transcribing); #expect(window.frame == frame); window.dismiss()
    }

    @Test func dragSavesClampedFrameExactlyOnce() {
        var saveCount = 0
        DictationToastWindow.saveDictationForTests = { _ in saveCount += 1 }
        defer { DictationToastWindow.saveDictationForTests = nil }
        let window = makeWindow(); window.setFrame(NSRect(x: 200, y: 200, width: 240, height: 36), display: false)
        window.beginDrag(atScreenPoint: NSPoint(x: 10, y: 10)); window.drag(toScreenPoint: NSPoint(x: 5000, y: 5000)); window.endDrag()
        #expect(saveCount == 1); #expect(FrameStore.loadDictation() == window.frame); window.dismiss()
    }

    @Test func dragTracksConsecutiveScreenPointerMovement() {
        let window = makeWindow()
        window.setFrame(NSRect(x: 200, y: 200, width: 240, height: 36), display: false)

        window.beginDrag(atScreenPoint: NSPoint(x: 300, y: 300))
        window.drag(toScreenPoint: NSPoint(x: 320, y: 310))
        #expect(window.frame.origin == NSPoint(x: 220, y: 210))
        window.drag(toScreenPoint: NSPoint(x: 340, y: 320))

        #expect(window.frame.origin == NSPoint(x: 240, y: 220))
        window.endDrag()
        window.dismiss()
    }

    @Test func readyLabelIsCenteredInTheCapsule() {
        let window = makeWindow()

        window.show(phase: .ready)

        #expect(abs(window.labelMidXForTests - window.contentMidXForTests) < 0.5)
        window.dismiss()
    }

    @Test func dragAndResetDoNotChangeKeyOrMainState() {
        let window = makeWindow(); window.setFrame(NSRect(x: 200, y: 200, width: 240, height: 36), display: false)
        let keyBefore = window.isKeyWindow; let mainBefore = window.isMainWindow
        window.beginDrag(atScreenPoint: NSPoint(x: 10, y: 10)); window.drag(toScreenPoint: NSPoint(x: 30, y: 30)); window.endDrag()
        window.onResetPosition = { window.resetPosition() }; window.performResetButtonAction()
        #expect(window.isKeyWindow == keyBefore); #expect(window.isMainWindow == mainBefore); window.dismiss()
    }
    @Test("real drag updates and persists the borderless panel frame")
    func realDragPersistsFrame() {
        let window = makeWindow()
        window.setFrame(NSRect(x: 200, y: 220, width: 240, height: 36), display: false)
        window.orderFrontRegardless()
        let number = window.windowNumber
        let down = NSEvent.mouseEvent(with: .leftMouseDown, location: NSPoint(x: 210, y: 230), modifierFlags: [], timestamp: 0, windowNumber: number, context: nil, eventNumber: 1, clickCount: 1, pressure: 1)!
        let move = NSEvent.mouseEvent(with: .leftMouseDragged, location: NSPoint(x: 260, y: 280), modifierFlags: [], timestamp: 0, windowNumber: number, context: nil, eventNumber: 2, clickCount: 1, pressure: 1)!
        let up = NSEvent.mouseEvent(with: .leftMouseUp, location: NSPoint(x: 260, y: 280), modifierFlags: [], timestamp: 0, windowNumber: number, context: nil, eventNumber: 3, clickCount: 1, pressure: 1)!
        window.sendEvent(down)
        window.sendEvent(move)
        window.sendEvent(up)
        #expect(window.frame.origin != NSPoint(x: 200, y: 220))
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

    @Test("dictating feedback uses a waveform instead of the phase text")
    func dictatingPhaseShowsWaveform() {
        let window = makeWindow()
        window.show(phase: .dictating)
        #expect(window.waveformVisibleForTests)
        window.show(phase: .transcribing)
        #expect(!window.waveformVisibleForTests)
        window.dismiss()
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

        // The callback is intentionally deferred, but a busy CI window server
        // can delay the main-actor task beyond the nominal 250 ms grace period.
        // Wait for the behavior with a bounded timeout instead of asserting a
        // precise wall-clock delivery time.
        for _ in 0..<20 where events.count == 1 {
            try? await Task.sleep(for: .milliseconds(50))
        }
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

    @Test("AppDelegate dismisses ready feedback after inactivity")
    func appDelegateDismissesReadyFeedbackAfterInactivity() async {
        let app = AppDelegate()
        app.updateDictationToastForTests(.ready)
        try? await Task.sleep(for: .seconds(6))
        #expect(!app.dictationToastForTests.isVisible)
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
