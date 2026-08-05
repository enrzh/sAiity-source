import AppKit
import Foundation

// Scriptable export, so transcripts are usable outside the menu:
//   sAiity --list
//   sAiity --export srt|md|txt [sessionId]     (default: most recent)
let args = CommandLine.arguments
if args.count > 1, args[1].hasPrefix("--") {
    let sessions = TranscriptStore.list()
    switch args[1] {
    case "--list":
        let df = ISO8601DateFormatter()
        for s in sessions {
            print("\(s.id)\t\(df.string(from: s.meta.startedAt))\t\(s.meta.locale)\t\(s.meta.lineCount) lines")
        }
    case "--export":
        let format = args.count > 2 ? args[2] : "txt"
        let session = args.count > 3 ? sessions.first { $0.id == args[3] } : sessions.first
        guard let session else {
            FileHandle.standardError.write(Data("no such session\n".utf8))
            exit(1)
        }
        let segs = TranscriptStore.segments(of: session)
        switch format {
        case "srt": print(Export.srt(segs))
        case "md":  print(Export.markdown(segs, meta: session.meta))
        default:    print(Export.txt(segs))
        }
    default:
        FileHandle.standardError.write(Data("usage: sAiity [--list | --export srt|md|txt [id]]\n".utf8))
        exit(2)
    }
    exit(0)
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
MainActor.assumeIsolated {
    let delegate = AppDelegate()
    app.delegate = delegate
    // Held for the process lifetime: NSApplication.delegate is a weak reference,
    // so without this the delegate would deallocate immediately.
    delegateRef = delegate
}
app.setActivationPolicy(.accessory)
app.run()
