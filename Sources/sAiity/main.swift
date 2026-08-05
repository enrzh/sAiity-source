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

// Automatic language detection is ON unless the user turns it off. Registered
// rather than hardcoded so an explicit "off" in the menu still wins — and keeps
// winning across launches.
UserDefaults.standard.register(defaults: ["autoLanguage": true])

// Menu-bar only: no dock icon, no default window.
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
