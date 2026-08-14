import AppKit
import CoreGraphics
import Foundation
import OSLog

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
enum Diagnostics {

    static func report() -> String {
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
                   + " · llm model \(LocalModel.selected?.file ?? "—")")
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
                line += " · FAILED TO LOAD: \(reason)"
            }
            out.append(line)
        }
        out.append("")
        out.append("log (this run):")
        out.append(contentsOf: logSinceLaunch())
        return out.joined(separator: "\n") + "\n"
    }

    static func save() {
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
                .map { "  \(df.string(from: $0.date)) \($0.composedMessage)" }
        } catch {
            return ["  (unified log unavailable: \(error.localizedDescription))"]
        }
    }
}
