import AppKit
import CoreGraphics
import Foundation
import SwiftUI

// MARK: - Pure reporting

/// One thing the smoke test looked at.
struct LaunchSmokeCheck: Equatable {
    let name: String
    let passed: Bool
    let detail: String

    init(_ name: String, passed: Bool, detail: String) {
        self.name = name
        self.passed = passed
        self.detail = detail
    }
}

/// What the checks mean, and what the process should exit with.
///
/// Deliberately free of AppKit and of the run itself, because a smoke test that
/// cannot report a failure is worse than none: CI goes green on a bundle that
/// never launched, and the green is the whole point of the check.
enum LaunchSmokeReport {
    static let okMarker = "saiity-selftest: ok"
    static let failMarker = "saiity-selftest: FAILED"
    static let skipMarker = "saiity-selftest: skipped"
    static let hangMarker = "saiity-selftest: timed out"

    /// Distinct exit codes so a CI log says which thing went wrong: 1 is a real
    /// launch failure, 70 (EX_SOFTWARE) is a launch that never finished.
    static let okExit: Int32 = 0
    static let failureExit: Int32 = 1
    static let hangExit: Int32 = 70

    enum Outcome: Equatable {
        case ok
        case failed([LaunchSmokeCheck])
        case skipped(String)
    }

    static func outcome(for checks: [LaunchSmokeCheck]) -> Outcome {
        let failed = checks.filter { !$0.passed }
        return failed.isEmpty ? .ok : .failed(failed)
    }

    /// A skip is a success. There is no window server to draw into over a plain
    /// ssh session, and that is a fact about the session, not a defect in the
    /// bundle — failing here would mean the check can only ever run on a
    /// machine with a monitor attached.
    static func exitCode(for outcome: Outcome) -> Int32 {
        switch outcome {
        case .ok, .skipped: okExit
        case .failed: failureExit
        }
    }

    /// The whole report: one line per check, then the marker. Written in one
    /// function so the marker can never be printed without the checks that
    /// justify it, or the other way round.
    static func report(for outcome: Outcome, checks: [LaunchSmokeCheck]) -> [String] {
        switch outcome {
        case .skipped(let reason):
            return ["\(skipMarker) (\(reason))"]
        case .ok, .failed:
            var lines = checks.map {
                "\($0.passed ? "pass" : "FAIL")  \($0.name) — \($0.detail)"
            }
            lines.append(marker(for: outcome))
            return lines
        }
    }

    /// Named `emit` rather than `print`, which would shadow the standard one
    /// inside this type and make every call site in it ambiguous.
    static func emit(_ outcome: Outcome, checks: [LaunchSmokeCheck] = []) {
        for line in report(for: outcome, checks: checks) { print(line) }
        // The process exits immediately afterwards; a block-buffered stdout
        // would otherwise hold the verdict until the very end of the run.
        fflush(stdout)
    }

    private static func marker(for outcome: Outcome) -> String {
        switch outcome {
        case .ok: okMarker
        case .failed: failMarker
        case .skipped: skipMarker
        }
    }
}

// MARK: - The run

/// A real launch of the app, bounded in time, from a script.
///
/// `--version` proves the binary links, starts and can read its own bundle. It
/// touches no AppKit: no `NSApplication`, no window server, no run loop. A
/// menu-bar app can fail every one of those ways and still answer `--version`
/// perfectly — that is the failure this exists to catch, and it is invisible to
/// `swift test` because a unit test bundle has no window server either.
///
/// So this launches the genuine application: the real `AppDelegate`, the real
/// main menu, the real `applicationDidFinishLaunching`, and a real turn of the
/// run loop that `app.run()` owns. Then it exits with a verdict.
@MainActor
final class LaunchSmokeTest {
    /// How long the post-launch checks may spin the run loop before the app is
    /// called wedged.
    private static let spinLimit: TimeInterval = 5

    /// The selectors the Edit menu must route. A menu-bar app has no menu bar
    /// of its own, so without this menu the standard editing shortcuts do
    /// nothing in any text field the app shows.
    ///
    /// The spelling matters and was taken from the real selectors, not from
    /// what the shortcut ought to be called: `NSText.selectAll(_:)` is
    /// `selectAll:`, and an expectation of `selectPasteboard:` here reported a
    /// healthy menu as broken. A check that fails on a working build trains
    /// people to ignore it.
    private static let editingSelectors: Set<String> = [
        "undo:", "redo:", "cut:", "copy:", "paste:", "selectAll:",
    ]

    /// The observer below holds a weak reference, and nothing else outlives the
    /// launch, so the test keeps itself alive.
    private static var active: LaunchSmokeTest?

    /// True inside an Aqua login session. `NSApplication` needs a window server;
    /// without one it is not a launch failure, it is a session that cannot
    /// launch a GUI at all.
    nonisolated static var hasWindowServerSession: Bool {
        CGSessionCopyCurrentDictionary() != nil
    }

