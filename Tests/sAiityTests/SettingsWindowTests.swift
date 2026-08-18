import AppKit
import Testing

@testable import sAiity

@MainActor
@Suite struct SettingsWindowTests {
    @Test("dictation translation is opt-in and persisted")
    func dictationTranslationIsOptIn() {
        let defaults = UserDefaults.standard
        let previous = defaults.object(forKey: "translateDictation")
        defer {
            if let previous {
                defaults.set(previous, forKey: "translateDictation")
            } else {
                defaults.removeObject(forKey: "translateDictation")
            }
        }

        defaults.removeObject(forKey: "translateDictation")
        let state = AppState()
        #expect(state.translateDictation == false)

        state.translateDictation = true
        #expect(defaults.bool(forKey: "translateDictation"))

        state.translateDictation = false
        #expect(defaults.bool(forKey: "translateDictation") == false)
    }

    @Test("settings uses preference toolbar chrome with visible labels")
    func toolbarUsesPreferenceChrome() {
        SettingsWindowController.show()
        defer {
            NSApp.windows
                .first(where: { $0.contentViewController is NSTabViewController })?
                .close()
        }

        guard let window = NSApp.windows.first(where: {
            $0.contentViewController is NSTabViewController
        }) else {
            Issue.record("settings window was not created")
            return
        }

        #expect(window.toolbarStyle == .preference)
        #expect(window.titlebarAppearsTransparent == false)
        #expect(window.toolbar?.displayMode == .iconAndLabel)
        #expect(window.toolbar?.allowsDisplayModeCustomization == false)

        func descendants(of view: NSView) -> [NSView] {
            view.subviews + view.subviews.flatMap(descendants)
        }
        let backdrop = window.contentView?.superview.map(descendants(of:))?
            .compactMap { $0 as? SettingsWindowToolbarBackdrop }
            .first
        #expect(backdrop != nil)
        #expect(backdrop?.isOpaque == true)
        #expect(backdrop?.hitTest(NSPoint(x: 1, y: 1)) == nil)
        #expect(backdrop?.layer?.backgroundColor != nil)
    }
}
