import CoreGraphics
import Testing

@testable import sAiity

@Suite struct DictationHotkeyMonitorTests {
    @Test("control flags are detected without treating other modifiers as control")
    func controlFlagDetection() {
        #expect(DictationHotkeyMonitor.isControlDown(flags: [.maskControl]))
        #expect(!DictationHotkeyMonitor.isControlDown(flags: [.maskShift, .maskCommand]))
    }

    @Test("only a real control transition produces a callback")
    func transitionDetection() {
        #expect(DictationHotkeyMonitor.hasTransition(from: false, to: true))
        #expect(DictationHotkeyMonitor.hasTransition(from: true, to: false))
        #expect(!DictationHotkeyMonitor.hasTransition(from: true, to: true))
        #expect(!DictationHotkeyMonitor.hasTransition(from: false, to: false))
    }
}
