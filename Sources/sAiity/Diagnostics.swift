import AppKit
import CoreGraphics
import Foundation
import OSLog

public struct DiagnosticsRuntimeFailure: Codable, Equatable, Sendable {
    public let date: Date
    public let operation: String
    public let reason: String
}

public struct DiagnosticsRuntimeTiming: Codable, Equatable, Sendable {
    public let date: Date
    public let operation: String
    public let seconds: Double
    public let cold: Bool?
    public let runID: String?
    public let outcome: String?
    public let fallbackReason: String?
    public let modelLoadCount: Int?
    public let modelCallCount: Int?

    public init(date: Date, operation: String, seconds: Double, cold: Bool? = nil,
                runID: String? = nil, outcome: String? = nil, fallbackReason: String? = nil,
                modelLoadCount: Int? = nil, modelCallCount: Int? = nil) {
        self.date = date
        self.operation = operation
        self.seconds = seconds
        self.cold = cold
        self.runID = runID
        self.outcome = outcome
        self.fallbackReason = fallbackReason
        self.modelLoadCount = modelLoadCount
        self.modelCallCount = modelCallCount
    }
}

public struct DiagnosticsTimingSummary: Equatable, Sendable {
    public let operation: String
    public let count: Int
    public let p50: Double
    public let p95: Double
    public var cold: Bool? = nil
    public var outcome: String? = nil
}

enum DiagnosticsTimingSummarizer {
    static func slowestStage(_ timings: [DiagnosticsRuntimeTiming]) -> DiagnosticsRuntimeTiming? {
        let stages = ["dictation.preparation", "dictation.preparation-wait", "dictation.capture-start", "dictation.transcription",
                      "dictation.cleanup", "dictation.translation", "dictation.delivery"]
        return timings.filter { stages.contains($0.operation) && $0.seconds.isFinite && $0.seconds >= 0 }
            .max { $0.seconds < $1.seconds }
    }

    static func stageTitle(_ operation: String) -> String {
        switch operation {
        case "dictation.preparation": String(localized: "Preparing recognition")
        case "dictation.preparation-wait": String(localized: "Waiting for recognition")
        case "dictation.capture-start": String(localized: "Starting microphone")
        case "dictation.transcription", "model.recognition": String(localized: "Recognizing speech")
        case "dictation.cleanup": String(localized: "Cleaning text")
        case "dictation.translation": String(localized: "Translating text")
        case "dictation.delivery": String(localized: "Delivering result")
        case "dictation.total": String(localized: "Whole dictation")
        case "dictation.release-to-result": String(localized: "From release to result")
        case "dictation.release-to-insert": String(localized: "From release to delivery")
        case "dictation.cleanup.requests": String(localized: "Cleanup model requests")
        case "model.load": String(localized: "Loading a local model")
        case "model.generation": String(localized: "Generating text")
        case "model.prompt": String(localized: "Reading model input")
        case "model.decode": String(localized: "Decoding text")
        default: operation
        }
    }

    static func slowestExplanation(_ operation: String) -> String {
        switch operation {
        case "dictation.preparation", "dictation.preparation-wait": String(localized: "Most time was spent preparing speech recognition.")
        case "dictation.capture-start": String(localized: "Most time was spent starting the microphone.")
        case "dictation.transcription": String(localized: "Most time was spent recognizing speech.")
        case "dictation.cleanup": String(localized: "Most time was spent cleaning text.")
        case "dictation.translation": String(localized: "Most time was spent translating text.")
        case "dictation.delivery": String(localized: "Most time was spent delivering the result.")
        default: ""
        }
    }

    static func latestRun(_ timings: [DiagnosticsRuntimeTiming]) -> [DiagnosticsRuntimeTiming] {
        let recent = timings.prefix(20)
        guard let runID = recent.first(where: { $0.runID != nil })?.runID else { return [] }
        return recent.filter { $0.runID == runID }
    }

    static func summarize(_ timings: [DiagnosticsRuntimeTiming]) -> [DiagnosticsTimingSummary] {
        let allowed = ["inserted", "paste-dispatched", "copied", "copy-failed", "cancelled", "failed"]
        func outcome(_ value: String?) -> String? { value.flatMap { allowed.contains($0) ? $0 : nil } }
        return Dictionary(grouping: timings.filter { $0.seconds.isFinite && $0.seconds >= 0 }, by: {
            "\($0.operation)|\($0.cold.map { $0 ? "cold" : "warm" } ?? "unspecified")|\(outcome($0.outcome) ?? "unspecified")"
        })
            .map { _, values in
                let sorted = values.map(\.seconds).sorted()
                let percentile: (Double) -> Double = { rank in
                    let index = min(sorted.count - 1,
                                    max(0, Int(ceil(rank * Double(sorted.count))) - 1))
                    return sorted[index]
                }
                return DiagnosticsTimingSummary(operation: values[0].operation,
                                                count: sorted.count,
                                                p50: percentile(0.50),
                                                p95: percentile(0.95), cold: values[0].cold, outcome: outcome(values[0].outcome))
            }
            .sorted { $0.operation < $1.operation }
    }
}

