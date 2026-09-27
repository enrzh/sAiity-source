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
}

public struct DiagnosticsTimingSummary: Equatable, Sendable {
    public let operation: String
    public let count: Int
    public let p50: Double
    public let p95: Double
}

enum DiagnosticsTimingSummarizer {
    static func summarize(_ timings: [DiagnosticsRuntimeTiming]) -> [DiagnosticsTimingSummary] {
        Dictionary(grouping: timings, by: \.operation)
            .map { operation, values in
                let sorted = values.map(\.seconds).sorted()
                let percentile: (Double) -> Double = { rank in
                    let index = min(sorted.count - 1,
                                    max(0, Int(ceil(rank * Double(sorted.count))) - 1))
                    return sorted[index]
                }
                return DiagnosticsTimingSummary(operation: operation,
                                                count: sorted.count,
                                                p50: percentile(0.50),
                                                p95: percentile(0.95))
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

    private static func read<T: Decodable>(_ type: T.Type, key: String) -> [T] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let values = try? JSONDecoder().decode([T].self, from: data) else {
            return []
        }
        return values
    }

    private static func write<T: Encodable>(_ values: [T], key: String) {
        guard let data = try? JSONEncoder().encode(values) else { return }
        UserDefaults.standard.set(data, forKey: key)
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

    public static func recordTiming(operation: String, seconds: Double, cold: Bool? = nil) {
        let operation = operation.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !operation.isEmpty, seconds.isFinite, seconds >= 0 else { return }
        loadTimings()
        timingStore.append(.init(date: Date(), operation: operation, seconds: seconds, cold: cold))
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
    public static func clearRuntimeHistoryForTests() {
        flushTask?.cancel()
        notifyTask?.cancel()
        flushTask = nil
        notifyTask = nil
        failureStore = []
        timingStore = []
        failuresLoaded = true
        timingsLoaded = true
        UserDefaults.standard.removeObject(forKey: failureKey)
        UserDefaults.standard.removeObject(forKey: timingKey)
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

    public static func report() -> String {
        flushNow()
        var out: [String] = []
        let info = Bundle.main
        let v = info.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let b = info.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        out.append("sAiity diagnostics — \(ISO8601DateFormatter().string(from: Date()))")
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
        out.append("recent failures:")
        let failureDate = ISO8601DateFormatter()
        if recentFailures.isEmpty {
            out.append("  none")
        } else {
            for failure in recentFailures {
                out.append("  \(failureDate.string(from: failure.date)) \(failure.operation): \(DiagnosticsRedactor.redact(failure.reason))")
            }
        }
        out.append("recent timings:")
        if recentTimings.isEmpty {
            out.append("  none")
        } else {
            for timing in recentTimings {
                let temperature = timing.cold == nil ? "" : (timing.cold == true ? " · cold" : " · warm")
                out.append("  \(failureDate.string(from: timing.date)) \(timing.operation): \(String(format: "%.3f", timing.seconds))s\(temperature)")
            }
        }
        out.append("timing percentiles (recent):")
        if recentTimingSummaries.isEmpty {
            out.append("  none")
        } else {
            for summary in recentTimingSummaries {
                out.append("  \(summary.operation): n=\(summary.count) p50=\(String(format: "%.3f", summary.p50))s p95=\(String(format: "%.3f", summary.p95))s")
            }
        }
        out.append("")
        out.append("log (this run):")
        out.append(contentsOf: logSinceLaunch())
        return out.joined(separator: "\n") + "\n"
    }

    public static func save() {
        let panel = NSSavePanel()
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd-HHmm"
        panel.nameFieldStringValue = "sAiity-diagnostics-\(df.string(from: Date())).txt"
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
