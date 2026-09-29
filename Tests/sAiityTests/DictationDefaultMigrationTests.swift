import Foundation
import Testing

@testable import sAiity

/// The dictation default, and who it applies to.
///
/// This is a migration, and the failure it guards is silent: press-to-talk was
/// **on by default in 2.5.5**, so a user who accepted that default never wrote
/// a preference. The key is simply absent for them. Reading "absent" as "off"
/// therefore switched off the hotkey of exactly the users least likely to
/// notice why, with nothing on screen to say so.
@Suite("Dictation default migration")
struct DictationDefaultMigrationTests {
    private static let keys = ["dictationEnabled",
                               "onboardingCompletedVersion", "onboardingDismissedVersion"]

    /// Runs `body` with the preference store set to `values`, then restores it.
    private func withDefaults(_ values: [String: Any?], _ body: () -> Void) {
        let defaults = UserDefaults.standard
        let snapshot = Self.keys.map { ($0, defaults.object(forKey: $0)) }
        defer {
            snapshot.forEach { key, value in
                if let value { defaults.set(value, forKey: key) }
                else { defaults.removeObject(forKey: key) }
            }
        }
        Self.keys.forEach { defaults.removeObject(forKey: $0) }
        values.forEach { key, value in
            if let value { defaults.set(value, forKey: key) }
        }
        body()
    }

    @Test("a user who already chose keeps their choice")
    func explicitChoiceIsKept() {
        withDefaults(["dictationEnabled": true, "onboardingCompletedVersion": 1]) {
            #expect(AppState.resolveDictationEnabled())
        }
        withDefaults(["dictationEnabled": false, "onboardingCompletedVersion": 1]) {
            #expect(!AppState.resolveDictationEnabled())
        }
    }

    /// The regression. This install ran before, so dictation was on by default
    /// and no preference was ever written. It must still resolve to on.
    @Test("an install that ran before keeps dictation on without a stored value")
    func existingInstallKeepsTheOldDefault() {
        withDefaults(["onboardingCompletedVersion": 1]) {
            #expect(AppState.resolveDictationEnabled(),
                    "an accepted 2.5.5 default must not be read as a decision to turn it off")
        }
        // Dismissed counts too: dismissing still means the user has been here.
        withDefaults(["onboardingDismissedVersion": 1]) {
            #expect(AppState.resolveDictationEnabled())
        }
    }

    @Test("a fresh install opts in to press-to-talk")
    func freshInstallStartsOff() {
        withDefaults([:]) {
            #expect(!AppState.resolveDictationEnabled(),
                    "an always-listening global shortcut should be a decision, not an inherited default")
        }
    }

    /// The `didSet` only writes when the value changes, so an install that
    /// resolves to what it loaded would otherwise persist nothing and leave the
    /// next release facing the identical ambiguity.
    @Test("the resolved answer is written down so the ambiguity cannot recur")
    func resolutionIsPersisted() {
        withDefaults(["onboardingCompletedVersion": 1]) {
            #expect(UserDefaults.standard.object(forKey: "dictationEnabled") == nil)
            _ = AppState.resolveDictationEnabled()
            #expect(UserDefaults.standard.object(forKey: "dictationEnabled") as? Bool == true,
                    "the migration must leave an explicit value behind")
        }
    }

    @Test("an install that ran before is recognised from either marker")
    func launchMarker() {
        withDefaults([:]) { #expect(!Onboarding.hasLaunchedBefore) }
        withDefaults(["onboardingCompletedVersion": 1]) { #expect(Onboarding.hasLaunchedBefore) }
        withDefaults(["onboardingDismissedVersion": 1]) { #expect(Onboarding.hasLaunchedBefore) }
    }
}
