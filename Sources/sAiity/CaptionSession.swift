import Foundation
import Observation

/// A thin bridge between the running caption session and the Settings window.
///
/// Deleting a model is only safe when nothing is holding it open. Unlinking a
/// file that CoreML or llama.cpp has mmap'd *succeeds* — the engine keeps
/// running from the now-nameless inode and the blocks are not returned until the
/// last descriptor closes. So an app that deletes under a live session reports
/// "removed" while the disk does not move an inch. Nothing in the Settings
/// window could previously even tell whether captions were running.
@MainActor
@Observable
final class CaptionSession {
    static let shared = CaptionSession()

    private(set) var isRunning = false

    /// Installed by `AppDelegate` at launch: stop the session and release every
    /// loaded model. Kept as a closure so the Settings window does not need a
    /// reference to the app delegate.
    @ObservationIgnored
    var releaseModels: (@MainActor @Sendable () async -> Void)?

    private init() {}

    func setRunning(_ on: Bool) { isRunning = on }

    /// Drop every loaded model so its files can actually be removed. No-op when
    /// nothing is loaded.
    func releaseEverything() async {
        await releaseModels?()
    }
}
