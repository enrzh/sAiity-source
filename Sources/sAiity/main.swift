import AppKit
import Foundation

// Scriptable export, so transcripts are usable outside the menu:
//   Syllivra --list
//   Syllivra --export srt|md|txt [sessionId]     (default: most recent)
//
// The dispatch table is `CommandLinePlan`, which is pure and tested. Only
// --selftest needs the app itself: everything else answers from argv and exits
// here.
let plan = CommandLinePlan.parse(CommandLine.arguments)
var smokeTimeout: TimeInterval?
if let plan {
    switch plan {
    case .version:
        // The git-stamped version from the bundle, or "unbundled" from a bare
        // swift-build binary — a bug report has to be able to name its build.
        // Nothing else on this path touches AppKit or the transcript store: a
        // build that prints its version has proved it can start.
        let v = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        let b = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        print("Syllivra \(v ?? "unbundled") (\(b ?? "0"))")
    case .list:
        let df = ISO8601DateFormatter()
        for s in TranscriptStore.list() {
            print("\(s.id)\t\(df.string(from: s.meta.startedAt))\t\(s.meta.locale)\t\(s.meta.lineCount) lines")
        }
    case .export(let format, let sessionID):
        let sessions = TranscriptStore.list()
        let session = sessionID.flatMap { id in sessions.first { $0.id == id } } ?? sessions.first
        guard let session else {
            FileHandle.standardError.write(Data("no such session\n".utf8))
            exit(1)
        }
        let segs = TranscriptStore.segments(of: session)
        switch format {
        case "srt": print(Export.srt(segs))
        case "vtt": print(Export.vtt(segs))
        case "md":  print(Export.markdown(segs, meta: session.meta,
                                          summary: TranscriptSummaryStore.read(session), localized: false))
        default:    print(Export.txt(segs, meta: session.meta))
        }
    case .openApp(let verb):
        // Routed through the saiity:// scheme so the verb lands in the RUNNING
        // app — this CLI invocation is a separate process with no session of
        // its own. LaunchServices starts the app first if it is not running,
        // which is exactly right for --start and --toggle.
        guard let url = CommandLinePlan.appURL(forVerb: verb) else { exit(1) }
        NSWorkspace.shared.open(url)
        // Give LaunchServices a beat to accept the open before this process
        // exits; exiting immediately can drop the hand-off.
        RunLoop.current.run(until: Date().addingTimeInterval(0.5))
    case .launchSmokeTest(let timeout):
        // The one verb that needs the app itself, so the one verb this block
        // does not exit on. Armed further down, before app.run(), because
        // NSApplication posts didFinishLaunching from inside run().
        smokeTimeout = timeout
    case .unknown:
        FileHandle.standardError.write(Data(CommandLinePlan.usage.utf8))
        exit(2)
    }
    if smokeTimeout == nil { exit(0) }
}

// Registered rather than hardcoded, so an explicit "off" still wins and keeps
// winning across launches.
//
// captionClickThrough defaults ON: the bubble sits about 90 pt above the bottom
// of the screen, which is exactly where a video player puts its scrubber, and
// defaulting to off meant the subtitles quietly swallowed every click there.
UserDefaults.standard.register(defaults: [
    "autoLanguage": true,
    "captionClickThrough": true,
])

/// Strong reference to the app delegate; `NSApplication.delegate` is weak.
nonisolated(unsafe) var delegateRef: AnyObject?

// Menu-bar only: no dock icon, no default window.
//
// `AppDelegate` is @MainActor-isolated, and top-level code is not, so the
// construction is hopped explicitly. We are on the main thread here — this is
// the process entry point — so assumeIsolated states that rather than
// scheduling work that would not run until after `app.run()` takes over.
let app = NSApplication.shared
if smokeTimeout != nil {
    var arguments = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
    arguments["dictationEnabled"] = false
    arguments["transcriptRetentionDays"] = 0
    arguments["onboardingCompletedVersion"] = Onboarding.currentVersion
    UserDefaults.standard.setVolatileDomain(arguments, forName: UserDefaults.argumentDomain)
}
MainActor.assumeIsolated {
    // Even a menu-bar app needs a functioning Edit menu: without one, the
    // standard editing shortcuts do nothing in any text field the app shows —
    // most painfully the language search box. The menu is never visible (there
    // is no menu bar to show it in) but the key equivalents route through it.
    let main = NSMenu()
    let editItem = NSMenuItem()
    let edit = NSMenu(title: String(localized: "Edit"))
    edit.addItem(withTitle: String(localized: "Undo"), action: Selector(("undo:")), keyEquivalent: "z")
    edit.addItem(withTitle: String(localized: "Redo"), action: Selector(("redo:")), keyEquivalent: "Z")
    edit.addItem(.separator())
    edit.addItem(withTitle: String(localized: "Cut"), action: #selector(NSText.cut(_:)), keyEquivalent: "x")
    edit.addItem(withTitle: String(localized: "Copy"), action: #selector(NSText.copy(_:)), keyEquivalent: "c")
    edit.addItem(withTitle: String(localized: "Paste"), action: #selector(NSText.paste(_:)), keyEquivalent: "v")
    edit.addItem(withTitle: String(localized: "Select All"), action: #selector(NSText.selectAll(_:)),
                 keyEquivalent: "a")
    editItem.submenu = edit
    main.addItem(editItem)

    let windowItem = NSMenuItem()
    let window = NSMenu(title: String(localized: "Window"))
    window.addItem(withTitle: String(localized: "Close"), action: #selector(NSWindow.performClose(_:)),
                   keyEquivalent: "w")
    windowItem.submenu = window
    main.addItem(windowItem)
    app.mainMenu = main

    let delegate = AppDelegate()
    app.delegate = delegate
    // Held for the process lifetime: NSApplication.delegate is a weak reference,
    // so without this the delegate would deallocate immediately.
    delegateRef = delegate
}
app.setActivationPolicy(.accessory)

// Before run(): didFinishLaunching is posted from inside it, so the observer
// has to exist first. The window-server check runs before any AppKit exists, so
// a session that cannot host a GUI at all skips instead of failing.
if let smokeTimeout { LaunchSmokeTest.armOrSkip(timeout: smokeTimeout) }
app.run()
