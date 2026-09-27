import Foundation
import Testing

@testable import sAiity

/// The CLI is the only part of the app that a script can drive, and it is the
/// part CI drives: build-app.sh and verify-release.sh both call the binary
/// directly. A dispatch table that has drifted from the documented verbs fails
/// a release check for a reason that looks like a broken bundle, so the table
/// is pinned here instead.
///
/// These are the pure ones. `LaunchSmokeTest`'s own verdict logic is pure too
/// and is covered in LaunchSmokeReportTests.
struct CommandLinePlanTests {

    @Test("no arguments is a normal launch")
    func noArgumentsLaunchesTheApp() {
        #expect(CommandLinePlan.parse(["/Applications/sAiity.app/Contents/MacOS/sAiity"]) == nil)
    }

    @Test("only a leading flag is a verb")
    func onlyTheFirstArgumentIsAVerb() {
        // A dropped document, or `open -a sAiity report.srt`. A path in any
        // later position is data, never a verb.
        #expect(CommandLinePlan.parse(["sAiity", "notes.md"]) == nil)
        #expect(CommandLinePlan.parse(["sAiity", "--list", "--export"]) == .list)
    }

    @Test("--version and --list are their own modes")
    func informationalVerbs() {
        #expect(CommandLinePlan.parse(["sAiity", "--version"]) == .version)
        #expect(CommandLinePlan.parse(["sAiity", "--list"]) == .list)
    }

    @Test("export defaults to plain text and takes an optional session id")
    func exportArguments() {
        #expect(CommandLinePlan.parse(["sAiity", "--export"]) == .export(format: "txt", sessionID: nil))
        #expect(CommandLinePlan.parse(["sAiity", "--export", "srt"]) == .export(format: "srt", sessionID: nil))
        #expect(CommandLinePlan.parse(["sAiity", "--export", "md", "2026-09-26T10-00-00"]) ==
                .export(format: "md", sessionID: "2026-09-26T10-00-00"))
    }

    @Test("a missing format falls back to text rather than eating the next verb")
    func exportWithoutAFormatDoesNotSwallowAVerb() {
        // `sAiity --export --list` used to take "--list" as the format and
        // export nothing the caller asked for. The old code also lost the
        // requested format whenever the session id came first, which is not an
        // order this CLI ever documents.
        #expect(CommandLinePlan.parse(["sAiity", "--export", "--list"]) == .export(format: "txt", sessionID: nil))
    }

    @Test("the running-app verbs keep their names")
    func appVerbs() {
        for verb in ["--toggle", "--start", "--stop", "--copy"] {
            #expect(CommandLinePlan.parse(["sAiity", verb]) == .openApp(verb: String(verb.dropFirst(2))))
            #expect(CommandLinePlan.appVerbs.contains(verb), "\(verb) must be an app-routed verb")
        }
    }

    @Test("a missing or unusable selftest timeout keeps the default")
    func selftestTimeout() {
        let fallback = CommandLinePlan.defaultSmokeTimeout
        #expect(CommandLinePlan.parse(["sAiity", "--selftest"]) == .launchSmokeTest(timeout: fallback))
        #expect(CommandLinePlan.parse(["sAiity", "--selftest", "soon"]) == .launchSmokeTest(timeout: fallback))
        #expect(CommandLinePlan.parse(["sAiity", "--selftest", "0"]) == .launchSmokeTest(timeout: fallback))
        #expect(CommandLinePlan.parse(["sAiity", "--selftest", "-5"]) == .launchSmokeTest(timeout: fallback))
    }

    @Test("a selftest timeout is honoured, and bounded")
    func selftestTimeoutIsBounded() {
        #expect(CommandLinePlan.parse(["sAiity", "--selftest", "12"]) == .launchSmokeTest(timeout: 12))
        // A typo must not park a CI runner for hours.
        #expect(CommandLinePlan.parse(["sAiity", "--selftest", "999999"]) ==
                .launchSmokeTest(timeout: CommandLinePlan.maximumSmokeTimeout))
    }

    @Test("an unrecognised flag is a usage error, not a launch")
    func unknownVerbIsUsageError() {
        #expect(CommandLinePlan.parse(["sAiity", "--wat"]) == .unknown(argument: "--wat"))
        #expect(CommandLinePlan.parse(["sAiity", "--"]) == .unknown(argument: "--"))
    }

    @Test("every verb is reachable, and the usage line lists all of them")
    func usageCoversEveryVerb() {
        for verb in CommandLinePlan.verbs {
            #expect(CommandLinePlan.parse(["sAiity", verb]) != nil,
                    "\(verb) is advertised but not handled")
            #expect(CommandLinePlan.usage.contains(verb),
                    "\(verb) is handled but not in the usage line")
        }
        // And the reverse: no verb in the usage line that the table does not
        // accept, so a typo in the help text cannot send users nowhere.
        for token in CommandLinePlan.usage.split(whereSeparator: { $0 == " " || $0 == "|" || $0 == "[" || $0 == "]" })
        where token.hasPrefix("--") {
            #expect(CommandLinePlan.verbs.contains(String(token)),
                    "\(token) is in the usage line but not in the verb table")
        }
    }

    @Test("app verbs become saiity:// URLs that carry only the verb")
    func appURLs() {
        for verb in CommandLinePlan.appVerbs {
            let name = String(verb.dropFirst(2))
            #expect(CommandLinePlan.appURL(forVerb: name)?.absoluteString == "saiity://\(name)")
        }
        // The old code built the URL by string interpolation and never checked
        // it: a malformed verb produced a URL that opens nothing, and the
        // process still exited 0 — a silent no-op reported as success.
        #expect(CommandLinePlan.appURL(forVerb: "") == nil)
        #expect(CommandLinePlan.appURL(forVerb: "two words") == nil)
        #expect(CommandLinePlan.appURL(forVerb: "a/b") == nil)
        // A verb that is already a URL is not a verb.
        #expect(CommandLinePlan.appURL(forVerb: "saiity://toggle") == nil)
    }
}
