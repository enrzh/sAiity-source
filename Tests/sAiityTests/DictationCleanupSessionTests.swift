import Foundation
import Testing

@testable import sAiity

@Suite @MainActor
struct DictationCleanupSessionTests {
    private let repair = "Send the report, I mean the revised report."

    @MainActor
    private final class MockModel {
        var events: [String] = []
        var calls: [(String, String?, DictationLanguageMetadata)] = []
        var output: String?
        var pause: NativePause?

        func load(_ key: String) -> DictationCleanupSession.Model {
            events.append("load-\(key)")
            return .init(cleanup: { text, language, metadata in
                self.events.append("cleanup-\(key)")
                self.calls.append((text, language, metadata))
                if let pause = self.pause { await pause.wait() }
                return self.output ?? text
            }, stop: {
                self.events.append("stop-\(key)")
            })
        }
    }

    /// Ignores cancellation like a native decode, but auto-releases on failure
    /// so a broken ordering assertion cannot strand the test suite.
    @MainActor
    private final class NativePause {
        var entered = false
        var sawCancellation = false
        private var continuation: CheckedContinuation<Void, Never>?
        private var watchdog: Task<Void, Never>?

        func wait() async {
            entered = true
            await withCheckedContinuation { continuation in
                self.continuation = continuation
                watchdog = Task {
                    // The complete suite runs main-actor tests in parallel;
                    // unrelated model/setup tests can delay this mock task.
                    // Keep the failure escape hatch, but do not make it a
                    // three-second race against the scheduler.
                    do { try await Task.sleep(for: .seconds(10)) }
                    catch { return }
                    Issue.record("Native mock was not explicitly released")
                    release()
                }
            }
            sawCancellation = Task.isCancelled
        }

        func release() {
            watchdog?.cancel()
            watchdog = nil
            let pending = continuation
            continuation = nil
            pending?.resume()
        }
    }

