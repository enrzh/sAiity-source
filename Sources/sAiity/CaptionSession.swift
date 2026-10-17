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
    private(set) var isStopping = false
    private(set) var isRemovingModels = false
    func setRemovingModels(_ on: Bool) { isRemovingModels = on }
    private(set) var translationBacklogged = false
    func setTranslationBacklogged(_ on: Bool) { translationBacklogged = on }

    /// Installed by `AppDelegate` at launch: stop the session and release every
    /// loaded model. Kept as a closure so the Settings window does not need a
    /// reference to the app delegate.
    @ObservationIgnored
    var releaseModels: (@MainActor @Sendable () async -> Void)?

    private init() {}

    func setRunning(_ on: Bool, stopping: Bool = false) {
        isRunning = on
        isStopping = on && stopping
        if !on { translationBacklogged = false }
    }

    /// True while a saved transcript is being re-translated.
    ///
    /// The rule "only one translator at a time" was written one-directionally
    /// — re-translation refused to start during a session, but a session was
    /// free to start during a re-translation, which is the same two models in
    /// memory at once by the other route. This is the other half.
    private var retranslationRuns = 0
    var isRetranslating: Bool { retranslationRuns > 0 }
    func beginRetranslation() { retranslationRuns += 1 }
    func endRetranslation() { retranslationRuns = max(0, retranslationRuns - 1) }

    private(set) var isSummarizing = false
    func setSummarizing(_ on: Bool) { isSummarizing = on }
    var isProcessingTranscript: Bool { isRetranslating || isSummarizing }

    var transcriptWorkMessage: String.LocalizationValue {
        isSummarizing
            ? "Summarizing a saved transcript — wait for that to finish, or cancel it"
            : "Translating a saved transcript — wait for that to finish, or cancel it"
    }

    /// Drop every loaded model so its files can actually be removed. No-op when
    /// nothing is loaded.
    func releaseEverything() async {
        await releaseModels?()
    }
}