/// The settings rows for caption timing. The diagnostics file keeps p50 and
/// p95; this is the wording a person reads, with no ratios or percentiles.
enum CaptionPerformanceCopy {
    /// A real-time factor at or below 1 means recognition finished at least as
    /// fast as the audio arrived.
    static func recognitionSpeed(p50RealTimeFactor rtf: Double) -> String {
        guard rtf.isFinite, rtf <= 1 else {
            return String(localized: "Falling behind")
        }
        return String(localized: "Keeping up")
    }

    static func duration(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0.05 else {
            return String(localized: "Under 0.1 seconds")
        }
        let shown = String(format: "%.1f", seconds)
        return String(localized: "\(shown) seconds")
    }

    static func audioNotCaptioned(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0.05 else {
            return String(localized: "None")
        }
        return duration(seconds)
    }
}

/// The caption-page choice for how soon a line can appear, and the pause
/// readout beside it. The stored tier and the pause hold stay in milliseconds.
/// This only changes the words a person reads.
enum CaptionLatencyCopy {
    static func title(chunkMs: Int) -> String {
        switch chunkMs {
        case 1120: return String(localized: "About 1 second")
        default: return String(localized: "About 2 seconds")
        }
    }

    static var missingDownload: String {
        String(localized: "This choice is a separate download. Get it under Models.")
    }

    /// 750 ms is 0.75 seconds, not 0.8. Keep a second decimal only when the
    /// tenth would hide it.
    static func pauseLength(milliseconds: Double) -> String {
        let seconds = milliseconds / 1000
        let hundredths = (seconds * 100).rounded() / 100
        let tenths = (hundredths * 10).rounded() / 10
        let shown = abs(hundredths - tenths) < 0.001
            ? String(format: "%.1f", hundredths)
            : String(format: "%.2f", hundredths)
        return String(localized: "\(shown) seconds")
    }

    /// Clear is a command for a caption that is on screen. An empty or hidden
    /// bubble has nothing to clear.
    static func clearEnabled(showingCaption: Bool) -> Bool {
        showingCaption
    }
}

/// One shareable text file answering "what state was the app in".
///
/// Every log site in this app is NSLog, so the causal detail behind most
/// failures lives only in the unified log — and a menu-bar app's audience
/// cannot be walked through Console.app filters. Several visible errors also
/// deliberately keep their reason in the log ("Could not switch language",
/// translator prepare failures), which is right for the status line and
/// useless for a bug report. This gathers the state and this run's log lines
/// into a single file the user can attach.
///
/// The report itself is deliberately English, whatever the UI language: it is
/// written to be read by whoever fixes the bug, and grep-stable field names
/// beat translated ones there. Only the button that triggers it is localized.
@MainActor
public enum Diagnostics {
    public static let changed = Notification.Name("saiityDiagnosticsChanged")

    private static let failureKey = "saiityRecentRuntimeFailures"
    private static let timingKey = "saiityRecentRuntimeTimings"
    private static let historyLimit = 20

    /// These events arrive per caption final, per translation, and per ASR
    /// metric sample — several per second during a busy session. Persisting and
    /// broadcasting on every one of them was the cost of a purely
    /// display-oriented feature: a synchronous UserDefaults round trip on the
    /// main actor, plus a notification that rebuilt the settings performance
    /// section. History is now held in memory, persisted on a coalescing timer,
    /// and the UI is woken at most once per second.
    private static let flushInterval: TimeInterval = 1.0

    private static var failuresLoaded = false
    private static var timingsLoaded = false
    private static var failureStore: [DiagnosticsRuntimeFailure] = []
    private static var timingStore: [DiagnosticsRuntimeTiming] = []
    private static var flushTask: Task<Void, Never>?
    private static var notifyTask: Task<Void, Never>?

    private static var runtimeDefaults: UserDefaults {
#if SAIITY_TEST_HOOKS
        if let runtimeDefaultsForTests { return runtimeDefaultsForTests }
#endif
        return .standard
    }

    private static func read<T: Decodable>(_ type: T.Type, key: String) -> [T] {
        guard let data = runtimeDefaults.data(forKey: key),
              let values = try? JSONDecoder().decode([T].self, from: data) else {
            return []
        }
        return values
    }

