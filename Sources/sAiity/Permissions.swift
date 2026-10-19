import AVFoundation
import AppKit
import ApplicationServices
import CoreGraphics

/// The macOS permissions Syllivra can need, described once.
///
/// Setup, General settings and the dictation messages each used to carry their
/// own copy of these checks, with different wording and different buttons. One
/// of them never asked for the microphone at all, which is how a press of the
/// dictation shortcut could do nothing without saying why.
enum AppPermission: String, CaseIterable, Identifiable, Sendable {
    case microphone, accessibility, inputMonitoring, screenRecording

    var id: String { rawValue }

    /// The name System Settings uses, so the user can find the same row there.
    var title: String {
        switch self {
        case .microphone: String(localized: "Microphone")
        case .accessibility: String(localized: "Accessibility")
        case .inputMonitoring: String(localized: "Input Monitoring")
        case .screenRecording: String(localized: "Screen & System Audio Recording")
        }
    }

    /// What Syllivra does with it, in one short sentence.
    var purpose: String {
        switch self {
        case .microphone: String(localized: "Hears you while you hold the dictation shortcut.")
        case .accessibility: String(localized: "Types the dictated text into the app you are using.")
        case .inputMonitoring: String(localized: "Notices the dictation shortcut in every app.")
        case .screenRecording: String(localized: "Hears what your Mac plays, for captions. Nothing is recorded.")
        }
    }

    /// Which feature it belongs to, so a captions-only user is not asked for
    /// dictation permissions and the other way round.
    var feature: Feature {
        switch self {
        case .microphone, .accessibility, .inputMonitoring: .dictation
        case .screenRecording: .captions
        }
    }

    enum Feature: Sendable { case dictation, captions }

    enum Status: Equatable, Sendable {
        case granted
        /// macOS has not asked yet, so asking shows its prompt.
        case notAsked
        /// Turned off, or macOS will not prompt again: only System Settings
        /// can change it.
        case off
    }

    var status: Status {
        switch self {
        case .microphone:
            switch AVCaptureDevice.authorizationStatus(for: .audio) {
            case .authorized: .granted
            case .notDetermined: .notAsked
            default: .off
            }
        case .accessibility:
            AXIsProcessTrusted() ? .granted : .off
        case .inputMonitoring:
            CGPreflightListenEventAccess() ? .granted : .off
        case .screenRecording:
            CGPreflightScreenCaptureAccess() ? .granted : .off
        }
    }

    /// Asks macOS. The first time, that shows macOS's own prompt. macOS shows
    /// those prompts once and then stays silent, so every later request opens
    /// the right list in System Settings instead of appearing to do nothing.
    @MainActor
    func request(defaults: UserDefaults = .standard) {
        let askedKey = "permissionAsked.\(rawValue)"
        if self == .microphone {
            if status == .notAsked {
                AVCaptureDevice.requestAccess(for: .audio) { _ in }
            } else {
                openSettings()
            }
            return
        }
        guard !defaults.bool(forKey: askedKey) else {
            openSettings()
            return
        }
        defaults.set(true, forKey: askedKey)
        switch self {
        case .accessibility:
            let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(options)
        case .inputMonitoring:
            _ = CGRequestListenEventAccess()
        case .screenRecording:
            _ = CGRequestScreenCaptureAccess()
        case .microphone:
            break
        }
    }

    var settingsURL: URL? {
        let pane = switch self {
        case .microphone: "Privacy_Microphone"
        case .accessibility: "Privacy_Accessibility"
        case .inputMonitoring: "Privacy_ListenEvent"
        case .screenRecording: "Privacy_ScreenCapture"
        }
        return URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)")
    }

    @MainActor
    func openSettings() {
        if let settingsURL { NSWorkspace.shared.open(settingsURL) }
    }
}
