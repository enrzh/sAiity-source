import AppKit
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
    private static let resumeKey = "onboardingResumeStep"

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
    case welcome, permission, purpose, models, finish

    var title: String {
        switch self {
        case .welcome: return "Welcome"
        case .permission: return "Permission"
        case .purpose: return "What for"
        case .models: return "Models"
        case .finish: return "Ready"
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
