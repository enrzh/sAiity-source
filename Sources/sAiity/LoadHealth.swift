import Foundation
import CTranscribe

/// Records "the bytes are on disk, but they did not load" per asset.
///
/// Presence checks are marker-file-thin — Nemotron's `isDownloaded()` is a
/// single metadata.json existence test, a GGUF just has to exist — so a
/// corrupted tree passes them forever: every Start repeats the same load
/// error in the status line while the Models page shows the asset as
/// installed, with only a generic Delete nobody has a reason to connect to
/// the failure. The app knows exactly which asset refused to load; this is
/// where it says so, and the Models row turns it into the one recovery path
/// that exists: delete the damaged files and fetch them again.
///
/// An entry is written when a load fails for an asset whose files are
/// present, and cleared by the three things that change the story: a
/// successful load, a fresh download, deletion.
enum LoadHealth {
    private static let key = "assetLoadFailures"
    static let changed = Notification.Name("saiityLoadHealthChanged")

    static var all: [String: String] {
        UserDefaults.standard.dictionary(forKey: key) as? [String: String] ?? [:]
    }

    static func reason(for assetID: String) -> String? { all[assetID] }
    static func shouldRecordLoadFailure(_ error: Error) -> Bool {
        if error is CancellationError { return false }
        if let error = error as? URLError, error.code == .cancelled { return false }
        if let error = error as? TranslationEngineError, case .runtimeUnavailable = error { return false }
        if let error = error as? GraniteASRBackend.Failure {
            switch error {
            case .invalidModelIdentity: return true
            case .native(let status, _, _):
                return [TRANSCRIBE_ERR_GGUF, TRANSCRIBE_ERR_UNSUPPORTED_ARCH, TRANSCRIBE_ERR_UNSUPPORTED_VARIANT]
                    .contains { Int32(bitPattern: $0.rawValue) == status }
            default: return false
            }
        }
        return true
    }

    /// Record only when the asset's files are actually present — a failure to
    /// load what was never downloaded is not damage, it is the normal
    /// not-installed state every other surface already explains.
    static func recordFailureIfInstalled(_ assetID: String, reason: String) {
        guard let asset = ModelRegistry.assets().first(where: { $0.id == assetID }),
              ModelRegistry.isInstalled(asset) else { return }
        var t = all
        guard t[assetID] != reason else { return }
        t[assetID] = reason
        UserDefaults.standard.set(t, forKey: key)
        NotificationCenter.default.post(name: changed, object: nil)
    }

    static func clear(_ assetID: String) {
        var t = all
        guard t.removeValue(forKey: assetID) != nil else { return }
        UserDefaults.standard.set(t, forKey: key)
        NotificationCenter.default.post(name: changed, object: nil)
    }
}
