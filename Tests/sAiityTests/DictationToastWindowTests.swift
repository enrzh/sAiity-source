import AppKit
import Testing

@testable import sAiity

@MainActor
@Suite struct DictationToastWindowTests {
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
