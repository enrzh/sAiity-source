import Foundation

/// What the process was asked to do, decided from `argv` alone.
///
/// The dispatch table, the usage text and the CI smoke step all read from
/// `verbs`, so a verb cannot be handled without being documented, and a verb
/// nobody handles cannot be advertised.
///
/// Parsing lives here rather than in `main.swift` because it is the one part of
/// the launch path with no side effects: no AppKit, no disk, no network. That
/// is what keeps `--version` a two-line answer — it used to read the whole
/// transcript index first, because the session list was fetched before the
/// argument switch, so a bug report could not name its build without also
/// waiting on the store — and it is what makes the table testable.
enum CommandLinePlan: Equatable {
    /// Print this build's version and exit.
    case version
    /// Print every stored transcript session and exit.
    case list
    /// Print one session in `format`; `format` falls back to plain text.
    case export(format: String, sessionID: String?)
    /// Hand `verb` to the already-running app through its `saiity://` scheme.
    case openApp(verb: String)
    /// Launch the real app, check the launch, exit. See `LaunchSmokeTest`.
    case launchSmokeTest(timeout: TimeInterval)
    /// An argument this build does not understand.
    case unknown(argument: String)

    /// Every verb, in the order the usage line lists them. This is the list
    /// `parse` and `usage` are checked against, so adding a verb here without
    /// handling it fails a test rather than shipping a silent no-op.
    static let verbs = ["--version", "--list", "--export", "--toggle",
                        "--start", "--stop", "--copy", "--selftest"]

    /// Verbs that are requests to the RUNNING app rather than answers from
    /// this process. A fresh CLI invocation has no session of its own, so these
    /// go through the URL scheme and let LaunchServices find the app.
    static let appVerbs: Set<String> = ["--toggle", "--start", "--stop", "--copy"]

    /// `--selftest` gives up after this long. Long enough for a cold first
    /// launch (dyld resolving Sparkle, MLX and llama, reading the transcript
    /// index) and short enough that a wedged launch fails the job instead of
    /// running until the runner's own timeout.
    static let defaultSmokeTimeout: TimeInterval = 90

    /// An upper bound on a caller-supplied timeout, so `--selftest 999999`
    /// cannot park a CI runner.
    static let maximumSmokeTimeout: TimeInterval = 600

    static let usage = """
        usage: Syllivra [--version | --list | --export srt|vtt|md|txt [id] | \
        --toggle | --start | --stop | --copy | --selftest [seconds]]
        """

    /// The plan for `arguments` — `CommandLine.arguments`, `argv[0]` included —
    /// or nil to launch the app normally.
    ///
    /// Only the FIRST argument can be a verb. Anything else (a dropped file, a
    /// bare path) means a normal launch, which is exactly what Finder and
    /// `open` send, and it keeps a document path from being mistaken for a
    /// session id.
    static func parse(_ arguments: [String]) -> CommandLinePlan? {
        guard arguments.count > 1 else { return nil }
        let first = arguments[1]
        guard first.hasPrefix("--") else { return nil }
        switch first {
        case "--version":
            return .version
        case "--list":
            return .list
        case "--export":
            // A session id is an identifier and a format is a bare word, so
            // either can be left out; the other one can never look like a verb.
            let format = (arguments.count > 2 && !arguments[2].hasPrefix("--"))
                ? arguments[2] : "txt"
            let sessionID = (arguments.count > 3 && !arguments[3].hasPrefix("--"))
                ? arguments[3] : nil
            return .export(format: format, sessionID: sessionID)
        case "--toggle", "--start", "--stop", "--copy":
            return .openApp(verb: String(first.dropFirst(2)))
        case "--selftest":
            return .launchSmokeTest(timeout: smokeTimeout(arguments))
        default:
            return .unknown(argument: first)
        }
    }

    /// The URL that hands a verb to the running app.
    ///
    /// Nil for a verb that is not a plain identifier: `saiity://` with an empty
    /// host opens nothing at all, and the process would exit 0 having quietly
    /// done nothing, which is the worst possible answer to `--start`.
    static func appURL(forVerb verb: String) -> URL? {
        guard !verb.isEmpty,
              verb.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" })
        else { return nil }
        return URL(string: "saiity://\(verb)")
    }

    /// A missing, unparsable or non-positive `--selftest` argument keeps the
    /// default rather than failing: the timeout is a backstop against a hung
    /// launch, not a knob whose absence should be an error.
    private static func smokeTimeout(_ arguments: [String]) -> TimeInterval {
        guard arguments.count > 2, let seconds = Double(arguments[2]), seconds > 0 else {
            return defaultSmokeTimeout
        }
        return min(seconds, maximumSmokeTimeout)
    }
}
