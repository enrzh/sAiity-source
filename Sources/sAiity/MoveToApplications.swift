import AppKit

/// The classic well-behaved-Mac-app offer: relocate to /Applications when
/// launched from the disk image, from Downloads, or app-translocated.
///
/// This matters more than anything visual about the installer. The Screen
/// Recording grant is keyed to where the bundle lives, and a quarantined app
/// outside /Applications runs TRANSLOCATED — from a randomized read-only
/// path, different on every launch — so the permission a user just granted
/// can stop matching the app that asks next time. Sparkle cannot update an
/// app running from a read-only image at all. One copy fixes all of it.
@MainActor
enum MoveToApplications {
    private static let suppressKey = "suppressMoveToApplications"

    static func offerIfNeeded() {
        guard !UserDefaults.standard.bool(forKey: suppressKey) else { return }
        let path = Bundle.main.bundlePath
        guard let source = badLocation(of: path) else { return }

        let a = NSAlert()
        a.messageText = String(localized: "Move sAiity to the Applications folder?")
        a.informativeText = String(
            localized: "sAiity is running from \(source). From Applications, the Screen Recording permission sticks across launches and updates can install themselves. This is one copy, done once.")
        a.addButton(withTitle: String(localized: "Move to Applications"))
        a.addButton(withTitle: String(localized: "Not Now"))
        // AppKit's own suppression checkbox, with its own localized title.
        a.showsSuppressionButton = true
        ForegroundActivation.begin()
        defer { ForegroundActivation.end() }
        let response = a.runModal()
        if a.suppressionButton?.state == .on {
            UserDefaults.standard.set(true, forKey: suppressKey)
        }
        guard response == .alertFirstButtonReturn else { return }
        performMove(from: path)
    }

    /// A launch location that deserves the offer, described for the alert —
    /// or nil from anywhere sensible (Applications, a dev build directory).
    private static func badLocation(of path: String) -> String? {
        guard !path.hasPrefix("/Applications/") else { return nil }
        if path.hasPrefix("/Volumes/") {
            return String(localized: "the disk image")
        }
        if path.contains("/AppTranslocation/") {
            return String(localized: "a temporary location")
        }
        let fm = FileManager.default
        for dir: FileManager.SearchPathDirectory in [.downloadsDirectory, .desktopDirectory] {
            if let base = fm.urls(for: dir, in: .userDomainMask).first?.path,
               path.hasPrefix(base + "/") {
                return dir == .downloadsDirectory
                    ? String(localized: "the Downloads folder")
                    : String(localized: "the Desktop")
            }
        }
        return nil
    }

    private static func performMove(from path: String) {
        let fm = FileManager.default
        let src = URL(fileURLWithPath: path)
        let dest = URL(fileURLWithPath: "/Applications")
            .appendingPathComponent(src.lastPathComponent)
        // Always stage, then install — including the fresh-install case, which
        // used to copy straight to the destination. FileManager does not clean
        // up a partially written destination, so a copy that died mid-way (a
        // full disk is the realistic cause; this bundle carries llama and MLX)
        // left a truncated sAiity.app in /Applications that launches to a
        // crash. Staging inside /Applications, not /tmp, keeps the final step
        // a same-volume rename rather than a second full copy.
        let staging = URL(fileURLWithPath: "/Applications")
            .appendingPathComponent(".sAiity-staging-\(UUID().uuidString)")
        let staged = staging.appendingPathComponent(src.lastPathComponent)
        defer { try? fm.removeItem(at: staging) }
        do {
            try fm.createDirectory(at: staging, withIntermediateDirectories: true)
            try fm.copyItem(at: src, to: staged)
            if fm.fileExists(atPath: dest.path) {
                // The old app stays intact until the new one is in place.
                _ = try fm.replaceItemAt(dest, withItemAt: staged)
            } else {
                try fm.moveItem(at: staged, to: dest)
            }
        } catch {
            let fail = NSAlert()
            fail.messageText = String(localized: "Could not move sAiity")
            fail.informativeText = error.localizedDescription
            fail.addButton(withTitle: String(localized: "OK"))
            fail.runModal()
            return
        }

        // A writable original (Downloads, Desktop) goes to the Trash so the
        // stale copy cannot be launched by habit next week — recoverable, not
        // deleted. The disk image is read-only and simply gets ejected by the
        // user; a translocated path is not the real original at all.
        if !path.hasPrefix("/Volumes/"), !path.contains("/AppTranslocation/") {
            try? fm.trashItem(at: src, resultingItemURL: nil)
        }

        NSLog("sAiity moved to /Applications; relaunching from there")
        let cfg = NSWorkspace.OpenConfiguration()
        cfg.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: dest, configuration: cfg) { _, _ in
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
    }
}
