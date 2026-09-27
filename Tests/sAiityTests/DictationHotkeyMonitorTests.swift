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

    @Test("a chord needs a modifier and a real key, or it fires by accident")
    func chordSafety() {
        // Both halves matter, and they stop different accidents. A bare letter
        // fires while typing; a bare modifier fires on every press of it in
        // every app, which is what the default used to be.
        #expect(DictationChord(keyCodes: [59, 2]).isUsable)   // ⌃A
        #expect(!DictationChord(keyCodes: [2]).isUsable)       // A alone
        #expect(!DictationChord(keyCodes: [59]).isUsable)      // ⌃ alone

        var capture = DictationChordCaptureState()
        #expect(capture.handle(.keyDown(2)) == nil)
        #expect(capture.handle(.keyUp(2)) == nil)
    }

    @Test("a bare modifier cannot be recorded as the dictation shortcut")
    func bareModifierIsNotRecordable() {
        // Pressing and releasing only Control must not become the shortcut.
        var capture = DictationChordCaptureState()
        #expect(capture.handle(.flagsChanged(59, isDown: true)) == nil)
        #expect(capture.handle(.flagsChanged(59, isDown: false)) == nil)
    }

    @Test("the default shortcut cannot fire on an ordinary key press")
    func defaultChordIsInertWithoutTheModifier() {
        // The whole point of the new default: a Control press anywhere must not
        // start a recording.
        let chord = DictationChord.defaultControl
        #expect(chord.isUsable)
        var state = DictationChordState(chord: chord)
        #expect(state.handle(.flagsChanged(UInt16(kVK_Control), isDown: true)) == .none)
        #expect(state.handle(.keyDown(UInt16(kVK_ANSI_A))) == .none)
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

    @Test("a modifier chord accepts either physical modifier key")
    func controlAlias() {
        // Left and right must be interchangeable, so a user who binds ⌃ uses
        // whichever Control their hand is on.
        var state = DictationChordState(chord: DictationChord(keyCodes: [59]))

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

    @Test("event tap preserves the current key edge instead of rebuilding a global snapshot")
    func eventTapUsesCurrentEdge() {
        #expect(DictationHotkeyMonitor.eventInput(type: .flagsChanged,
                                                  key: UInt16(kVK_Control),
                                                  flags: [.maskControl])
                == .flagsChanged(UInt16(kVK_Control), isDown: true))
        #expect(DictationHotkeyMonitor.eventInput(type: .keyDown,
                                                  key: UInt16(kVK_Space),
                                                  flags: [])
                == .keyDown(UInt16(kVK_Space)))
        #expect(DictationHotkeyMonitor.eventInput(type: .keyUp,
                                                  key: UInt16(kVK_Space),
                                                  flags: [])
                == .keyUp(UInt16(kVK_Space)))
    }

    @Test("only a real control transition produces a callback")
    func transitionDetection() {
        #expect(DictationHotkeyMonitor.hasTransition(from: false, to: true))
        #expect(DictationHotkeyMonitor.hasTransition(from: true, to: false))
        #expect(!DictationHotkeyMonitor.hasTransition(from: true, to: true))
        #expect(!DictationHotkeyMonitor.hasTransition(from: false, to: false))
    }
}
