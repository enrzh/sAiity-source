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

    @Test("Liquid Glass is configurable on the dictation bubble")
    func liquidGlassStyle() {
        let defaults = UserDefaults.standard
        let previous = defaults.data(forKey: CaptionStyle.dictationKey)
        DictationToastWindow.accessibilityPreferences = { (false, false, false) }
        defer {
            if let previous { defaults.set(previous, forKey: CaptionStyle.dictationKey) }
            else { defaults.removeObject(forKey: CaptionStyle.dictationKey) }
            DictationToastWindow.accessibilityPreferences = DictationToastWindow.systemAccessibilityPreferences
        }

        var style = CaptionStyle.currentDictation
        style.glassStyle = CaptionStyle.liquidGlass
        CaptionStyle.currentDictation = style
        let window = makeWindow()
        #expect(window.renderedBubbleStyleForTests == CaptionStyle.liquidGlass)
        #expect(window.usesLiquidGlassForTests)
        window.dismiss()
    }

    @Test("Liquid Glass falls back to solid for reduced transparency")
    func liquidGlassAccessibilityFallback() {
        let defaults = UserDefaults.standard
        let previous = defaults.data(forKey: CaptionStyle.dictationKey)
        DictationToastWindow.accessibilityPreferences = { (false, true, false) }
        defer {
            if let previous { defaults.set(previous, forKey: CaptionStyle.dictationKey) }
            else { defaults.removeObject(forKey: CaptionStyle.dictationKey) }
            DictationToastWindow.accessibilityPreferences = DictationToastWindow.systemAccessibilityPreferences
        }

        var style = CaptionStyle.currentDictation
        style.glassStyle = CaptionStyle.liquidGlass
        CaptionStyle.currentDictation = style
        let window = makeWindow()
        #expect(window.renderedBubbleStyleForTests == CaptionStyle.solidGlass)
        #expect(!window.usesLiquidGlassForTests)
        window.dismiss()
    }

    @Test("dictation styling is independent and resizes the result bubble")
    func dictationStyleIsIndependentAndLive() async {
        let defaults = UserDefaults.standard
        let previousCaption = defaults.data(forKey: CaptionStyle.key)
        let previousDictation = defaults.data(forKey: CaptionStyle.dictationKey)
        // Restore through the setter, not by writing UserDefaults directly:
        // the style is cached, and a direct write leaves the cache holding the
        // width this test just set.
        defer {
            if let previousCaption { CaptionStyle.current = try! JSONDecoder().decode(CaptionStyle.self, from: previousCaption) }
            else { CaptionStyle.current = CaptionStyle() }
            if let previousDictation { CaptionStyle.currentDictation = try! JSONDecoder().decode(CaptionStyle.self, from: previousDictation) }
            else { CaptionStyle.currentDictation = CaptionStyle.dictationDefaults }
        }

        var caption = CaptionStyle.current
        caption.glassStyle = CaptionStyle.liquidGlass
        CaptionStyle.current = caption

        var dictation = CaptionStyle.dictationDefaults
        dictation.glassStyle = CaptionStyle.regularGlass
        dictation.dictationWidth = 360
        dictation.original.fontSize = 20
        CaptionStyle.currentDictation = dictation

        let window = makeWindow()
        #expect(window.renderedBubbleStyleForTests == CaptionStyle.regularGlass)
        window.show(resultText: "A result styled independently from captions.", autoDismissAfter: nil)
        #expect(window.frame.width == 360)
        #expect(window.resultFontSizeForTests == 20)

        dictation.dictationWidth = 420
        CaptionStyle.currentDictation = dictation
        await Task.yield()
        await Task.yield()
        #expect(window.frame.width == 420)
        window.dismiss()
    }

    @Test("dictation preview shows a result bubble")
    func dictationPreviewShowsResult() async {
        let window = makeWindow()
        NotificationCenter.default.post(name: .saiityDictationPreview, object: nil)
        await Task.yield()
        await Task.yield()

        #expect(window.resultVisibleForTests)
        #expect(window.resultTextForTests == CaptionStyle.longDictationPreview)
        window.dismiss()
    }

    @Test("changing dictation bubble styles keeps its content attached")
    func styleChangesPreserveDictationContent() async {
        let defaults = UserDefaults.standard
        let previous = defaults.data(forKey: CaptionStyle.dictationKey)
        DictationToastWindow.accessibilityPreferences = { (false, false, false) }
        defer {
            if let previous { defaults.set(previous, forKey: CaptionStyle.dictationKey) }
            else { defaults.removeObject(forKey: CaptionStyle.dictationKey) }
            DictationToastWindow.accessibilityPreferences = DictationToastWindow.systemAccessibilityPreferences
        }

        var style = CaptionStyle.currentDictation
        style.glassStyle = CaptionStyle.regularGlass
        CaptionStyle.currentDictation = style
        let window = makeWindow()
        window.show(phase: .dictating)
        #expect(window.bubbleContentAttachedForTests)
        #expect(window.waveformVisibleForTests)
        #expect(window.resetButtonVisibleForTests)

        for glassStyle in [CaptionStyle.liquidGlass, CaptionStyle.regularGlass,
                           CaptionStyle.clearGlass, CaptionStyle.solidGlass,
                           CaptionStyle.liquidGlass, CaptionStyle.regularGlass] {
            style.glassStyle = glassStyle
            CaptionStyle.currentDictation = style
            await Task.yield()
            await Task.yield()
            #expect(window.bubbleContentAttachedForTests,
                    "style=\(glassStyle), rendered=\(window.renderedBubbleStyleForTests)")
            #expect(window.waveformVisibleForTests)
            #expect(window.resetButtonVisibleForTests)

            window.show(text: "Ready", animated: false)
            #expect(window.bubbleContentAttachedForTests)
            #expect(window.labelVisibleForTests)
            #expect(window.resetButtonVisibleForTests)
            window.show(phase: .dictating)
        }

        window.show(text: "Ready", animated: false)
        #expect(window.bubbleContentAttachedForTests)
        #expect(window.labelVisibleForTests)
        #expect(window.resetButtonVisibleForTests)
        window.dismiss()
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

    @Test func phaseChangesPreserveCallerPositionAndConfiguredSize() {
        let window = makeWindow(); let frame = NSRect(x: 31, y: 42, width: 320, height: 80)
        window.setFrame(frame, display: false)
        for phase in [DictationPhase.preparing, .transcribing] {
            window.show(phase: phase)
            #expect(window.frame.origin == frame.origin)
            #expect(window.frame.height == 54)
            #expect(window.frame.width == min(560, max(180, CGFloat(CaptionStyle.currentDictation.dictationWidth))))
        }
        window.dismiss()
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
        #expect(!window.resultVisibleForTests)
        #expect(window.frame.width == 224)
        #expect(window.waveformFrameForTests.width >= 172)
        #expect(window.waveformFrameForTests.height >= 34)
        window.show(phase: .transcribing)
        #expect(!window.waveformVisibleForTests)
        window.dismiss()
    }

    @Test("completed dictation is shown as a scrollable bubble result")
    func completedDictationShowsResultText() {
        let window = makeWindow()
        let text = String(repeating: "This is a completed dictation. ", count: 40)

        window.show(resultText: text, autoDismissAfter: nil)

        #expect(window.resultVisibleForTests)
        #expect(!window.labelVisibleForTests)
        #expect(window.resultTextForTests == text)
        #expect(window.frame.height <= 420)
        #expect(window.resultScrollFrameForTests.height > 0)

        window.show(phase: .dictating)
        #expect(!window.resultVisibleForTests)
        #expect(window.waveformVisibleForTests)
        #expect(window.frame.height == 54)
        window.dismiss()
    }

    @Test("original copy is reachable, retries failure and leaves the processed result intact")
    func originalCopyRecovery() throws {
        let originalPost = DictationToastWindow.postAccessibility
        DictationToastWindow.postAccessibility = { _, _ in }
        defer { DictationToastWindow.postAccessibility = originalPost }
        let window = makeWindow()
        var copies = 0
        window.onCopyOriginal = { copies += 1; return copies > 1 }
        window.show(resultText: "Processed result", autoDismissAfter: nil, canCopyOriginal: true)
        let target = try #require(window.originalTargetAreaForTests)
        #expect(target.width >= 28 && target.height >= 28)
        #expect(!window.claimsTextGesture(atWindowPoint: NSPoint(x: target.maxX - 1, y: target.midY)))
        window.copyOriginal()
        #expect(window.resultTextForTests == "Processed result")
        #expect(window.originalTargetAreaForTests != nil)
        window.copyOriginal()
        #expect(copies == 2)
        window.show(phase: .dictating)
        #expect(window.originalTargetAreaForTests == nil)
        window.copyOriginal()
        #expect(copies == 2)
        window.dismiss()
    }

    @Test("copy recovery keeps selectable text and routes the action to retry")
    func copyRecoveryUsesResultAction() {
        let originalPost = DictationToastWindow.postAccessibility
        var announcements = 0
        DictationToastWindow.postAccessibility = { _, notification in
            if notification == .announcementRequested { announcements += 1 }
        }
        defer { DictationToastWindow.postAccessibility = originalPost }
        let window = makeWindow()
        window.isReleasedWhenClosed = false
        var retries = 0
        var resets = 0
        window.onRetryCopy = { retries += 1 }
        window.onResetPosition = { resets += 1 }
        window.show(resultText: "Retained output.", autoDismissAfter: nil, retryCopy: true)
        #expect(window.resultVisibleForTests)
        #expect(window.resultSelectableForTests)
        #expect(window.offersCopyRetryForTests)
        #expect(announcements == 1)
        #expect(window.performResetPosition())
        #expect(retries == 1)
        #expect(resets == 0)
        window.show(phase: .ready)
        #expect(!window.offersCopyRetryForTests)
        #expect(window.performResetPosition())
        #expect(resets == 1)
        window.dismiss()
    }

    @Test("returning from a result restores the compact bubble height")
    func resultHeightDoesNotPersistIntoStatus() {
        let window = makeWindow()
        window.show(resultText: String(repeating: "Long result. ", count: 40), autoDismissAfter: nil)
        #expect(window.frame.height > 54)

        window.show(phase: .ready)

        #expect(window.frame.height == 54)
        #expect(window.labelVisibleForTests)
        #expect(!window.resultVisibleForTests)
        window.dismiss()
    }

    @Test("a saved frame cannot override the current recording preset's size")
    func savedFramePreservesPositionOnly() {
        let original = CaptionStyle.currentDictation
        defer { CaptionStyle.currentDictation = original }
        let style = BubbleStylePreset.minimal.applying(to: original, context: .dictation)
        CaptionStyle.currentDictation = style
        let window = makeWindow()
        let saved = NSRect(x: 200, y: 200, width: 600, height: 220)
        window.setFrame(saved, display: false)
        window.show(phase: .dictating)
        let compact = window.frame.size
        #expect(compact.height == 54)
        #expect(compact.width < saved.width)
        #expect(window.frame.origin == saved.origin)
        window.show(resultText: String(repeating: "Long result. ", count: 40), autoDismissAfter: nil)
        window.show(phase: .dictating)
        #expect(window.frame.size == compact)
        #expect(window.waveformVisibleForTests)
        window.dismiss()
    }

    @Test("a resting toast is click-through, and arms only over real controls")
    func restingToastIsClickThrough() {
        FrameStore.resetDictation()
        let window = makeWindow()
        window.setFrame(NSRect(x: 200, y: 200, width: 224, height: 54), display: false)

        window.show(phase: .ready)

        // The whole point: a dictation toast sits on screen for the entire
        // dictation. If its resting rectangle takes clicks, the user cannot
        // click the app they are dictating into through it.
        #expect(window.ignoresMouseEvents)

        let content = window.contentFrameForTests
        let body = NSPoint(x: content.midX, y: content.minY + 6)
        let strip = NSPoint(x: content.midX, y: content.maxY - 6)
        let button = NSPoint(x: window.resetTargetAreaForTests.midX,
                             y: window.resetTargetAreaForTests.midY)

        window.updateMouseArming(atContentPoint: body)
        #expect(window.ignoresMouseEvents, "the idle status text must not take clicks")
        window.updateMouseArming(atContentPoint: strip)
        #expect(!window.ignoresMouseEvents, "the drag strip must take clicks")
        window.updateMouseArming(atContentPoint: button)
        #expect(!window.ignoresMouseEvents, "the reset control must take clicks")
        window.updateMouseArming(atContentPoint: body)
        #expect(window.ignoresMouseEvents)
        window.dismiss()
        #expect(window.ignoresMouseEvents, "a dismissed toast must go back to resting")
        FrameStore.resetDictation()
    }

    @Test("a result's text area takes clicks, the rest of the bubble does not")
    func resultAreaTakesClicksWhileResting() {
        FrameStore.resetDictation()
        let window = makeWindow()
        window.setFrame(NSRect(x: 200, y: 200, width: 224, height: 54), display: false)
        window.show(resultText: String(repeating: "A result. ", count: 30),
                    autoDismissAfter: nil)

        let area = window.resultAreaForTests
        #expect(area != nil, "a shown result has no clickable area")
        guard let area, let content = window.contentView else {
            Issue.record("a shown result has no content view")
            window.dismiss()
            return
        }

        window.updateMouseArming(atContentPoint: NSPoint(x: area.midX, y: area.maxY - 4))
        #expect(!window.ignoresMouseEvents,
                "the result text must be reachable, or it cannot be selected")

        // In the bubble's own side padding there is nothing to do, and the panel
        // must not take that click either.
        window.updateMouseArming(atContentPoint: NSPoint(x: 6, y: 2))
        #expect(window.ignoresMouseEvents)

        // And a click inside the text area is a text gesture, not a window drag.
        let text = content.convert(NSPoint(x: area.midX, y: area.midY), to: nil)
        #expect(window.claimsTextGesture(atWindowPoint: text))
        let control = content.convert(
            NSPoint(x: window.resetTargetAreaForTests.midX,
                    y: window.resetTargetAreaForTests.midY), to: nil)
        #expect(!window.claimsTextGesture(atWindowPoint: control),
                "the reset control is the panel's, not the text view's")
        window.dismiss()
        FrameStore.resetDictation()
    }

    @Test("a long result actually scrolls instead of being clipped")
    func longResultScrolls() {
        let window = makeWindow()
        window.show(resultText: String(repeating: "Long dictated sentence. ", count: 60),
                    autoDismissAfter: nil)

        #expect(window.resultSelectableForTests)
        #expect(window.resultScrollableForTests,
                "the document is as tall as the clip view, so a long result is clipped, not scrollable")

        // A short result is not scrollable — and must not claim to be.
        window.show(resultText: "Short.", autoDismissAfter: nil)
        #expect(!window.resultScrollableForTests)
        window.dismiss()
    }

    @Test("single-line status text uses a visually centered label frame")
    func statusTextFrameIsCentered() {
        let window = makeWindow()
        window.show(text: "Transcribing", animated: true)
        #expect(window.labelFrameForTests.height == 20)
        #expect(window.labelFrameForTests.midY == window.contentFrameForTests.midY)
        window.dismiss()
    }

    @Test("phase updates do not reposition the toast")
    func phaseUpdatesPreserveFrame() {
        let window = makeWindow()
        // A zero-sized newly created panel is intentionally placed on first
        // show. Exercise the phase-update invariant with the toast's actual
        // stable footprint instead of the pre-layout placeholder.
        window.setFrame(NSRect(x: 321, y: 222, width: 224, height: 54), display: false)
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

    private func withDUP8Feedback(_ body: (DictationToastWindow) throws -> Void) rethrows {
        let preferences = DictationToastWindow.accessibilityPreferences
        let post = DictationToastWindow.postAccessibility
        DictationToastWindow.accessibilityPreferences = { (true, false, false) }
        DictationToastWindow.postAccessibility = { _, _ in }
        let window = makeWindow()
        defer {
            window.dismiss()
            DictationToastWindow.accessibilityPreferences = preferences
            DictationToastWindow.postAccessibility = post
        }
        window.show(resultText: "DUP8 selectable feedback", autoDismissAfter: .seconds(60))
        window.updateMouseArming(atContentPoint: NSPoint(x: -1_000, y: -1_000))
        window.makeFirstResponder(nil)
        try body(window)
    }

    private func withDUP8KeyFeedback(_ body: (DictationToastWindow, NSWindow) throws -> Void) async throws {
        try #require(LaunchSmokeTest.hasWindowServerSession,
                     "Q3 setup requires a WindowServer-backed Aqua login session")
        let app = NSApplication.shared
        let policy = app.activationPolicy()
        let wasActive = app.isActive
        let previousKey = app.keyWindow
        let other = NSWindow(contentRect: NSRect(x: 50, y: 50, width: 200, height: 100),
                             styleMask: [.titled], backing: .buffered, defer: false)
        defer {
            other.orderOut(nil)
            previousKey?.makeKeyAndOrderFront(nil)
            if !wasActive { app.deactivate() }
            if policy == .prohibited { _ = app.setActivationPolicy(policy) }
        }
        if policy == .prohibited {
            try #require(app.setActivationPolicy(.accessory),
                         "Q3 test host rejected transient accessory activation policy")
        }
        // Match SettingsWindow's native activation path; order-front alone cannot make an inactive host key.
        app.activate(ignoringOtherApps: true)
        other.makeKeyAndOrderFront(nil)
        for _ in 0..<40 where !app.isActive || !other.isKeyWindow {
            try await Task.sleep(for: .milliseconds(25))
            if app.isActive, !other.isKeyWindow { other.makeKeyAndOrderFront(nil) }
        }
        try #require(app.isActive && other.isKeyWindow,
                     "Q3 setup unavailable: active=\(app.isActive), policy=\(app.activationPolicy().rawValue), peerKey=\(other.isKeyWindow); main needs an activated isolated preview host")
        try withDUP8Feedback { window in try body(window, other) }
    }

    @Test("DUP8 feedback survives hover and dismisses once hover ends")
    func dup8AutoDismissPreservesHover() {
        withDUP8Feedback { window in
            let timeout = window.autoDismissActionForTests
            let target = window.resetTargetAreaForTests
            window.updateMouseArming(atContentPoint: NSPoint(x: target.midX, y: target.midY))
            #expect(!window.ignoresMouseEvents)
            #expect(window.isInteractingWithFeedback)
            timeout()
            #expect(window.isVisible, "feedback disappeared while its control was hovered")
            #expect(window.resultTextForTests == "DUP8 selectable feedback")
            window.updateMouseArming(atContentPoint: NSPoint(x: -1_000, y: -1_000))
            #expect(!window.isInteractingWithFeedback)
            timeout()
            #expect(!window.isVisible)
        }
    }

    @Test("DUP8 feedback survives selected text without needing hover or key focus")
    func dup8AutoDismissPreservesSelection() {
        withDUP8Feedback { window in
            let text = window.resultTextViewForTests
            let timeout = window.autoDismissActionForTests
            text.setSelectedRange(NSRange(location: 0, length: 4))
            #expect(text.selectedRange().length == 4)
            #expect(window.isInteractingWithFeedback)
            timeout()
            #expect(window.isVisible, "selected feedback disappeared before it could be copied")
            #expect(text.selectedRange().length == 4)
            text.setSelectedRange(NSRange(location: 0, length: 0))
            #expect(!window.isInteractingWithFeedback)
            timeout()
            #expect(!window.isVisible)
        }
    }

    @Test("DUP8 feedback survives AppKit-owned text tracking outside the hover area")
    func dup8AutoDismissPreservesTextGesture() {
        withDUP8Feedback { window in
            let timeout = window.autoDismissActionForTests
            // Avoid entering NSTextView's blocking mouse-tracking loop in a synthetic test.
            window.textGestureInFlightForTests = true
            #expect(window.isInteractingWithFeedback)
            timeout()
            #expect(window.isVisible, "feedback disappeared during the text down/drag/up sequence")
            window.textGestureInFlightForTests = false
            #expect(!window.isInteractingWithFeedback)
            timeout()
            #expect(!window.isVisible)
        }
    }

    @Test("DUP8 feedback survives an active window drag")
    func dup8AutoDismissPreservesDrag() {
        withDUP8Feedback { window in
            let timeout = window.autoDismissActionForTests
            window.beginDrag(atScreenPoint: NSPoint(x: 10, y: 10))
            #expect(window.isInteractingWithFeedback)
            timeout()
            #expect(window.isVisible, "feedback disappeared before the window drag ended")
            #expect(window.resultTextForTests == "DUP8 selectable feedback")
            // Do not endDrag here: its existing production path persists the frame.
        }
    }

    @Test("DUP8 feedback survives native keyboard focus and dismisses after focus leaves",
          .enabled(if: ProcessInfo.processInfo.environment["SAIITY_NATIVE_FOCUS_TESTS"] == "1"))
    func dup8AutoDismissPreservesKeyboardFocus() async throws {
        try await withDUP8KeyFeedback { window, other in
            let timeout = window.autoDismissActionForTests
            let text = window.resultTextViewForTests
            #expect(window.makeFirstResponder(text))
            #expect(window.firstResponder === text)
            try #require(window.canBecomeKey, "completed result must permit intentional keyboard focus")
            window.makeKeyAndOrderFront(nil)
            try #require(window.isKeyWindow, "a saved responder is not actual keyboard ownership")
            #expect(window.isInteractingWithFeedback)
            timeout()
            #expect(window.isVisible, "feedback disappeared while a result control had keyboard focus")
            other.makeKeyAndOrderFront(nil)
            try #require(other.isKeyWindow)
            #expect(!window.isKeyWindow)
            // Keep the result's saved responder: focus ownership has moved elsewhere.
            #expect(window.firstResponder === text)
            #expect(!window.isInteractingWithFeedback)
            timeout()
            #expect(!window.isVisible)
        }
    }

    @Test("DUP8 stored result responder does not keep idle feedback alive after focus leaves",
          .enabled(if: ProcessInfo.processInfo.environment["SAIITY_NATIVE_FOCUS_TESTS"] == "1"))
    func dup8AutoDismissStaleResponderResumesIdle() async throws {
        try await withDUP8KeyFeedback { window, other in
            let text = window.resultTextViewForTests
            try #require(window.makeFirstResponder(text))
            other.makeKeyAndOrderFront(nil)
            try #require(other.isKeyWindow, "synthetic peer must actually own keyboard focus")
            #expect(!window.isKeyWindow)
            #expect(window.firstResponder === text)
            text.setSelectedRange(NSRange(location: 0, length: 0))
            window.textGestureInFlightForTests = false
            window.setAccessibilityFocused(false)
            text.setAccessibilityFocused(false)
            window.updateMouseArming(atContentPoint: NSPoint(x: -1_000, y: -1_000))
            #expect(window.ignoresMouseEvents)
            #expect(text.selectedRange().length == 0)
            #expect(!window.isInteractingWithFeedback, "stored responder outlived actual keyboard/AX interaction")
            window.autoDismissActionForTests()
            #expect(!window.isVisible, "ordinary idle dismissal stayed blocked by a saved responder")
        }
    }

    @Test("DUP8 actual AX focus protects a non-key result despite a stored responder",
          .enabled(if: ProcessInfo.processInfo.environment["SAIITY_NATIVE_FOCUS_TESTS"] == "1"))
    func dup8AutoDismissAccessibilityFocusWithStaleResponder() async throws {
        try await withDUP8KeyFeedback { window, other in
            let text = window.resultTextViewForTests
            try #require(window.makeFirstResponder(text))
            text.setSelectedRange(NSRange(location: 0, length: 0))
            other.makeKeyAndOrderFront(nil)
            try #require(other.isKeyWindow)
            #expect(!window.isKeyWindow)
            window.setAccessibilityFocused(true)
            #expect(window.isInteractingWithFeedback)
            window.autoDismissActionForTests()
            #expect(window.isVisible)
            window.setAccessibilityFocused(false)
            text.setAccessibilityFocused(false)
            #expect(window.firstResponder === text)
            #expect(!window.isInteractingWithFeedback, "leaving AX focus must not expose sticky responder protection")
            window.autoDismissActionForTests()
            #expect(!window.isVisible)
        }
    }

    @Test("DUP8 showing feedback or recording never steals the dictation target's key ownership",
          .enabled(if: ProcessInfo.processInfo.environment["SAIITY_NATIVE_FOCUS_TESTS"] == "1"))
    func dup8AutoDismissPresentationDoesNotStealKey() async throws {
        try await withDUP8KeyFeedback { window, other in
            try #require(other.isKeyWindow)
            window.show(phase: .dictating)
            #expect(!window.canBecomeKey)
            #expect(!window.canBecomeMain)
            #expect(!window.isKeyWindow)
            #expect(other.isKeyWindow)
            window.show(resultText: "DUP8 live draft", autoDismissAfter: nil, allowsKeyboardFocus: false)
            #expect(!window.canBecomeKey)
            #expect(!window.isKeyWindow)
            #expect(other.isKeyWindow)
            window.show(resultText: "DUP8 completed feedback", autoDismissAfter: nil)
            #expect(window.canBecomeKey)
            #expect(!window.isKeyWindow)
            #expect(other.isKeyWindow)
            #expect(window.styleMask.contains(.nonactivatingPanel))
        }
    }

    @Test("DUP8 only completed results permit intentional keyboard focus")
    func dup8AutoDismissKeyboardEligibilityFollowsPresentation() {
        withDUP8Feedback { window in
            #expect(window.canBecomeKey)
            #expect(!window.canBecomeMain)
            window.show(resultText: "DUP8 live draft", autoDismissAfter: nil, allowsKeyboardFocus: false)
            #expect(!window.canBecomeKey)
            #expect(!window.canBecomeMain)
            window.show(resultText: "DUP8 completed feedback", autoDismissAfter: nil)
            #expect(window.canBecomeKey)
            window.show(phase: .dictating)
            #expect(!window.canBecomeKey)
            window.show(phase: .ready)
            #expect(!window.canBecomeKey)
            window.show(resultText: "DUP8 completed feedback", autoDismissAfter: nil)
            window.dismiss()
            #expect(!window.canBecomeKey)
            #expect(!window.canBecomeMain)
        }
    }

    @Test("DUP8 feedback survives native accessibility focus and dismisses after it leaves")
    func dup8AutoDismissPreservesAccessibilityFocus() {
        withDUP8Feedback { window in
            let timeout = window.autoDismissActionForTests
            window.setAccessibilityFocused(true)
            #expect(window.isInteractingWithFeedback)
            timeout()
            #expect(window.isVisible, "feedback disappeared while the accessibility cursor was on it")
            window.setAccessibilityFocused(false)
            #expect(!window.isInteractingWithFeedback)
            timeout()
            #expect(!window.isVisible)
        }
    }

    @Test("DUP8 copy failure keeps feedback and its recovery action", arguments: [false, true])
    func dup8AutoDismissPreservesCopyFailure(retryCopy: Bool) {
        withDUP8Feedback { window in
            window.show(resultText: "DUP8 retained output", autoDismissAfter: .seconds(60),
                        retryCopy: retryCopy, canCopyOriginal: !retryCopy)
            window.updateMouseArming(atContentPoint: NSPoint(x: -1_000, y: -1_000))
            window.makeFirstResponder(nil)
            if !retryCopy {
                window.onCopyOriginal = { false }
                window.copyOriginal()
            }
            #expect(window.isInteractingWithFeedback)
            window.autoDismissActionForTests()
            #expect(window.isVisible, "copy failure lost the result and recovery control")
            #expect(window.resultTextForTests == "DUP8 retained output")
            #expect(retryCopy ? window.offersCopyRetryForTests : window.originalTargetAreaForTests != nil)
        }
    }

    @Test("DUP8 ordinary idle feedback still dismisses")
    func dup8AutoDismissIdleFeedback() {
        withDUP8Feedback { window in
            #expect(window.isVisible)
            #expect(!window.isInteractingWithFeedback)
            window.autoDismissActionForTests()
            #expect(!window.isVisible)
            #expect(window.alphaValue == 1)
        }
    }

    @Test("DUP8 stale feedback timeout cannot dismiss a newer recording")
    func dup8AutoDismissStaleTimerAfterRecording() {
        withDUP8Feedback { window in
            let oldTimeout = window.autoDismissActionForTests
            window.show(phase: .dictating)
            oldTimeout()
            #expect(window.isVisible)
            #expect(window.alphaValue == 1)
            #expect(window.waveformVisibleForTests)
            #expect(!window.resultVisibleForTests)
        }
    }

    @Test("DUP8 a paused timer resumes ordinary dismissal after hover leaves")
    func dup8AutoDismissResumesAfterHoverEnds() async {
        let preferences = DictationToastWindow.accessibilityPreferences
        let post = DictationToastWindow.postAccessibility
        DictationToastWindow.accessibilityPreferences = { (true, false, false) }
        DictationToastWindow.postAccessibility = { _, _ in }
        let window = makeWindow()
        defer {
            window.dismiss()
            DictationToastWindow.accessibilityPreferences = preferences
            DictationToastWindow.postAccessibility = post
        }
        window.show(resultText: "DUP8 selectable feedback", autoDismissAfter: .milliseconds(80))
        window.stopArmingTickForTests()
        window.makeFirstResponder(nil)
        let target = window.resetTargetAreaForTests
        window.updateMouseArming(atContentPoint: NSPoint(x: target.midX, y: target.midY))
        try? await Task.sleep(for: .milliseconds(160))
        #expect(window.isVisible, "the real timer dismissed feedback during hover")
        window.updateMouseArming(atContentPoint: NSPoint(x: -1_000, y: -1_000))
        for _ in 0..<20 where window.isVisible {
            try? await Task.sleep(for: .milliseconds(50))
        }
        #expect(!window.isVisible, "ordinary dismissal never resumed after hover ended")
    }

    @Test("DUP8 successful retry clears failed-original-copy protection")
    func dup8AutoDismissCopySuccessClearsFailure() {
        withDUP8Feedback { window in
            window.show(resultText: "DUP8 retained output", autoDismissAfter: .seconds(60),
                        canCopyOriginal: true)
            window.updateMouseArming(atContentPoint: NSPoint(x: -1_000, y: -1_000))
            var copied = false
            window.onCopyOriginal = { copied }
            window.copyOriginal()
            #expect(window.isInteractingWithFeedback)
            copied = true
            window.copyOriginal()
            #expect(!window.isInteractingWithFeedback)
            window.autoDismissActionForTests()
            #expect(!window.isVisible)
        }
    }

    @Test("DUP8 a fresh result clears old selection and failed-copy state")
    func dup8AutoDismissNewResultClearsInteraction() {
        withDUP8Feedback { window in
            window.show(resultText: "DUP8 prior feedback", autoDismissAfter: .seconds(60),
                        canCopyOriginal: true)
            window.resultTextViewForTests.setSelectedRange(NSRange(location: 0, length: 4))
            window.onCopyOriginal = { false }
            window.copyOriginal()
            #expect(window.isInteractingWithFeedback)
            window.show(resultText: "DUP8 new feedback", autoDismissAfter: .seconds(60))
            window.updateMouseArming(atContentPoint: NSPoint(x: -1_000, y: -1_000))
            window.makeFirstResponder(nil)
            #expect(window.resultTextViewForTests.selectedRange().length == 0)
            #expect(!window.isInteractingWithFeedback)
            window.autoDismissActionForTests()
            #expect(!window.isVisible)
        }
    }

    @Test("DUP8 hovering click-through status text also preserves feedback")
    func dup8AutoDismissPreservesClickThroughHover() throws {
        try withDUP8Feedback { window in
            window.show(text: "DUP8 ready feedback", animated: false, autoDismissAfter: .seconds(60))
            let content = try #require(window.contentView)
            let point = NSPoint(x: content.bounds.midX, y: content.bounds.minY + 20)
            let windowPoint = content.convert(point, to: nil)
            window.updateMouseArming(atScreenPoint: window.convertPoint(toScreen: windowPoint))
            #expect(window.ignoresMouseEvents, "status text must remain click-through")
            #expect(window.isInteractingWithFeedback)
            window.autoDismissActionForTests()
            #expect(window.isVisible)
            window.updateMouseArming(atContentPoint: NSPoint(x: -1_000, y: -1_000))
            #expect(!window.isInteractingWithFeedback)
            window.autoDismissActionForTests()
            #expect(!window.isVisible)
        }
    }

    @Test("DUP8 a gesture or new recording interrupts a fade safely", arguments: [false, true])
    func dup8AutoDismissFadeRace(newRecording: Bool) async {
        let preferences = DictationToastWindow.accessibilityPreferences
        let post = DictationToastWindow.postAccessibility
        DictationToastWindow.accessibilityPreferences = { (false, false, false) }
        DictationToastWindow.postAccessibility = { _, _ in }
        let window = makeWindow()
        defer {
            window.dismiss()
            DictationToastWindow.accessibilityPreferences = preferences
            DictationToastWindow.postAccessibility = post
        }
        window.show(resultText: "DUP8 selectable feedback", autoDismissAfter: .seconds(60))
        window.stopArmingTickForTests()
        window.updateMouseArming(atContentPoint: NSPoint(x: -1_000, y: -1_000))
        window.makeFirstResponder(nil)
        let oldTimeout = window.autoDismissActionForTests
        oldTimeout()
        #expect(window.isAutoDismissFadingForTests)
        if newRecording {
            window.show(phase: .dictating)
            window.stopArmingTickForTests()
            oldTimeout()
        } else {
            window.textGestureInFlightForTests = true
        }
        try? await Task.sleep(for: .seconds(1))
        #expect(window.isVisible, "an expired fade hid interacting feedback or a new recording")
        #expect(window.alphaValue == 1)
        #expect(!window.isAutoDismissFadingForTests)
        if newRecording {
            #expect(window.waveformVisibleForTests)
            #expect(!window.resultVisibleForTests)
        } else {
            #expect(window.resultTextForTests == "DUP8 selectable feedback")
            window.textGestureInFlightForTests = false
            for _ in 0..<30 where window.isVisible {
                try? await Task.sleep(for: .milliseconds(50))
            }
            #expect(!window.isVisible, "idle feedback stayed visible after the interrupted fade")
        }
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
