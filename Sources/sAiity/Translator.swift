import Foundation
import Translation

/// On-device translation of finished caption lines.
///
/// Apple's Translation framework runs entirely locally once a language pair is
/// installed, which is the whole point here — the audio never left the machine
/// during recognition and the text must not leave it during translation either.
///
/// Two constraints shape this file:
///   - It needs a real app bundle. In a bare command-line binary even
///     `LanguageAvailability.status` never returns, because the framework talks
///     to a per-app daemon over XPC.
///   - `TranslationSession(installedSource:target:)` only works for pairs already
///     downloaded. `.supported` (as opposed to `.installed`) means the user must
///     fetch it first in System Settings → Translation Languages; we surface that
///     rather than hanging on a prompt that has no UI to appear in.
actor Translator {
    enum Availability {
        case installed
        case needsDownload
        case unsupported
    }

    private var session: TranslationSession?
    private var pair: String = ""

    /// Nil target = translation off.
    private(set) var target: Locale.Language?

    func setTarget(_ language: Locale.Language?) {
        target = language
        session = nil
        pair = ""
    }

    func availability(from source: Locale.Language) async -> Availability {
        guard let target else { return .unsupported }
        switch await LanguageAvailability().status(from: source, to: target) {
        case .installed: return .installed
        case .supported: return .needsDownload
        case .unsupported: return .unsupported
        @unknown default: return .unsupported
        }
    }

    /// Returns nil when translation is off or the pair is not installed, so the
    /// caller can fall back to showing the original line.
    func translate(_ text: String, from source: Locale.Language) async -> String? {
        guard let target else { return nil }
        let key = "\(source.minimalIdentifier)->\(target.minimalIdentifier)"

        if session == nil || pair != key {
            guard await availability(from: source) == .installed else { return nil }
            session = TranslationSession(installedSource: source, target: target)
            pair = key
        }
        guard let session else { return nil }
        return try? await session.translate(text).targetText
    }
}
