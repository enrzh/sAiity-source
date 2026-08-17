import AppKit
import Testing

@testable import sAiity

@MainActor
@Suite struct SettingsWindowTests {
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
