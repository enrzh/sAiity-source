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

    public static var recentFailures: [DiagnosticsRuntimeFailure] {
        Array(read(DiagnosticsRuntimeFailure.self, key: failureKey).reversed())
    }

    public static var recentTimings: [DiagnosticsRuntimeTiming] {
        Array(read(DiagnosticsRuntimeTiming.self, key: timingKey).reversed())
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
        var values = read(DiagnosticsRuntimeFailure.self, key: failureKey)
        values.append(.init(date: Date(), operation: operation, reason: reason))
        write(Array(values.suffix(historyLimit)), key: failureKey)
        NSLog("sAiity runtime failure: %@ — %@", operation, reason)
        NotificationCenter.default.post(name: changed, object: nil)
    }

    public static func recordTiming(operation: String, seconds: Double, cold: Bool? = nil) {
        let operation = operation.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !operation.isEmpty, seconds.isFinite, seconds >= 0 else { return }
        var values = read(DiagnosticsRuntimeTiming.self, key: timingKey)
        values.append(.init(date: Date(), operation: operation, seconds: seconds, cold: cold))
        write(Array(values.suffix(historyLimit)), key: timingKey)
        NotificationCenter.default.post(name: changed, object: nil)
    }

#if SAIITY_TEST_HOOKS
    public static func clearRuntimeHistoryForTests() {
        UserDefaults.standard.removeObject(forKey: failureKey)
        UserDefaults.standard.removeObject(forKey: timingKey)
        NotificationCenter.default.post(name: changed, object: nil)
    }
#endif

    public static func report() -> String {
        var out: [String] = []
        let info = Bundle.main
        let v = info.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let b = info.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        out.append("sAiity diagnostics — \(ISO8601DateFormatter().string(from: Date()))")
        out.append("app: \(v) (\(b))")
        out.append("macOS: \(ProcessInfo.processInfo.operatingSystemVersionString)")
        out.append("")
        out.append("recognition: \(ASREngine.selected?.rawValue ?? "none selected")"
                   + " · nemotron tier \(NemotronEngine.selectedChunkMs) ms")
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
