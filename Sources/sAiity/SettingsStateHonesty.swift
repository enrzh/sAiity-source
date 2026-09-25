import Foundation

/// Stored settings that claim work the Mac cannot do.
///
/// Recognition stays unset until the recommended model is actually on disk.
/// Translation stays off while its target is Off. Cleanup stays off while its
/// model is not ready. Callers in Setup, Captions, and Dictation read the
/// corrected values instead of each inventing a fallback.
struct SettingsStateHonesty: Equatable {
    var recognition: ASREngine?
    var showCaptionTranslation: Bool
    var dictationTranslationEnabled: Bool
    var cleanupEnabled: Bool

    static func reconcile(recognition: ASREngine?,
                          recommendedRecognitionInstalled: Bool,
                          showCaptionTranslation: Bool,
                          captionTarget: String?,
                          dictationTranslationEnabled: Bool,
                          dictationTarget: String?,
                          cleanupEnabled: Bool,
                          cleanupReady: Bool) -> SettingsStateHonesty {
        SettingsStateHonesty(
            recognition: ASREngine.visibleSelection(recognition)
                ?? (recommendedRecognitionInstalled ? ASREngine.recommended : nil),
            showCaptionTranslation: showCaptionTranslation && !isOff(captionTarget),
            dictationTranslationEnabled: dictationTranslationEnabled && !isOff(dictationTarget),
            cleanupEnabled: cleanupEnabled && cleanupReady)
    }

    /// "Not set" only while no recognizer is chosen. A model that identifies
    /// the language from audio has no locale to display, so the row says Auto.
    static func languageLabel(for engine: ASREngine?) -> String {
        guard let engine else { return String(localized: "Not set") }
        // A legacy value is not a user-selectable English-only mode. Treat it
        // like the supported model's automatic language detection so an old
        // preference cannot leak retired engine copy into the UI.
        guard let visible = ASREngine.visibleSelection(engine) else {
            return String(localized: "Auto")
        }
        if visible.identifiesLanguageFromAudio { return String(localized: "Auto") }
        return String(localized: "English only")
    }

    private static func isOff(_ target: String?) -> Bool {
        target?.isEmpty != false
    }
}