    private static func write<T: Encodable>(_ values: [T], key: String) {
        guard let data = try? JSONEncoder().encode(values) else { return }
        runtimeDefaults.set(data, forKey: key)
    }

    /// Seed the in-memory history from disk on first touch of this run, so a
    /// restart still shows the previous session's tail. The append paths must go
    /// through this before writing, or a first event of the run would land in an
    /// empty array and silently discard everything that was persisted.
    private static func loadFailures() {
        guard !failuresLoaded else { return }
        failureStore = read(DiagnosticsRuntimeFailure.self, key: failureKey)
        failuresLoaded = true
    }

    private static func loadTimings() {
        guard !timingsLoaded else { return }
        timingStore = read(DiagnosticsRuntimeTiming.self, key: timingKey)
        timingsLoaded = true
    }

    private static var storedFailures: [DiagnosticsRuntimeFailure] {
        loadFailures()
        return failureStore
    }

    private static var storedTimings: [DiagnosticsRuntimeTiming] {
        loadTimings()
        return timingStore
    }

    /// Persist and notify at most once per `flushInterval`, so a burst of
    /// events costs one write and one settings rebuild rather than one each.
    /// The last event in a burst still reaches disk and the UI, so nothing is
    /// lost — it is only delayed by at most one interval.
    private static func scheduleFlushAndNotify() {
        if flushTask == nil {
            flushTask = Task { @MainActor in
                try? await Task.sleep(for: .seconds(Diagnostics.flushInterval))
                guard !Task.isCancelled else { return }
                Diagnostics.flush()
            }
        }
        if notifyTask == nil {
            notifyTask = Task { @MainActor in
                try? await Task.sleep(for: .seconds(Diagnostics.flushInterval))
                guard !Task.isCancelled else { return }
                Diagnostics.announce()
            }
        }
    }

    private static func flush() {
        flushTask?.cancel()
        flushTask = nil
        guard failuresLoaded || timingsLoaded else { return }
        if failuresLoaded {
            // Trim on the way out as well as on the way in: this is the only
            // place the persisted array shrinks, and a file that only ever
            // grew would carry whatever was there when the limit was raised.
            if failureStore.count > historyLimit {
                failureStore.removeFirst(failureStore.count - historyLimit)
            }
            write(failureStore, key: failureKey)
        }
        if timingsLoaded {
            if timingStore.count > historyLimit {
                timingStore.removeFirst(timingStore.count - historyLimit)
            }
            write(timingStore, key: timingKey)
        }
    }

    private static func announce() {
        notifyTask?.cancel()
        notifyTask = nil
        NotificationCenter.default.post(name: changed, object: nil)
    }

    /// Newest-first, and already bounded to `historyLimit`. The cap is applied
    /// on read as well as on write: the in-memory buffer is deliberately
    /// allowed to run past the limit between flushes, so a reader that skipped
    /// the suffix would see a history the settings page and the report do not
    /// agree about.
    public static var recentFailures: [DiagnosticsRuntimeFailure] {
        Array(storedFailures.suffix(historyLimit).reversed())
    }

    public static var recentTimings: [DiagnosticsRuntimeTiming] {
        Array(storedTimings.suffix(historyLimit).reversed())
    }

    public static var recentTimingSummaries: [DiagnosticsTimingSummary] {
        DiagnosticsTimingSummarizer.summarize(recentTimings)
    }

    public static var recentLatestRun: [DiagnosticsRuntimeTiming] {
        DiagnosticsTimingSummarizer.latestRun(recentTimings)
    }

    public static var latestFailure: DiagnosticsRuntimeFailure? { recentFailures.first }

    public static func recordFailure(operation: String, reason: String) {
        let operation = DiagnosticsRedactor.redact(operation)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let reason = DiagnosticsRedactor.redact(reason)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !operation.isEmpty, !reason.isEmpty else { return }
        loadFailures()
        failureStore.append(.init(date: Date(), operation: operation, reason: reason))
        if failureStore.count > historyLimit * 2 {
            failureStore.removeFirst(failureStore.count - historyLimit)
        }
        NSLog("sAiity runtime failure: %@ — %@", operation, reason)
        scheduleFlushAndNotify()
    }

