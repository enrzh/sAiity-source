import Foundation
import Testing

@testable import sAiity

@MainActor
@Suite struct DiagnosticsTests {
    @Test("runtime diagnostics keep a bounded, newest-first history")
    func boundedHistory() {
        Diagnostics.clearRuntimeHistoryForTests()
        defer { Diagnostics.clearRuntimeHistoryForTests() }

        for index in 0..<25 {
            Diagnostics.recordFailure(operation: "operation-\(index)", reason: "reason-\(index)")
            Diagnostics.recordTiming(operation: "timing-\(index)",
                                     seconds: Double(index),
                                     cold: index == 0)
        }

        #expect(Diagnostics.recentFailures.count == 20)
        #expect(Diagnostics.recentTimings.count == 20)
        #expect(Diagnostics.latestFailure?.operation == "operation-24")
        #expect(Diagnostics.recentTimings.first?.operation == "timing-24")
        #expect(Diagnostics.recentTimings.last?.operation == "timing-5")
    }

    @Test("diagnostics report includes runtime failures and timings")
    func reportIncludesRuntimeHistory() {
        Diagnostics.clearRuntimeHistoryForTests()
        defer { Diagnostics.clearRuntimeHistoryForTests() }

        Diagnostics.recordFailure(operation: "dictation.translation", reason: "original preserved")
        Diagnostics.recordTiming(operation: "translator.prepare", seconds: 1.25, cold: true)

        let report = Diagnostics.report()
        #expect(report.contains("recent failures:"))
        #expect(report.contains("dictation.translation: original preserved"))
        #expect(report.contains("recent timings:"))
        #expect(report.contains("translator.prepare: 1.250s · cold"))
        #expect(report.contains("timing percentiles (recent):"))
    }

    @Test("timing summaries expose p50 and p95 for recent stages")
    func timingPercentiles() {
        Diagnostics.clearRuntimeHistoryForTests()
        defer { Diagnostics.clearRuntimeHistoryForTests() }

        for value in [0.1, 0.2, 0.4, 0.8] {
            Diagnostics.recordTiming(operation: "dictation.transcription", seconds: value)
        }

        let summary = Diagnostics.recentTimingSummaries.first { $0.operation == "dictation.transcription" }
        #expect(summary?.count == 4)
        #expect(summary?.p50 == 0.2)
        #expect(summary?.p95 == 0.8)
    }

    @Test("diagnostics redact transcript payloads and home paths")
    func redactsSensitiveLogPayloads() {
        let line = "sAiity chunk final=true: secret transcript"
        #expect(DiagnosticsRedactor.redact(line) == "sAiity chunk final=<redacted>")
        #expect(DiagnosticsRedactor.redact(
            "/Users/example/Library/Application Support/sAiity/error.log",
            homeDirectory: "/Users/example") == "~/Library/Application Support/sAiity/error.log")
        #expect(DiagnosticsRedactor.redact("sAiity live translated: private output")
            .contains("<redacted>"))
    }

    @Test("caption performance rows use plain wording")
    func captionPerformanceWording() {
        #expect(CaptionPerformanceCopy.recognitionSpeed(p50RealTimeFactor: 1)
                == String(localized: "Keeping up"))
        #expect(CaptionPerformanceCopy.recognitionSpeed(p50RealTimeFactor: 1.01)
                == String(localized: "Falling behind"))
        #expect(CaptionPerformanceCopy.duration(2.44).contains("2.4"))
        #expect(!CaptionPerformanceCopy.duration(2.44).localizedCaseInsensitiveContains("p50"))
        #expect(!CaptionPerformanceCopy.recognitionSpeed(p50RealTimeFactor: 0.4)
            .localizedCaseInsensitiveContains("RTF"))
        #expect(CaptionPerformanceCopy.audioNotCaptioned(0.02) == String(localized: "None"))
        #expect(CaptionPerformanceCopy.audioNotCaptioned(1.26).contains("1.3"))
    }

    @Test("caption latency choice uses plain time, not model jargon")
    func captionLatencyWording() {
        #expect(CaptionLatencyCopy.title(chunkMs: 2240) == String(localized: "About 2 seconds"))
        #expect(CaptionLatencyCopy.title(chunkMs: 1120) == String(localized: "About 1 second"))
        #expect(CaptionLatencyCopy.title(chunkMs: 0) == String(localized: "About 2 seconds"))
        let note = CaptionLatencyCopy.missingDownload
        #expect(!note.localizedCaseInsensitiveContains("tier"))
        #expect(!note.localizedCaseInsensitiveContains("chunk"))
        #expect(!note.localizedCaseInsensitiveContains("640"))
        #expect(!note.localizedCaseInsensitiveContains("RTF"))
        let pause = CaptionLatencyCopy.pauseLength(milliseconds: 750)
        #expect(pause.contains("0.75"))
        #expect(!pause.localizedCaseInsensitiveContains("ms"))
        #expect(CaptionLatencyCopy.pauseLength(milliseconds: 300).contains("0.3"))
        #expect(CaptionLatencyCopy.pauseLength(milliseconds: 2000).contains("2.0"))
        #expect(CaptionLatencyCopy.clearEnabled(showingCaption: false) == false)
        #expect(CaptionLatencyCopy.clearEnabled(showingCaption: true))
    }
}
