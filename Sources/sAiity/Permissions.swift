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

    /// Asks macOS, and from the second time on also opens the right list in
    /// System Settings.
    ///
    /// The request runs every time, not just the first: it is what puts *this*
    /// build into the System Settings list. A list entry left behind by an
    /// earlier copy of the app looks switched on but belongs to that copy's
    /// signature, and only a fresh request replaces it. macOS shows its own
    /// prompt at most once and then stays silent, which is why later requests
    /// also open System Settings instead of appearing to do nothing.
    @MainActor
    func request(defaults: UserDefaults = .standard) {
        if self == .microphone {
            if status == .notAsked {
                AVCaptureDevice.requestAccess(for: .audio) { _ in }
            } else {
                openSettings()
            }
            return
        }
        let askedKey = "permissionAsked.\(rawValue)"
        let askedBefore = defaults.bool(forKey: askedKey)
        defaults.set(true, forKey: askedKey)
        let granted: Bool
        switch self {
        case .accessibility:
            let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: !askedBefore] as CFDictionary
            granted = AXIsProcessTrustedWithOptions(options)
        case .inputMonitoring:
            granted = CGRequestListenEventAccess()
        case .screenRecording:
            granted = CGRequestScreenCaptureAccess()
        case .microphone:
            granted = true
        }
        if askedBefore, !granted { openSettings() }
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