    public static func recordTiming(operation: String, seconds: Double, cold: Bool? = nil,
                                    runID: String? = nil, outcome: String? = nil,
                                    fallbackReason: String? = nil, modelLoadCount: Int? = nil,
                                    modelCallCount: Int? = nil) {
        let operation = operation.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !operation.isEmpty, seconds.isFinite, seconds >= 0 else { return }
        let timing = DiagnosticsRuntimeTiming(date: Date(), operation: operation, seconds: seconds, cold: cold,
                                 runID: runID ?? LocalGeneration.dictationRunID, outcome: outcome, fallbackReason: fallbackReason,
                                 modelLoadCount: modelLoadCount, modelCallCount: modelCallCount)
        if let observer = LocalGeneration.timingObserver {
            observer(timing)
            return
        }
        loadTimings()
        timingStore.append(timing)
        if timingStore.count > historyLimit * 2 {
            timingStore.removeFirst(timingStore.count - historyLimit)
        }
        scheduleFlushAndNotify()
    }

    /// Persist immediately, without broadcasting. Called before producing a
    /// report so a user attaching a bug report gets the event that just
    /// happened, not the state as of the last one-second tick. Deliberately
    /// does not post `changed`: a report is a read, and waking the views that
    /// are about to be read from would be churn.
    public static func flushNow() {
        flush()
    }

#if SAIITY_TEST_HOOKS
    private static var runtimeDefaultsForTests: UserDefaults?

    /// Synchronous scope: original tasks cannot resume while a test domain is installed.
    public static func withRuntimeHistoryForTests(defaults: UserDefaults,
                                                  _ body: () throws -> Void) rethrows {
        let previous = (runtimeDefaultsForTests, failuresLoaded, timingsLoaded,
                        failureStore, timingStore, flushTask, notifyTask)
        runtimeDefaultsForTests = defaults
        failuresLoaded = true
        timingsLoaded = true
        failureStore = []
        timingStore = []
        flushTask = nil
        notifyTask = nil
        defer {
            flushTask?.cancel()
            notifyTask?.cancel()
            (runtimeDefaultsForTests, failuresLoaded, timingsLoaded,
             failureStore, timingStore, flushTask, notifyTask) = previous
        }
        try body()
    }

    public static func clearRuntimeHistoryForTests() {
        // Clearing a test history must never fall through to the live defaults domain.
        guard let defaults = runtimeDefaultsForTests else { return }
        flushTask?.cancel()
        notifyTask?.cancel()
        flushTask = nil
        notifyTask = nil
        failureStore = []
        timingStore = []
        failuresLoaded = true
        timingsLoaded = true
        defaults.removeObject(forKey: failureKey)
        defaults.removeObject(forKey: timingKey)
        NotificationCenter.default.post(name: changed, object: nil)
    }

    /// Drop the in-memory cache without touching what is on disk, so a test can
    /// exercise the path a fresh launch takes. Without this the history can only
    /// ever be observed through the buffer the current process built.
    public static func dropRuntimeHistoryCacheForTests() {
        flushTask?.cancel()
        notifyTask?.cancel()
        flushTask = nil
        notifyTask = nil
        failureStore = []
        timingStore = []
        failuresLoaded = false
        timingsLoaded = false
    }
#endif

    /// Formats synthetic or already-captured history without reading app state.
    static func runtimeHistoryReport(failures: [DiagnosticsRuntimeFailure],
                                     timings: [DiagnosticsRuntimeTiming]) -> [String] {
        let timings = Array(timings.prefix(historyLimit))
        let date = ISO8601DateFormatter()
        func timingLine(_ timing: DiagnosticsRuntimeTiming) -> String {
            var line = "  \(date.string(from: timing.date)) \(timing.operation): \(String(format: "%.3f", timing.seconds))s"
            if let cold = timing.cold { line += cold ? " · cold" : " · warm" }
            // Persisted metadata must not become an arbitrary speech/content export channel.
            if let rawID = timing.runID, let id = UUID(uuidString: rawID) {
                line += " · runID=\(id.uuidString)"
            }
            if let outcome = timing.outcome,
               ["inserted", "paste-dispatched", "copied", "copy-failed", "cancelled", "failed"].contains(outcome) {
                line += " · outcome=\(outcome)"
            }
            if let reason = timing.fallbackReason,
               ["cleanup-unavailable", "translation-unavailable", "validation-rejected", "deadline-exhausted"].contains(reason) {
                line += " · fallbackReason=\(reason)"
            }
            if let loads = timing.modelLoadCount, loads >= 0 { line += " · modelLoadCount=\(loads)" }
            if let calls = timing.modelCallCount, calls >= 0 { line += " · modelCallCount=\(calls)" }
            return line
        }

        var out = ["recent failures:"]
        if failures.isEmpty {
            out.append("  none")
        } else {
            for failure in failures.prefix(historyLimit) {
                out.append("  \(date.string(from: failure.date)) \(failure.operation): \(DiagnosticsRedactor.redact(failure.reason))")
            }
        }
        out.append("recent timings:")
        out.append(contentsOf: timings.isEmpty ? ["  none"] : timings.map(timingLine))
        out.append("timing percentiles (recent):")
        let summaries = DiagnosticsTimingSummarizer.summarize(timings)
        if summaries.isEmpty {
            out.append("  none")
        } else {
            for summary in summaries {
                let condition = summary.cold.map { $0 ? "cold" : "warm" } ?? "unspecified"
                out.append("  \(summary.operation): n=\(summary.count) p50=\(String(format: "%.3f", summary.p50))s p95=\(String(format: "%.3f", summary.p95))s [\(condition), \(summary.outcome ?? "unspecified")]")
            }
        }
        out.append("latest dictation run:")
        let run = DiagnosticsTimingSummarizer.latestRun(timings)
        out.append(contentsOf: run.isEmpty ? ["  none"] : run.map(timingLine))
        return out
    }

