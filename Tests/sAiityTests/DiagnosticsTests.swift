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

    @Test("a persisted history larger than the limit is still served bounded")
    func persistedHistoryIsBoundedOnRead() throws {
        Diagnostics.clearRuntimeHistoryForTests()
        defer { Diagnostics.clearRuntimeHistoryForTests() }

        // Simulates a defaults file written by a build with a larger limit, or
        // corrupted by a partial write. The reader must not trust it.
        let oversized = (0..<64).map {
            DiagnosticsRuntimeTiming(date: Date(), operation: "stale-\($0)",
                                     seconds: Double($0), cold: nil)
        }
        UserDefaults.standard.set(try JSONEncoder().encode(oversized),
                                  forKey: "saiityRecentRuntimeTimings")
        // A fresh process would load it lazily; the same must be true here.
        Diagnostics.dropRuntimeHistoryCacheForTests()

        #expect(Diagnostics.recentTimings.count == 20)
        #expect(Diagnostics.recentTimings.first?.operation == "stale-63")
    }

    @Test("a burst of events costs one write, and the last event still lands on disk")
    func burstIsCoalescedButNotLost() {
        Diagnostics.clearRuntimeHistoryForTests()
        defer { Diagnostics.clearRuntimeHistoryForTests() }

        // The timing path fires several times per caption final. It must not do
        // a UserDefaults round trip per event, and it must not lose the newest
        // event when it is flushed.
        for index in 0..<25 {
            Diagnostics.recordTiming(operation: "captions.visible-lag", seconds: Double(index) / 100)
        }
        #expect(Diagnostics.recentTimings.count == 20)

        Diagnostics.flushNow()

        let persisted = UserDefaults.standard.data(forKey: "saiityRecentRuntimeTimings")
        #expect(persisted != nil)
        let decoded = try? JSONDecoder().decode(
            [DiagnosticsRuntimeTiming].self, from: persisted ?? Data())
        #expect(decoded?.count == 20)
        #expect(decoded?.last?.seconds == 0.24)
    }

    @Test("history is readable before any flush, not only afterwards")
    func readsAreServedFromMemory() {
        Diagnostics.clearRuntimeHistoryForTests()
        defer { Diagnostics.clearRuntimeHistoryForTests() }

        Diagnostics.recordTiming(operation: "captions.asr.rtf", seconds: 0.4)
        Diagnostics.recordFailure(operation: "captions.backend.start", reason: "load failed")

        // No flush, no notification: the settings pages read this directly.
        #expect(Diagnostics.recentTimings.first?.operation == "captions.asr.rtf")
        #expect(Diagnostics.latestFailure?.reason == "load failed")
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
