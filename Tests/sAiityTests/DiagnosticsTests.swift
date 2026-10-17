import Foundation
import Testing

@testable import sAiity

@MainActor
@Suite struct DiagnosticsTests {
    @Test("Scoped benchmark timing collection preserves run correlation without writing production history")
    func benchmarkTimingObserver() throws {
        try withIsolatedHistory { _ in
            var observed: [DiagnosticsRuntimeTiming] = []
            LocalGeneration.$dictationRunID.withValue("benchmark-run") {
                LocalGeneration.$timingObserver.withValue({ observed.append($0) }) {
                    Diagnostics.recordTiming(operation: "model.load", seconds: 0.2, modelLoadCount: 1)
                    Diagnostics.recordTiming(operation: "translator.gate-wait", seconds: 0.3)
                }
            }
            #expect(observed.count == 2)
            #expect(observed.allSatisfy { $0.runID == "benchmark-run" })
            #expect(observed.first?.modelLoadCount == 1)
            #expect(Diagnostics.recentTimings.isEmpty)
        }
    }
    @Test("model observations inherit only their async dictation context")
    func dupModelTimingUsesRunContext() throws {
        try withIsolatedHistory { _ in
            LocalGeneration.$dictationRunID.withValue("synthetic-run") {
                Diagnostics.recordTiming(operation: "model.load", seconds: 0.2, cold: true, modelLoadCount: 1)
                Diagnostics.recordTiming(operation: "model.generation", seconds: 0.3, modelCallCount: 1)
                Diagnostics.recordTiming(operation: "explicit", seconds: 0.1, runID: "explicit-run")
            }
            Diagnostics.recordTiming(operation: "background", seconds: 0.1)
            let events = Diagnostics.recentTimings
            #expect(events.first?.runID == nil)
            #expect(events.first(where: { $0.operation == "explicit" })?.runID == "explicit-run")
            #expect(events.first(where: { $0.operation == "model.load" })?.runID == "synthetic-run")
            #expect(events.first(where: { $0.operation == "model.generation" })?.runID == "synthetic-run")
        }
    }

    @Test("slowest-stage attribution excludes totals and nested model breakdowns")
    func dupSlowestStageExcludesTotals() {
        let events = [("dictation.total", 20.0), ("dictation.release-to-insert", 18.0),
                      ("dictation.cleanup", 2.0), ("dictation.transcription", 1.0),
                      ("model.decode", 1.8)].map {
            DiagnosticsRuntimeTiming(date: Date(), operation: $0.0, seconds: $0.1)
        }
        #expect(DiagnosticsTimingSummarizer.slowestStage(events)?.operation == "dictation.cleanup")
        #expect(DiagnosticsTimingSummarizer.slowestStage(Array(events.prefix(2))) == nil)
    }