    private let timeout: TimeInterval
    private var checks: [LaunchSmokeCheck] = []

    private init(timeout: TimeInterval) {
        self.timeout = timeout
    }

    /// Arms the smoke test, or reports a skip and exits 0 when there is no
    /// window server to launch into.
    ///
    /// Call this BEFORE `app.run()`. NSApplication posts
    /// `didFinishLaunchingNotification` from inside `run()`, after
    /// `applicationDidFinishLaunching` returns, so an observer registered
    /// afterwards would never see the launch finish.
    nonisolated static func armOrSkip(timeout: TimeInterval) {
        guard hasWindowServerSession else {
            LaunchSmokeReport.emit(.skipped("no window server — not an Aqua login session"))
            exit(LaunchSmokeReport.okExit)
        }
        MainActor.assumeIsolated { arm(timeout: timeout) }
    }

    private static func arm(timeout: TimeInterval) {
        let test = LaunchSmokeTest(timeout: timeout)
        active = test
        test.observeLaunch()
        test.startWatchdog()
    }

    private func observeLaunch() {
        NotificationCenter.default.addObserver(
            forName: NSApplication.didFinishLaunchingNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            // Delivered on the main run loop, which is running precisely
            // because app.run() is executing — so this is the main actor's
            // thread, and MainActor.assumeIsolated states that rather than
            // scheduling work that might not run before the watchdog fires.
            MainActor.assumeIsolated { self?.conclude() }
        }
    }