    public static func report() -> String {
        flushNow()
        var out: [String] = []
        let info = Bundle.main
        let v = info.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let b = info.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        out.append("Syllivra diagnostics — \(ISO8601DateFormatter().string(from: Date()))")
        out.append("app: \(v) (\(b))")
        out.append("macOS: \(ProcessInfo.processInfo.operatingSystemVersionString)")
        out.append("")
        // Both tiers, because they are two separate preferences now. A report
        // naming only one cannot explain why press-to-talk and the caption
        // bubble behave differently on the same Mac.
        out.append("recognition: \(ASREngine.selected?.rawValue ?? "none selected")"
                   + " · nemotron captions tier \(NemotronEngine.selectedChunkMs) ms"
                   + " · dictation tier \(NemotronEngine.dictationSelectedChunkMs) ms")
        out.append("translation: \(TranslationEngine.selected?.rawValue ?? "none selected")"
                   + " · cleanup model \(LocalModel.cleanupSelected?.file ?? "—")")
        out.append("mlx metallib: \(MADLADTranslator.hasBundledMetalLibrary ? "present" : "missing")")
        out.append("translate to: \(UserDefaults.standard.string(forKey: "translateTo") ?? "off")"
                   + " · timing \(TranslationTiming.current.rawValue)")
        out.append("speech gap: \(SpeechGap.enabled ? "on" : "off") · hold \(SpeechGap.holdMs) ms")
        out.append("screen recording: \(CGPreflightScreenCaptureAccess() ? "granted" : "not granted")")
        out.append("memory: \(MemoryPolicy.describeFootprint())")
        out.append("")
        out.append("models:")
        for st in ModelRegistry.snapshot() {
            var line = "  \(st.asset.id): "
            line += st.isInstalled ? "installed" : st.isPartial ? "partial" : "not downloaded"
            if st.bytesOnDisk > 0 { line += " · \(ModelRegistry.format(st.bytesOnDisk))" }
            if let reason = LoadHealth.reason(for: st.asset.id) {
                line += " · FAILED TO LOAD: \(DiagnosticsRedactor.redact(reason))"
            }
            out.append(line)
        }
        out.append("")
        out.append(contentsOf: runtimeHistoryReport(failures: recentFailures, timings: recentTimings))
        out.append("")
        out.append("log (this run):")
        out.append(contentsOf: logSinceLaunch())
        return out.joined(separator: "\n") + "\n"
    }

    public static func save() {
        let panel = NSSavePanel()
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd-HHmm"
        panel.nameFieldStringValue = "Syllivra-diagnostics-\(df.string(from: Date())).txt"
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try report().write(to: url, atomically: true, encoding: .utf8)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600],
                                                   ofItemAtPath: url.path)
        } catch {
            NSLog("sAiity diagnostics save failed: \(error.localizedDescription)")
        }
    }

    /// NSLog output lands in the unified log; the process-scoped store starts
    /// at launch, which is exactly the window a bug report needs. Filtered to
    /// this app's own lines — every log site here prefixes "sAiity".
    private static func logSinceLaunch() -> [String] {
        do {
            let store = try OSLogStore(scope: .currentProcessIdentifier)
            let df = DateFormatter()
            df.dateFormat = "HH:mm:ss.SSS"
            return try store.getEntries()
                .compactMap { $0 as? OSLogEntryLog }
                .filter { $0.composedMessage.contains("sAiity") }
                .map { DiagnosticsRedactor.redact("  \(df.string(from: $0.date)) \($0.composedMessage)") }
        } catch {
            return ["  (unified log unavailable: \(error.localizedDescription))"]
        }
    }
}
