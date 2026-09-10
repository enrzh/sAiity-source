import Foundation

/// Environment-variable hooks that exist only to make the app testable from a
/// script.
///
/// They are compiled out of a shipping build. `SAIITY_AUTOSTART` in particular
/// begins system-audio capture with no window, no menu interaction and no
/// consent — a reasonable thing to have while developing, and not a thing to
/// leave in a notarised binary that anyone can set an environment variable on.
///
/// `build-app.sh` defines `SAIITY_TEST_HOOKS` for local builds and never for
/// `--notarize`, so a release build resolves every check below to a constant
/// `false` and the branches are dropped.
enum TestHooks {

    #if SAIITY_TEST_HOOKS
    private static func flag(_ name: String, equals value: String = "1") -> Bool {
        ProcessInfo.processInfo.environment[name] == value
    }
    #else
    private static func flag(_ name: String, equals value: String = "1") -> Bool { false }
    #endif

    /// Start captioning at launch, without touching the UI.
    static var autostart: Bool { flag("SAIITY_AUTOSTART") }

    /// Raise the settings window at launch — a menu-bar app cannot otherwise be
    /// driven to it from a script.
    static var openSettings: Bool { flag("SAIITY_OPEN_SETTINGS") }

    /// Render the real caption bubble with sample content without starting ASR.
    static var preview: Bool { flag("SAIITY_PREVIEW") }

    /// Re-run the first-run wizard without clearing real preferences.
    static var forceOnboarding: Bool { flag("SAIITY_ONBOARDING", equals: "force") }

    /// Per-chunk transcript and capture-lag logging. Verbose, and it names what
    /// the user is listening to, so it is a development-only facility.
    static var verboseLogging: Bool { autostart }
}
