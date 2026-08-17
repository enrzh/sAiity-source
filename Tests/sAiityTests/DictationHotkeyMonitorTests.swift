import CoreGraphics
import Carbon.HIToolbox
import Testing

@testable import sAiity

@Suite struct DictationHotkeyMonitorTests {
    @Test("modifier chords use the standard language-neutral Mac glyphs")
    func chordDisplay() {
        #expect(DictationChord(keyCodes: [59]).displayString == "⌃")
        #expect(DictationChord(keyCodes: [55, 58, 49]).displayString == "⌘⌥Space")
    }

    @Test("ordinary keys require a modifier so typing cannot trigger dictation")
    func chordSafety() {
        #expect(DictationChord(keyCodes: [59]).isUsable)
        #expect(DictationChord(keyCodes: [59, 2]).isUsable)
        #expect(!DictationChord(keyCodes: [2]).isUsable)

        var capture = DictationChordCaptureState()
        #expect(capture.handle(.keyDown(2)) == nil)
        #expect(capture.handle(.keyUp(2)) == nil)
    }

    @Test("a configured chord starts when all keys are pressed and stops when one is released")
    func chordTransitions() {
        var state = DictationChordState(chord: DictationChord(keyCodes: [59]))
        #expect(state.handle(.flagsChanged(59, isDown: true)) == .start)
        #expect(state.handle(.flagsChanged(59, isDown: false)) == .stop)
    }

    @Test("a multi-key chord remains active until the final key is released")
    func multiKeyChordTransitions() {
        var state = DictationChordState(chord: DictationChord(keyCodes: [59, 49]))
        #expect(state.handle(.flagsChanged(59, isDown: true)) == .none)
        #expect(state.handle(.keyDown(49)) == .start)
        #expect(state.handle(.keyUp(49)) == .stop)
    }

    @Test("a chord can recover a missed key edge from the authoritative set")
    func authoritativeRecovery() {
        var state = DictationChordState(chord: DictationChord(keyCodes: [59]))
        #expect(state.sync(pressed: [59]) == .start)
        #expect(state.sync(pressed: []) == .stop)
    }

    @Test("a chord can start again after the event tap was disabled while held")
    func eventTapRecovery() {
        var state = DictationChordState(chord: DictationChord(keyCodes: [59]))
        #expect(state.sync(pressed: [59]) == .start)

        state.resetAfterEventTapDisabled()

        #expect(state.sync(pressed: [59]) == .start)
        #expect(state.sync(pressed: []) == .stop)
    }

    @Test("the default Control shortcut accepts either physical Control key")
    func controlAlias() {
        var state = DictationChordState(chord: .defaultControl)

        #expect(state.handle(.flagsChanged(UInt16(kVK_RightControl), isDown: true)) == .start)
        #expect(state.handle(.flagsChanged(UInt16(kVK_RightControl), isDown: false)) == .stop)
    }

    @Test("shortcut capture commits the complete chord after every key is released")
    func chordCapture() {
        var capture = DictationChordCaptureState()
        #expect(capture.handle(.flagsChanged(59, isDown: true)) == nil)
        #expect(capture.handle(.keyDown(49)) == nil)
        #expect(capture.handle(.keyUp(49)) == nil)
        #expect(capture.handle(.flagsChanged(59, isDown: false)) == DictationChord(keyCodes: [59, 49]))
    }

    @Test("control flags are detected without treating other modifiers as control")
    func controlFlagDetection() {
        #expect(DictationHotkeyMonitor.isControlDown(flags: [.maskControl]))
        #expect(!DictationHotkeyMonitor.isControlDown(flags: [.maskShift, .maskCommand]))
    }

    @Test("generic Control flags count as either physical Control key")
    func genericControlFlagsKeepTheChordDown() {
        #expect(DictationHotkeyMonitor.physicalKeyDown(UInt16(kVK_Control),
                                                       flags: [.maskControl]))
        #expect(DictationHotkeyMonitor.physicalKeyDown(UInt16(kVK_RightControl),
                                                       flags: [.maskControl]))
    }

    @Test("only a real control transition produces a callback")
    func transitionDetection() {
        #expect(DictationHotkeyMonitor.hasTransition(from: false, to: true))
        #expect(DictationHotkeyMonitor.hasTransition(from: true, to: false))
        #expect(!DictationHotkeyMonitor.hasTransition(from: true, to: true))
        #expect(!DictationHotkeyMonitor.hasTransition(from: false, to: false))
    }
}
