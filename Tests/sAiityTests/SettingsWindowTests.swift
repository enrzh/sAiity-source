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

    @Test("first dictation target initialization inherits captions once, including Off")
    func dictationTargetMigratesOnce() {
        let defaults = UserDefaults.standard
        let keys = ["translateTo", "dictationTranslateTo", "dictationTranslateToMigrated"]
        let snapshot = keys.map { ($0, defaults.object(forKey: $0)) }
        defer {
            snapshot.forEach { key, value in
                if let value { defaults.set(value, forKey: key) }
                else { defaults.removeObject(forKey: key) }
            }
        }

        defaults.set("de", forKey: "translateTo")
        defaults.removeObject(forKey: "dictationTranslateTo")
        defaults.removeObject(forKey: "dictationTranslateToMigrated")
        let inherited = AppState()
        #expect(inherited.dictationTranslateTo == "de")
        #expect(defaults.bool(forKey: "dictationTranslateToMigrated"))

        inherited.dictationTranslateTo = "fr"
        inherited.translateTo = "ja"
        let independent = AppState()
        #expect(independent.dictationTranslateTo == "fr")
        #expect(independent.translateTo == "ja")

        defaults.removeObject(forKey: "dictationTranslateTo")
        defaults.removeObject(forKey: "dictationTranslateToMigrated")
        defaults.removeObject(forKey: "translateTo")
        let off = AppState()
        #expect(off.dictationTranslateTo == nil)
        #expect(defaults.bool(forKey: "dictationTranslateToMigrated"))
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