    private func waitUntil(_ condition: () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while !condition(), ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(1))
        }
        return condition()
    }

    @Test("clean English and German and simple fillers never load a model")
    func deterministicRequestsSkipModel() async {
        let session = DictationCleanupSession(gate: TranslationInferenceGate())
        let mock = MockModel()
        let fixtures = [
            ("Please send the report today.", "en", "Please send the report today."),
            ("Bitte sende den Bericht heute.", "de", "Bitte sende den Bericht heute."),
            ("Um, please please send the report today.", "en", "Please send the report today."),
            ("Ähm, bitte bitte sende den Bericht heute.", "de", "Bitte sende den Bericht heute."),
        ]
        for (text, language, expected) in fixtures {
            let result = await session.cleanup(.init(text: text, language: language),
                                               modelKey: "1b") { mock.load("1b") }
            #expect(result?.text == expected)
            #expect(result?.regions.map(\.language) == [language])
        }
        await session.invalidate()
        #expect(mock.events.isEmpty)
        #expect(mock.calls.isEmpty)
    }

    @Test("unresolved corrections load once and reuse the warm model")
    func correctionLoadsAndReuses() async {
        let session = DictationCleanupSession(gate: TranslationInferenceGate())
        let mock = MockModel()
        mock.output = "Send the revised report."
        let input = DictationTranscriptionResult(text: repair, language: "en")
        for _ in 0..<2 {
            let result = await session.cleanup(input, modelKey: "1b") { mock.load("1b") }
            #expect(result?.text == "Send the revised report.")
        }
        #expect(mock.events == ["load-1b", "cleanup-1b", "cleanup-1b"])
        #expect(mock.calls.map { $0.0 } == [repair, repair])
        await session.invalidate()
    }

    @Test("same-language regions share one cleanup request")
    func sameLanguageRegionsBatch() async {
        let session = DictationCleanupSession(gate: TranslationInferenceGate())
        let mock = MockModel()
        mock.output = "Send the revised report."
        let input = DictationTranscriptionResult(regions: [
            .init(text: "Send the report", language: "en-US"),
            .init(text: "I mean the revised report.", language: "en-US"),
        ])

        let result = await session.cleanup(input, modelKey: "1b") { mock.load("1b") }

        #expect(mock.calls.count == 1)
        #expect(mock.calls.first?.0 == "Send the report I mean the revised report.")
        #expect(result?.text == "Send the revised report.")
        #expect(result?.regions.map(\.language) == ["en-US"])
        await session.invalidate()
    }

    /// A model that answers a batched request, so the partial-batch path is
    /// reachable. `MockModel` only implements the single-region `cleanup`.
    @MainActor
    private final class BatchMockModel {
        var batchCalls = 0
        var singleCalls: [String] = []
        /// One output per region; an empty entry is what a malformed response
        /// looks like, and `validate` rejects it.
        var batchOutput: [String]

        init(batchOutput: [String]) {
            self.batchOutput = batchOutput
        }

        func load(_ key: String) -> DictationCleanupSession.Model {
            .init(cleanup: { text, _, _ in
                self.singleCalls.append(text)
                // Echo the input. A fallback that changes nothing still
                // validates, so the test measures model calls, not wording.
                return text
            }, cleanupRegions: { _ in
                self.batchCalls += 1
                return self.batchOutput
            }, stop: {})
        }
    }

    @Test("one bad region in a batch does not re-run the model for the good ones")
    func partialBatchIsKept() async {
        // The bug this pins: a single region failing validation cleared the
        // whole batch, so every region fell through to its own model call —
        // one wasted batched call plus N sequential ones. With ~0.5s per call
        // that is seconds of added latency for a dictation that was already
        // mostly finished.
        //
        // Mixed languages on purpose: the batch path is only reached when
        // `containsMultipleLanguages` is true, so same-language regions would
        // quietly test the single joined call instead.
        let session = DictationCleanupSession(gate: TranslationInferenceGate())
        let english = "Send the report, I mean the revised one."
        let german = "Schicke den Bericht, ich meine den revidierten."
        let mock = BatchMockModel(
            batchOutput: ["Send the revised one.", ""])  // German entry is invalid
        let input = DictationTranscriptionResult(regions: [
            .init(text: english, language: "en-US"),
            .init(text: german, language: "de-DE"),
        ])
        #expect(input.languageMetadata.containsMultipleLanguages,
                "the batch path needs genuinely mixed languages")

        let result = await session.cleanup(input, modelKey: "1b") { mock.load("1b") }

        #expect(mock.batchCalls == 1, "the batch was tried once")
        // The English region validated and must not be re-run; only the German
        // one fell back to a single call.
        #expect(mock.singleCalls == [german],
                "the validated region was sent through the model again")
        #expect(result != nil)
        await session.invalidate()
    }

    @Test("a changed model key tears down before reloading; invalidation tears down once")
    func changedKeyAndInvalidation() async {
        let session = DictationCleanupSession(gate: TranslationInferenceGate())
        let mock = MockModel()
        let input = DictationTranscriptionResult(text: repair, language: "en")
        _ = await session.cleanup(input, modelKey: "1b") { mock.load("1b") }
        _ = await session.cleanup(input, modelKey: "4b") { mock.load("4b") }
        #expect(mock.events == ["load-1b", "cleanup-1b", "stop-1b", "load-4b", "cleanup-4b"])
        await session.invalidate()
        await session.invalidate()
        #expect(mock.events.last == "stop-4b")
        #expect(mock.events.filter { $0 == "stop-4b" }.count == 1)
        _ = await session.cleanup(input, modelKey: "4b") { mock.load("4b") }
        #expect(Array(mock.events.suffix(3)) == ["stop-4b", "load-4b", "cleanup-4b"])
        await session.invalidate()
    }

    @Test("mixed regions retain their language metadata and pass region-local metadata to the model")
    func mixedRegionMetadata() async {
        let session = DictationCleanupSession(gate: TranslationInferenceGate())
        let mock = MockModel()
        let input = DictationTranscriptionResult(regions: [
            .init(text: repair, language: "en-US"),
            .init(text: "Sende den Bericht, ich meine den neuen Bericht.", language: "de-DE"),
        ])
        let result = await session.cleanup(input, modelKey: "1b") { mock.load("1b") }
        #expect(result == input)
        #expect(result?.languageMetadata.containsMultipleLanguages == true)
        #expect(mock.calls.count == 2)
        for (call, region) in zip(mock.calls, input.regions) {
            #expect(call.0 == region.text)
            #expect(call.1 == region.language)
            #expect(call.2 == DictationLanguageMetadata(regions: [region]))
        }
        await session.invalidate()
    }

    @Test("translated model output falls back to the deterministic baseline")
    func translatedOutputFallsBack() async {
        let session = DictationCleanupSession(gate: TranslationInferenceGate())
        let mock = MockModel()
        mock.output = "Sende den überarbeiteten Bericht."
        let input = DictationTranscriptionResult(text: "Um, send the report, I mean the revised report.",
                                                language: "en")
        let result = await session.cleanup(input, modelKey: "1b") { mock.load("1b") }
        #expect(mock.calls.count == 1)
        #expect(result?.text == "Send the report, I mean the revised report.")
        #expect(result?.regions.map(\.language) == ["en"])
        await session.invalidate()
    }

    @Test("queued cancellation never loads or cleans and cannot bypass active native work")
    func queuedCancellation() async {
        let session = DictationCleanupSession(gate: TranslationInferenceGate())
        let mock = MockModel()
        let pause = NativePause()
        mock.pause = pause
        let input = DictationTranscriptionResult(text: repair, language: "en")
        let active = Task { await session.cleanup(input, modelKey: "1b") { mock.load("1b") } }
        let entered = await waitUntil { pause.entered }
        #expect(entered)
        var queuedStarted = false
        let queued = Task {
            queuedStarted = true
            return await session.cleanup(input, modelKey: "cancelled") { mock.load("cancelled") }
        }
        let started = await waitUntil { queuedStarted }
        #expect(started)
        queued.cancel()
        var nextStarted = false
        var nextFinished = false
        let next = Task {
            nextStarted = true
            let result = await session.cleanup(input, modelKey: "4b") { mock.load("4b") }
            nextFinished = true
            return result
        }
        let submitted = await waitUntil { nextStarted }
        #expect(submitted)
        #expect(!nextFinished)
        #expect(mock.events == ["load-1b", "cleanup-1b"])
        mock.pause = nil
        pause.release()
        let activeResult = await active.value
        let cancelledResult = await queued.value
        let nextResult = await next.value
        #expect(activeResult != nil)
        #expect(cancelledResult == nil)
        #expect(nextResult != nil)
        #expect(mock.events == ["load-1b", "cleanup-1b", "stop-1b", "load-4b", "cleanup-4b"])
        await session.invalidate()
    }

    @Test("active cancellation drains native work before teardown and skips all remaining regions")
    func activeCancellationDrains() async {
        let session = DictationCleanupSession(gate: TranslationInferenceGate())
        let mock = MockModel()
        let pause = NativePause()
        mock.pause = pause
        let input = DictationTranscriptionResult(regions: [
            .init(text: repair, language: "en"),
            .init(text: "Sende den Bericht, ich meine den neuen Bericht.", language: "de"),
        ])
        var activeFinished = false
        let active = Task {
            let result = await session.cleanup(input, modelKey: "1b") { mock.load("1b") }
            activeFinished = true
            return result
        }
        let entered = await waitUntil { pause.entered }
        #expect(entered)
        active.cancel()
        var nextStarted = false
        var nextFinished = false
        let next = Task {
            nextStarted = true
            let result = await session.cleanup(.init(text: repair, language: "en"),
                                               modelKey: "4b") { mock.load("4b") }
            nextFinished = true
            return result
        }
        let submitted = await waitUntil { nextStarted }
        #expect(submitted)
        #expect(!activeFinished)
        #expect(!nextFinished)
        #expect(mock.events == ["load-1b", "cleanup-1b"])
        mock.pause = nil
        pause.release()
        let cancelledResult = await active.value
        let nextResult = await next.value
        #expect(cancelledResult == nil)
        #expect(pause.sawCancellation)
        #expect(nextResult != nil)
        #expect(mock.calls.map { $0.0 } == [repair, repair])
        #expect(mock.events == ["load-1b", "cleanup-1b", "stop-1b", "load-4b", "cleanup-4b"])
        await session.invalidate()
    }
}