    /// A launch that never finishes must fail the run, not hang it. No unwinding
    /// and no cleanup: the point is to leave nothing half-initialised behind.
    private func startWatchdog() {
        let timeout = self.timeout
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout) {
            let seconds = Int(timeout)
            FileHandle.standardError.write(Data(
                "\(LaunchSmokeReport.hangMarker) — no finished launch within \(seconds)s\n".utf8))
            _exit(LaunchSmokeReport.hangExit)
        }
    }

    /// Runs the checks and leaves. Never returns.
    private func conclude() {
        // The launch body itself. Everything else here is downstream of this
        // one notification: had applicationDidFinishLaunching trapped,
        // blocked or thrown, none of the rest would have been reached.
        record("launch body completed", true, detail: "applicationDidFinishLaunching returned")
        record("app delegate installed", NSApp.delegate is AppDelegate,
               detail: NSApp.delegate.map { "\(type(of: $0))" } ?? "no delegate")
        // The last two are the checks that reach past this process: a run loop
        // that actually turns, and a window the window server agrees exists.
        record("edit menu routes the standard shortcuts", hasEditingMenu())
        record("run loop turns", runOneTurn())
        record("window server reachable", orderAWindow())
        exerciseUserSurfaces()
        finish(with: LaunchSmokeReport.outcome(for: checks))
    }

    /// Never returns: the process ends here, one way or the other.
    private func finish(with outcome: LaunchSmokeReport.Outcome) {
        LaunchSmokeReport.emit(outcome, checks: checks)
        // Straight out, rather than through NSApp.terminate: terminate always
        // exits 0, which would turn a failed launch into a green run — the one
        // thing a smoke test must not do. The app is exiting anyway, so the
        // orderly teardown NSApp.terminate would buy is worth nothing here.
        exit(LaunchSmokeReport.exitCode(for: outcome))
    }

    private func record(_ name: String, _ passed: Bool, detail: String) {
        checks.append(LaunchSmokeCheck(name, passed: passed, detail: detail))
    }

    /// For the checks that describe their own evidence, so the reason lands in
    /// the CI log next to the verdict rather than only in this file.
    private func record(_ name: String, _ result: (passed: Bool, detail: String)) {
        checks.append(LaunchSmokeCheck(name, passed: result.passed, detail: result.detail))
    }

    /// The Edit menu is checked by ACTION, not by title. The titles come from
    /// the localization catalog, so a title check would fail for every user
    /// running sAiity in German — and pass for a menu that routes nothing.
    ///
    /// The detail names what is missing rather than just returning false: "the
    /// Edit menu is wrong" is not an actionable CI failure, "unrouted:
    /// selectAll:" is.
    private func hasEditingMenu() -> (passed: Bool, detail: String) {
        let routed = NSApp.mainMenu?.items
            .compactMap { $0.submenu?.items.compactMap { $0.action?.description } }
            .flatMap { $0 } ?? []
        let missing = Self.editingSelectors.subtracting(routed).sorted()
        return missing.isEmpty
            ? (true, "\(Self.editingSelectors.count) standard shortcuts routed")
            : (false, "unrouted: \(missing.joined(separator: ", "))")
    }

    /// One turn of the run loop: a block posted to the main queue has to run
    /// while `app.run()` holds the loop. This app does essentially all of its
    /// work from main-queue blocks and timers, so a loop that never turns is a
    /// frozen app that still answers `--version` perfectly.
    private func runOneTurn() -> (passed: Bool, detail: String) {
        let turned = TurnFlag()
        DispatchQueue.main.async { turned.value = true }
        let deadline = Date().addingTimeInterval(Self.spinLimit)
        while !turned.value, Date() < deadline {
            _ = RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
        }
        return turned.value
            ? (true, "a main-queue block ran inside app.run()")
            : (false, "no main-queue block ran within \(Int(Self.spinLimit))s")
    }

    /// A real `NSWindow`, ordered in and straight back out. This is the check
    /// that reaches past the process into the window server, which is the part
    /// a hand-assembled or quarantine-broken bundle gets wrong while every
    /// other check in the repository stays green.
    private func orderAWindow() -> (passed: Bool, detail: String) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 200),
                              styleMask: [.titled, .closable],
                              backing: .buffered, defer: false)
        window.title = "sAiity selftest"
        window.orderFront(nil)
        let shown = window.isVisible
        window.orderOut(nil)
        window.close()
        return shown
            ? (true, "ordered a window in and out")
            : (false, "the window never became visible")
    }

    /// Real native views and presentation transitions, without audio capture,
    /// model downloads, clipboard writes or permanent settings changes.
    private func exerciseUserSurfaces() {
        let defaults = UserDefaults.standard
        let keys = [CaptionStyle.key, CaptionStyle.dictationKey, "captionFrame",
                    "captionUserWidth", "dictationToastFrame", "onboardingResumeStep"]
        let saved = keys.map { ($0, defaults.object(forKey: $0)) }
        let captionStyle = CaptionStyle.current
        let dictationStyle = CaptionStyle.currentDictation
        defer {
            CaptionStyle.current = captionStyle
            CaptionStyle.currentDictation = dictationStyle
            for (key, value) in saved {
                if let value { defaults.set(value, forKey: key) }
                else { defaults.removeObject(forKey: key) }
            }
        }
        let caption = OverlayWindow()
        let dictation = DictationToastWindow(contentRect: .zero, styleMask: [.borderless],
                                            backing: .buffered, defer: false)
        caption.isReleasedWhenClosed = false
        dictation.isReleasedWhenClosed = false
        for preset in BubbleStylePreset.allCases {
            var style = preset.applying(to: captionStyle, context: .captions)
            style.hidden = false
            CaptionStyle.current = style
            CaptionStyle.currentDictation = preset.applying(to: dictationStyle, context: .dictation)
            _ = runOneTurn()
            caption.applyStyle(style)
            caption.show(text: "First caption.", isFinal: true, sentenceID: 1)
            caption.showTranslation("Erster Untertitel.", forSentenceID: 1)
            caption.show(text: "A later caption appears below it.", isFinal: true, sentenceID: 2)
            caption.contentView?.layoutSubtreeIfNeeded()
            record("caption bubble \(preset.rawValue)", caption.isVisible && caption.frame.width > 0,
                   detail: "original, translation and following caption presented")
            caption.clearHistory(keepVisible: true)
            caption.show(text: "Captions continue after Clear.", isFinal: true, sentenceID: 3)
            record("caption clear \(preset.rawValue)", caption.isVisible,
                   detail: "clear followed by new content kept the bubble visible")

            dictation.show(phase: .dictating)
            let compact = dictation.frame.size
            dictation.updateWaveform(Array(repeating: 0.7, count: 28))
            dictation.show(resultText: String(repeating: "Dictation result. ", count: 30), autoDismissAfter: nil)
            dictation.contentView?.layoutSubtreeIfNeeded()
            record("dictation result \(preset.rawValue)", dictation.isVisible && dictation.frame.height >= compact.height,
                   detail: "waveform changed to a long result")
            dictation.show(phase: .dictating)
            record("dictation reset \(preset.rawValue)", dictation.frame.size == compact,
                   detail: "next recording restored the compact bubble")
        }
        caption.clear()
        dictation.dismiss()
        caption.close()
        dictation.close()

        for useCase in OnboardingModel.UseCase.allCases {
            let model = OnboardingModel(state: SettingsWindowController.state)
            model.useCase = useCase
            model.step = .finish
            model.trialText = "A trial result stays here without replacing your clipboard."
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 600),
                                  styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentViewController = NSHostingController(rootView: OnboardingView(model: model, onFinish: {}))
            window.orderFront(nil)
            window.contentView?.layoutSubtreeIfNeeded()
            record("setup trial \(useCase.rawValue)", window.isVisible && window.contentView?.subviews.isEmpty == false,
                   detail: "native setup result and trial controls laid out")
            window.close()
        }
    }

    /// Written by the main queue and read on the main thread, which is the only
    /// thread that can read it: a captured `var` would be a data race the
    /// compiler is right to complain about and this is not.
    private final class TurnFlag {
        var value = false
    }
}
