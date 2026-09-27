import Foundation
import Testing

@testable import sAiity

/// The verdict logic of `--selftest`, which is the part CI reads.
///
/// A smoke test that cannot fail is worse than no smoke test: CI goes green on
/// a bundle that never launched. So the three states it can end in — passed,
/// failed, skipped — are pinned here, including the exit code for each.
struct LaunchSmokeReportTests {

    private let delegateOK = LaunchSmokeCheck("app delegate installed", passed: true, detail: "AppDelegate")
    private let windowBroken = LaunchSmokeCheck("window server reachable", passed: false,
                                                detail: "the window never became visible")

    @Test("every check passing is a pass")
    func allGreen() {
        let checks = [delegateOK, LaunchSmokeCheck("run loop turns", passed: true, detail: "ran")]
        #expect(LaunchSmokeReport.outcome(for: checks) == .ok)
        #expect(LaunchSmokeReport.exitCode(for: .ok) == 0)
    }

    @Test("one failed check fails the run and is reported")
    func oneFailureFailsTheRun() {
        let checks = [delegateOK, windowBroken]
        #expect(LaunchSmokeReport.outcome(for: checks) == .failed([windowBroken]))
        #expect(LaunchSmokeReport.exitCode(for: .failed([windowBroken])) == 1)
    }

    @Test("an empty run is vacuously green, which is why the run records its own checks")
    // The list cannot be empty in practice: `conclude` records the finished
    // launch itself before anything else, so reaching the report at all proves
    // the app launched. The test below pins that the *report* is where the
    // evidence has to come from, since a summary that printed only a marker
    // would look identical for a real pass and for a harness that checked
    // nothing.
    func emptyIsVacuous() {
        #expect(LaunchSmokeReport.outcome(for: []) == .ok)
        #expect(LaunchSmokeReport.report(for: .ok, checks: []).count == 1)
    }

    @Test("a skip is a success, with its reason stated")
    func skipIsSuccess() {
        // Over a plain ssh session there is no window server, which is a fact
        // about the session and not a defect in the bundle. Failing there would
        // mean the check can only ever run on a machine with a display.
        let outcome = LaunchSmokeReport.Outcome.skipped("no window server — not an Aqua login session")
        #expect(LaunchSmokeReport.exitCode(for: outcome) == 0)
        #expect(LaunchSmokeReport.report(for: outcome, checks: []).joined() == "saiity-selftest: skipped (no window server — not an Aqua login session)")
    }

    @Test("the report shows every check and ends on the marker")
    func reportShape() {
        let failing = LaunchSmokeReport.report(for: .failed([windowBroken]),
                                               checks: [delegateOK, windowBroken])
        #expect(failing.count == 3, "one line per check plus the marker")
        #expect(failing[0].hasPrefix("pass"), Comment(rawValue: failing[0]))
        #expect(failing[1].hasPrefix("FAIL"), Comment(rawValue: failing[1]))
        // The reason is in the output, not only in the source: a CI log has to
        // be able to answer "what broke" without a debugger.
        #expect(failing[1].contains("the window never became visible"))
        #expect(failing.last == LaunchSmokeReport.failMarker)

        let passing = LaunchSmokeReport.report(for: .ok, checks: [delegateOK])
        #expect(passing == ["pass  app delegate installed — AppDelegate",
                            LaunchSmokeReport.okMarker])
    }

    @Test("a hang is distinguishable from a failed check")
    func hangHasItsOwnExitCode() {
        // The watchdog exits directly. If that number ever became the same as
        // the failure code, a launch that never finished would be reported as
        // an ordinary launch failure and nobody would look for the hang.
        #expect(LaunchSmokeReport.hangExit == 70)
        #expect(LaunchSmokeReport.hangExit != LaunchSmokeReport.failureExit)
        #expect(LaunchSmokeReport.failureExit == 1)
    }
}