    @Test("legacy timing JSON decodes with absent run metadata")
    func legacyTimingDecodesWithoutRunMetadata() throws {
        let data = Data(#"{"date":0,"operation":"dictation.transcription","seconds":0.4,"cold":true}"#.utf8)
        let timing = try JSONDecoder().decode(DiagnosticsRuntimeTiming.self, from: data)

        #expect(timing == DiagnosticsRuntimeTiming(date: Date(timeIntervalSinceReferenceDate: 0),
                                                 operation: "dictation.transcription",
                                                 seconds: 0.4, cold: true))
        let fields = Set(Mirror(reflecting: timing).children.compactMap { $0.label })
        #expect(Set(["runID", "outcome", "fallbackReason", "modelLoadCount", "modelCallCount"])
            .isSubset(of: fields))

        let encoded = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(timing))
            as? [String: Any])
        for field in ["runID", "outcome", "fallbackReason", "modelLoadCount", "modelCallCount"] {
            #expect(encoded[field] == nil)
        }
    }

    @Test("existing timing initializer keeps unknown observations absent")
    func existingTimingInitializerOmitsUnobservedMetadata() throws {
        let timing = DiagnosticsRuntimeTiming(date: Date(timeIntervalSinceReferenceDate: 0),
                                              operation: "dictation.cleanup", seconds: 0, cold: nil)
        let encoded = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(timing))
            as? [String: Any])
        for field in ["cold", "runID", "outcome", "fallbackReason", "modelLoadCount", "modelCallCount"] {
            #expect(encoded[field] == nil)
        }
        #expect(try JSONDecoder().decode(DiagnosticsRuntimeTiming.self,
                                        from: JSONEncoder().encode(timing)) == timing)
    }

    @Test("timing JSON preserves observed run, fallback and model counts")
    func extendedTimingRoundTripsObservedMetadata() throws {
        let data = Data(#"""
            {"date":0,"operation":"dictation.cleanup","seconds":1.25,"cold":true,
             "runID":"run-new","outcome":"copied","fallbackReason":"cleanup-unavailable",
             "modelLoadCount":1,"modelCallCount":0}
            """#.utf8)
        let timing = try JSONDecoder().decode(DiagnosticsRuntimeTiming.self, from: data)
        let encodedData = try JSONEncoder().encode(timing)
        let encoded = try #require(JSONSerialization.jsonObject(with: encodedData) as? [String: Any])

        #expect(encoded["runID"] as? String == "run-new")
        #expect(encoded["outcome"] as? String == "copied")
        #expect(encoded["fallbackReason"] as? String == "cleanup-unavailable")
        #expect(encoded["modelLoadCount"] as? Int == 1)
        #expect(encoded["modelCallCount"] as? Int == 0)
        #expect(encoded["cold"] as? Bool == true)
        #expect(timing.seconds == 1.25)
        #expect(try JSONDecoder().decode(DiagnosticsRuntimeTiming.self, from: encodedData) == timing)
    }

    @Test("timing JSON distinguishes every terminal delivery outcome",
          arguments: ["inserted", "copied", "copy-failed", "cancelled", "failed"])
    func extendedTimingPreservesTerminalOutcome(outcome: String) throws {
        let data = try JSONSerialization.data(withJSONObject: [
            "date": 0, "operation": "dictation.delivery", "seconds": 0,
            "cold": false, "runID": "run-new", "outcome": outcome
        ])
        let timing = try JSONDecoder().decode(DiagnosticsRuntimeTiming.self, from: data)
        let encoded = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(timing))
            as? [String: Any])

        #expect(encoded["outcome"] as? String == outcome)
        #expect(encoded["cold"] as? Bool == false)
        #expect(encoded["fallbackReason"] == nil)
        #expect(encoded["modelLoadCount"] == nil)
        #expect(encoded["modelCallCount"] == nil)
    }

    @Test("timing summaries keep cold, warm and delivery endpoints in separate cohorts")
    func summariesSeparateLifecycleAndDelivery() {
        let date = Date(timeIntervalSinceReferenceDate: 0)
        let timings = [
            DiagnosticsRuntimeTiming(date: date, operation: "dictation.total", seconds: 20, cold: true, outcome: "copied"),
            .init(date: date, operation: "dictation.total", seconds: 1, cold: false, outcome: "copied"),
            .init(date: date, operation: "dictation.total", seconds: 2, cold: false, outcome: "paste-dispatched"),
            .init(date: date, operation: "dictation.total", seconds: 3, cold: false, outcome: "paste-dispatched")
        ]
        let summaries = DiagnosticsTimingSummarizer.summarize(timings)
        #expect(summaries.count == 3)
        #expect(summaries.first { $0.cold == true }?.p95 == 20)
        #expect(summaries.first { $0.cold == false && $0.outcome == "copied" }?.p95 == 1)
        #expect(summaries.first { $0.outcome == "paste-dispatched" }?.count == 2)
        #expect(summaries.first { $0.outcome == "paste-dispatched" }?.p95 == 3)
    }

    @Test("correlated timing summaries preserve percentiles without mixing interleaved runs")
    func correlatedTimingSummariesPreservePercentiles() throws {
        let data = Data(#"""
            [{"date":7,"operation":"dictation.delivery","seconds":0.05,"runID":"run-new","outcome":"inserted"},
             {"date":6,"operation":"dictation.transcription","seconds":0.8,"runID":"run-new"},
             {"date":5,"operation":"dictation.transcription","seconds":99,"runID":"run-other"},
             {"date":4,"operation":"dictation.transcription","seconds":0.4,"runID":"run-new"},
             {"date":3,"operation":"dictation.transcription","seconds":75},
             {"date":2,"operation":"dictation.transcription","seconds":0.2,"runID":"run-new"},
             {"date":1,"operation":"dictation.transcription","seconds":0.1,"runID":"run-new"}]
            """#.utf8)
        let timings = try JSONDecoder().decode([DiagnosticsRuntimeTiming].self, from: data)
        let records = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(timings))
            as? [[String: Any]])
        let runTimings = zip(timings, records)
            .filter { $0.1["runID"] as? String == "run-new" }
            .map { $0.0 }

        #expect(runTimings.count == 5)
        let correlated = DiagnosticsTimingSummarizer.summarize(runTimings)
        let recognition = correlated.first { $0.operation == "dictation.transcription" }
        #expect(recognition?.count == 4)
        #expect(recognition?.p50 == 0.2)
        #expect(recognition?.p95 == 0.8)
        #expect(correlated.first { $0.operation == "dictation.delivery" }?.p50 == 0.05)

        let aggregate = DiagnosticsTimingSummarizer.summarize(timings)
            .first { $0.operation == "dictation.transcription" }
        #expect(aggregate?.count == 6)
        #expect(aggregate?.p50 == 0.4)
        #expect(aggregate?.p95 == 99)
    }

    @Test("latest run excludes interleaved runs and uncorrelated caption events")
    func latestRunKeepsInterleavedEventsCorrelated() {
        let date = Date(timeIntervalSinceReferenceDate: 0)
        let caption = DiagnosticsRuntimeTiming(date: date, operation: "captions.asr.rtf", seconds: 99)
        let delivery = DiagnosticsRuntimeTiming(date: date, operation: "dictation.delivery",
                                                seconds: 0.05, runID: "new", outcome: "inserted")
        let other = DiagnosticsRuntimeTiming(date: date, operation: "dictation.cleanup",
                                             seconds: 75, runID: "other", outcome: "cancelled")
        let recognition = DiagnosticsRuntimeTiming(date: date, operation: "dictation.transcription",
                                                   seconds: 0.4, runID: "new")
        let selected = DiagnosticsTimingSummarizer.latestRun([caption, delivery, other, recognition])

        #expect(selected == [delivery, recognition])
        #expect(DiagnosticsTimingSummarizer.summarize(selected).map(\.operation)
            == ["dictation.delivery", "dictation.transcription"])
    }

    @Test("latest run is absent for empty or legacy-only history")
    func latestRunDoesNotInferLegacyRunIDs() {
        let legacy = DiagnosticsRuntimeTiming(date: Date(), operation: "dictation.delivery", seconds: 0.1)
        #expect(DiagnosticsTimingSummarizer.latestRun([]).isEmpty)
        #expect(DiagnosticsTimingSummarizer.latestRun([legacy]).isEmpty)
    }

    @Test("latest run selects only events in the newest twenty-record window")
    func latestRunIsBoundedBeforeGrouping() {
        let date = Date(timeIntervalSinceReferenceDate: 0)
        let latest = DiagnosticsRuntimeTiming(date: date, operation: "dictation.delivery",
                                              seconds: 0.1, runID: "new")
        let legacy = DiagnosticsRuntimeTiming(date: date, operation: "captions.asr.rtf", seconds: 0.2)
        let staleMatch = DiagnosticsRuntimeTiming(date: date, operation: "dictation.cleanup",
                                                  seconds: 99, runID: "new")

        #expect(DiagnosticsTimingSummarizer.latestRun(
            [latest] + Array(repeating: legacy, count: 19) + [staleMatch]) == [latest])
        #expect(DiagnosticsTimingSummarizer.latestRun(
            Array(repeating: legacy, count: 20) + [staleMatch]).isEmpty)
    }

    @Test("recorded run metadata persists in an explicitly isolated diagnostics domain")
    func recordedTimingMetadataSurvivesFlushAndReload() throws {
        try withIsolatedHistory { defaults in
            Diagnostics.recordTiming(operation: "dictation.delivery", seconds: 0.05, cold: false,
                                     runID: "new", outcome: "copied", fallbackReason: "validation-rejected",
                                     modelLoadCount: 0, modelCallCount: 1)
            let timing = try #require(Diagnostics.recentTimings.first)
            #expect(timing.runID == "new")
            #expect(timing.outcome == "copied")
            #expect(timing.fallbackReason == "validation-rejected")
            #expect(timing.modelLoadCount == 0)
            #expect(timing.modelCallCount == 1)
            #expect(timing.cold == false)
            Diagnostics.flushNow()
            #expect(defaults.data(forKey: "saiityRecentRuntimeTimings") != nil)
            Diagnostics.dropRuntimeHistoryCacheForTests()
            #expect(Diagnostics.recentTimings == [timing])
            #expect(Diagnostics.recentLatestRun == [timing])
        }
    }

    @Test("runtime timing ignores nonfinite and negative durations")
    func recordedTimingRejectsInvalidDurations() throws {
        try withIsolatedHistory { _ in
            for seconds in [Double.nan, .infinity, -.infinity, -1] {
                Diagnostics.recordTiming(operation: "dictation.cleanup", seconds: seconds, runID: "new")
            }
            #expect(Diagnostics.recentTimings.isEmpty)
            Diagnostics.recordTiming(operation: "dictation.cleanup", seconds: 0, runID: "new")
            #expect(Diagnostics.recentTimings.count == 1)
        }
    }

    @Test("isolated diagnostics scope restores its previous domain and buffered history")
    func isolatedHistoryScopeRestoresOuterHistory() throws {
        try withIsolatedHistory { defaults in
            Diagnostics.recordTiming(operation: "outer", seconds: 0.5)
            Diagnostics.recordFailure(operation: "outer", reason: "synthetic failure")
            let previousTimings = Diagnostics.recentTimings
            let previousFailures = Diagnostics.recentFailures
            try withIsolatedHistory { _ in
                #expect(Diagnostics.recentTimings.isEmpty)
                #expect(Diagnostics.recentFailures.isEmpty)
                Diagnostics.recordTiming(operation: "inner", seconds: 0.1)
                Diagnostics.clearRuntimeHistoryForTests()
                #expect(Diagnostics.recentTimings.isEmpty)
            }
            #expect(Diagnostics.recentTimings == previousTimings)
            #expect(Diagnostics.recentFailures == previousFailures)
            Diagnostics.flushNow()
            let data = try #require(defaults.data(forKey: "saiityRecentRuntimeTimings"))
            #expect(try JSONDecoder().decode([DiagnosticsRuntimeTiming].self, from: data) == previousTimings)
        }
    }

    private func withIsolatedHistory(_ body: (UserDefaults) throws -> Void) throws {
        let suite = "saiity.DiagnosticsTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        try Diagnostics.withRuntimeHistoryForTests(defaults: defaults) {
            try body(defaults)
        }
    }

    @Test("runtime diagnostics keep a bounded, newest-first history")
    func boundedHistory() throws {
        try withIsolatedHistory { _ in
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
    }

    @Test("synthetic diagnostics report includes runtime failures and legacy timings")
    func reportIncludesRuntimeHistory() {
        let date = Date(timeIntervalSinceReferenceDate: 0)
        let report = Diagnostics.runtimeHistoryReport(
            failures: [.init(date: date, operation: "dictation.translation", reason: "original preserved")],
            timings: [.init(date: date, operation: "translator.prepare", seconds: 1.25, cold: true)])
            .joined(separator: "\n")
        #expect(report.contains("recent failures:"))
        #expect(report.contains("dictation.translation: original preserved"))
        #expect(report.contains("translator.prepare: 1.250s · cold"))
        #expect(report.contains("translator.prepare: n=1 p50=1.250s p95=1.250s"))
        #expect(report.contains("latest dictation run:\n  none"))
        #expect(!report.contains("runID="))
        #expect(!report.contains("outcome="))
        #expect(!report.contains("modelLoadCount="))
    }

    @Test("synthetic diagnostics export includes correlated run evidence and observed metadata")
    func reportIncludesCorrelatedRunMetadata() throws {
        let date = Date(timeIntervalSinceReferenceDate: 0)
        let runID = "00000000-0000-0000-0000-000000000001"
        let timings = [
            DiagnosticsRuntimeTiming(date: date, operation: "dictation.delivery", seconds: 0.05,
                                     runID: runID, outcome: "copied", fallbackReason: "cleanup-unavailable"),
            DiagnosticsRuntimeTiming(date: date, operation: "dictation.cleanup", seconds: 99,
                                     runID: "00000000-0000-0000-0000-000000000002", outcome: "cancelled"),
            DiagnosticsRuntimeTiming(date: date, operation: "dictation.cleanup", seconds: 1.25, cold: true,
                                     runID: runID, modelLoadCount: 1, modelCallCount: 0)
        ]
        let report = Diagnostics.runtimeHistoryReport(failures: [], timings: timings).joined(separator: "\n")
        let grouped = try #require(report.components(separatedBy: "latest dictation run:\n").last)
        #expect(grouped.contains("dictation.delivery: 0.050s"))
        #expect(grouped.contains("runID=\(runID)"))
        #expect(grouped.contains("outcome=copied"))
        #expect(grouped.contains("fallbackReason=cleanup-unavailable"))
        #expect(grouped.contains("dictation.cleanup: 1.250s · cold"))
        #expect(grouped.contains("modelLoadCount=1"))
        #expect(grouped.contains("modelCallCount=0"))
        #expect(!grouped.contains("99.000s"))
        #expect(!grouped.contains("outcome=cancelled"))
        #expect(report.contains("dictation.cleanup: n=1 p50=1.250s p95=1.250s [cold, unspecified]"))
        #expect(report.contains("dictation.cleanup: n=1 p50=99.000s p95=99.000s [unspecified, cancelled]"))
    }

    @Test("diagnostics export accepts only content-free run IDs and controlled metadata codes")
    func reportOmitsUncontrolledRunMetadata() {
        let date = Date(timeIntervalSinceReferenceDate: 0)
        let report = Diagnostics.runtimeHistoryReport(
            failures: [.init(date: date, operation: "dictation.cleanup",
                             reason: "sAiity live translated: PRIVATE_SOURCE")],
            timings: [.init(date: date, operation: "dictation.delivery", seconds: 0.1,
                            runID: "PRIVATE_TRANSCRIPT", outcome: "PRIVATE_WINDOW_TITLE",
                            fallbackReason: "PRIVATE_FILENAME", modelLoadCount: -1, modelCallCount: -1)])
            .joined(separator: "\n")
        for payload in ["PRIVATE_SOURCE", "PRIVATE_TRANSCRIPT", "PRIVATE_WINDOW_TITLE", "PRIVATE_FILENAME"] {
            #expect(!report.contains(payload))
        }
        #expect(report.contains("<redacted>"))
        #expect(!report.contains("modelLoadCount="))
        #expect(!report.contains("modelCallCount="))
    }

    @Test("diagnostics export preserves every controlled outcome and observed fallback code")
    func reportPreservesControlledCodes() {
        let date = Date(timeIntervalSinceReferenceDate: 0)
        for outcome in ["inserted", "copied", "copy-failed", "cancelled", "failed"] {
            let report = Diagnostics.runtimeHistoryReport(failures: [], timings: [
                .init(date: date, operation: "dictation.delivery", seconds: 0, outcome: outcome)
            ]).joined(separator: "\n")
            #expect(report.contains("outcome=\(outcome)"))
            #expect(!report.contains("fallbackReason="))
        }
        for reason in ["cleanup-unavailable", "translation-unavailable", "validation-rejected"] {
            let report = Diagnostics.runtimeHistoryReport(failures: [], timings: [
                .init(date: date, operation: "dictation.cleanup", seconds: 0, fallbackReason: reason)
            ]).joined(separator: "\n")
            #expect(report.contains("fallbackReason=\(reason)"))
            #expect(!report.contains("outcome="))
        }
    }

    @Test("a persisted history larger than the limit is still served bounded")
    func persistedHistoryIsBoundedOnRead() throws {
        try withIsolatedHistory { defaults in
            // Simulates a defaults file written by a build with a larger limit,
            // or corrupted by a partial write. The reader must not trust it.
            let oversized = (0..<64).map {
                DiagnosticsRuntimeTiming(date: Date(), operation: "stale-\($0)",
                                         seconds: Double($0), cold: nil)
            }
            defaults.set(try JSONEncoder().encode(oversized), forKey: "saiityRecentRuntimeTimings")
            Diagnostics.dropRuntimeHistoryCacheForTests()

            #expect(Diagnostics.recentTimings.count == 20)
            #expect(Diagnostics.recentTimings.first?.operation == "stale-63")
        }
    }

    @Test("a burst of events costs one write, and the last event still lands on disk")
    func burstIsCoalescedButNotLost() throws {
        try withIsolatedHistory { defaults in
            // A burst must not write per event or lose its newest event.
            for index in 0..<25 {
                Diagnostics.recordTiming(operation: "captions.visible-lag", seconds: Double(index) / 100)
            }
            #expect(Diagnostics.recentTimings.count == 20)

            Diagnostics.flushNow()

            let persisted = defaults.data(forKey: "saiityRecentRuntimeTimings")
            #expect(persisted != nil)
            let decoded = try? JSONDecoder().decode(
                [DiagnosticsRuntimeTiming].self, from: persisted ?? Data())
            #expect(decoded?.count == 20)
            #expect(decoded?.last?.seconds == 0.24)
        }
    }

    @Test("history is readable before any flush, not only afterwards")
    func readsAreServedFromMemory() throws {
        try withIsolatedHistory { _ in
            Diagnostics.recordTiming(operation: "captions.asr.rtf", seconds: 0.4)
            Diagnostics.recordFailure(operation: "captions.backend.start", reason: "load failed")

            // No flush, no notification: the settings pages read this directly.
            #expect(Diagnostics.recentTimings.first?.operation == "captions.asr.rtf")
            #expect(Diagnostics.latestFailure?.reason == "load failed")
        }
    }

    @Test("timing summaries expose p50 and p95 for recent stages")
    func timingPercentiles() throws {
        try withIsolatedHistory { _ in
            for value in [0.1, 0.2, 0.4, 0.8] {
                Diagnostics.recordTiming(operation: "dictation.transcription", seconds: value)
            }

            let summary = Diagnostics.recentTimingSummaries.first { $0.operation == "dictation.transcription" }
            #expect(summary?.count == 4)
            #expect(summary?.p50 == 0.2)
            #expect(summary?.p95 == 0.8)
        }
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
