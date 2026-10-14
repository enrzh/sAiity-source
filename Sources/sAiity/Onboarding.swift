import AppKit
import CoreAudio

extension DictationInputHealth {
    var trialHint: String {
        guard observedDuration >= 2 else {
            return String(localized: "Speak a short sentence to check this microphone.")
        }
        guard let rmsDBFS, !rmsDBFS.isNaN else {
            return String(localized: "Audio level is unavailable. The dictation result is still the useful check.")
        }
        // shortcut: observational thresholds only; calibrate on approved microphones before quality claims.
        if clippedSampleFraction > 0.01 {
            return String(localized: "Input may be clipping. Lower the microphone input level.")
        }
        if rmsDBFS < -50 {
            return String(localized: "Input is very quiet. Check the microphone or move closer.")
        }
        return String(localized: "Audio input detected. Review the words below to check recognition.")
    }
}
import CoreGraphics
import ScreenCaptureKit

/// First-run state.
///
/// A versioned Int rather than a Bool, so a later release can re-run the setup
/// for a step that did not exist before without wiping what the user already
/// chose.
enum Onboarding {
    static let currentVersion = 1

    private static let completedKey = "onboardingCompletedVersion"
    private static let dismissedKey = "onboardingDismissedVersion"
    static let resumeKey = "onboardingResumeStep"

    static var needsRun: Bool {
        if TestHooks.forceOnboarding { return true }
        let d = UserDefaults.standard
        return d.integer(forKey: completedKey) < currentVersion
            && d.integer(forKey: dismissedKey) < currentVersion
    }

    static func complete() {
        UserDefaults.standard.set(currentVersion, forKey: completedKey)
        UserDefaults.standard.removeObject(forKey: resumeKey)
    }

    /// Closed without finishing. Distinct from completing: it must not nag on
    /// every launch, but it also should not claim the setup was done.
    static func dismiss() {
        UserDefaults.standard.set(currentVersion, forKey: dismissedKey)
    }

    /// Whether this install has run before, as opposed to being brand new.
    ///
    /// Both finishing and dismissing write a version, so either one means the
    /// user has already been here and made whatever choices 2.5.5 defaulted for
    /// them. That is the discriminator a migration needs when the preference it
    /// cares about was never written — see `AppState.resolveDictationEnabled`.
    static var hasLaunchedBefore: Bool {
        let d = UserDefaults.standard
        return d.integer(forKey: completedKey) >= 1 || d.integer(forKey: dismissedKey) >= 1
    }

    /// Where to pick up after a relaunch forced by the permission step. Not on
    /// the @Defaults wrapper: the value is optional, and "no stored value" and
    /// "stored none" must stay distinguishable.
    static var resumeStep: OnboardingStep? {
        get { UserDefaults.standard.string(forKey: resumeKey).flatMap(OnboardingStep.init(rawValue:)) }
        set { UserDefaults.standard.set(newValue?.rawValue, forKey: resumeKey) }
    }

    /// Re-run from Settings.
    static func reset() {
        let d = UserDefaults.standard
        d.removeObject(forKey: completedKey)
        d.removeObject(forKey: dismissedKey)
    }
}

enum OnboardingStep: String, CaseIterable {
    case permission, setup, finish

    // The old raw values remain decodable for an interrupted v1 wizard, but
    // the new flow exposes only the three decisions that matter.
    case welcome, purpose, models

    static var allCases: [OnboardingStep] { [.setup, .permission, .finish] }

    var title: String {
        switch self {
        case .welcome: return String(localized: "Welcome")
        case .permission: return String(localized: "Permission")
        case .setup: return String(localized: "Setup")
        case .purpose: return String(localized: "Setup")
        case .models: return String(localized: "Setup")
        case .finish: return String(localized: "Try it out")
        }
    }
}

/// Puts the app in the Dock for as long as a real window is open.
///
/// sAiity is an `LSUIElement` agent, which means no menu bar of its own: no ⌘Q,
/// no ⌘W, no ⌘-Tab, and a window that slips behind another cannot be brought
/// back. That is survivable for a settings window the user just opened; it is
/// not survivable for a five-step wizard.
@MainActor
enum ForegroundActivation {
    private static var count = 0

    static func begin() {
        count += 1
        if count == 1 { NSApp.setActivationPolicy(.regular) }
        NSApp.activate()
    }

    static func end() {
        count = max(0, count - 1)
        if count == 0 { NSApp.setActivationPolicy(.accessory) }
    }
}

/// Screen Recording is how macOS gates system audio — there is no separate
/// system-audio permission.
enum ScreenRecordingPermission {
    /// Cheap, and can go stale inside a running process.
    static var preflight: Bool { CGPreflightScreenCaptureAccess() }

    /// Raises the system prompt. Only effective the first time; afterwards macOS
    /// silently ignores it and the user has to go to System Settings.
    static func request() { CGRequestScreenCaptureAccess() }

    /// Ground truth: actually try to enumerate shareable content. `preflight`
    /// alone is what makes apps tell users to relaunch when they need not.
    static func probe() async -> Bool {
        ((try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false))
            != nil)
    }

    static func openSettings() {
        if let u = URL(string:
            "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(u)
        }
    }

    /// Only meaningful for a real app bundle — a bare SwiftPM binary has nothing
    /// for LaunchServices to reopen.
    static var canRelaunch: Bool {
        Bundle.main.bundleIdentifier != nil && Bundle.main.bundleURL.pathExtension == "app"
    }

    static func relaunch() {
        Onboarding.resumeStep = .permission
        let cfg = NSWorkspace.OpenConfiguration()
        cfg.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: cfg) { _, _ in
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
    }
}

/// Input Monitoring is only relevant when the user chooses press-to-talk
/// dictation. Keep its request beside the other onboarding permission helpers
/// so the wizard does not need to know any System Settings URL details.
enum InputMonitoringPermission {
    static var preflight: Bool { CGPreflightListenEventAccess() }

    static func request() { _ = CGRequestListenEventAccess() }

    static func openSettings() {
        if let url = URL(string:
            "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent") {
            NSWorkspace.shared.open(url)
        }
    }
}
