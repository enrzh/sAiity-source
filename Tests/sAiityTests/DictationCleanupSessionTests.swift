import Foundation
import Testing

@testable import sAiity

@Suite @MainActor
struct DictationCleanupSessionTests {
    private let repair = "Send the report, I mean the revised report."

    @Test("pause dots reach the existing contextual editor and preserve words")
    func pauseDotsReachModel() async throws {
        let original = "It's weird because that shouldn't happen when you... are currently adding items to the card."
        let expected = "It's weird because that shouldn't happen when you are currently adding items to the card."
        let session = DictationCleanupSession(gate: TranslationInferenceGate())
        var calls = 0
        let result = try #require(await session.cleanup(.init(text: original, language: "en"),
            modelKey: "pause-editor") {
                .init(cleanup: { text, _, _ in
                    calls += 1
                    #expect(text == original)
                    return expected
                }, stop: {})
            })
        #expect(calls == 1)
        #expect(result.text == expected)
        #expect(result.modelAccepted == 1)
        await session.invalidate()
    }

    @Test("unavailable contextual cleanup preserves pause dots and reports fallback")
    func pauseDotsUnavailablePreservesOriginal() async throws {
        let original = "That shouldn't happen when you... are adding items to the card."
        let session = DictationCleanupSession(gate: TranslationInferenceGate())
        let inputs = [DictationTranscriptionResult(text: original, language: "en"),
                      DictationTranscriptionResult(regions: [
                        .init(text: original, language: "en"),
                        .init(text: "Je dois vérifier toutes les factures demain.", language: "fr")
                      ])]
        for input in inputs {
            for key in [nil, "unavailable"] as [String?] {
                let result = try #require(await session.cleanup(input, modelKey: key) {
                    .init(cleanup: { _, _, _ in nil }, stop: {})
                })
                #expect(result.text == input.text)
                #expect(result.languageMetadata.regionLanguages == input.languageMetadata.regionLanguages)
                #expect(result.modelCleanupUnavailable)
                #expect(result.modelCalls == (key == nil ? 0 : 1))
            }
        }
        await session.invalidate()
    }

    @Test("cleanup timings distinguish actual cold load, warm calls and rules-only work")
    func dupTimingCountsObservedInvocations() async throws {
        var timings: [DiagnosticsRuntimeTiming] = []
        let session = DictationCleanupSession(gate: TranslationInferenceGate(), onTiming: { timings.append($0) })
        let id = UUID().uuidString
        await LocalGeneration.$dictationRunID.withValue(id) {
            for text in [repair, repair, "Please send the report today."] {
                _ = await session.cleanup(.init(text: text, language: "en"), modelKey: "one-model") {
                    .init(cleanup: { _, _, _ in "Send the revised report." }, stop: {})
                }
            }
        }
        await session.invalidate()
        #expect(timings.count == 3)
        #expect(timings.map(\.modelLoadCount) == [1, 0, 0])
        #expect(timings.map(\.modelCallCount) == [1, 1, 0])
        #expect(timings.map(\.cold) == [true, false, nil])
        #expect(timings.allSatisfy { $0.runID == id && $0.seconds.isFinite && $0.seconds >= 0 })
        #expect(!timings.contains { $0.operation.contains("report") })
    }

    @Test("cleanup evidence separates actual model calls, accepted output, fallback and rules skips")
    func modelOutcomeCounts() async throws {
        let session = DictationCleanupSession(gate: TranslationInferenceGate())
        let input = DictationTranscriptionResult(text: repair, language: "en")
        let outputs: [String?] = ["Send the revised report.", nil, ""]
        for (index, output) in outputs.enumerated() {
            let result = try #require(await session.cleanup(input, modelKey: "model-\(index)") {
                .init(cleanup: { _, _, _ in output }, stop: {})
            })
            #expect(result.modelCalls == 1)
            #expect(result.modelAccepted == (index == 0 ? 1 : 0))
            #expect(result.modelFallbacks == (index == 0 ? 0 : 1))
            #expect(result.rulesSkipped == 0)
            #expect(result.modelCleanupUnavailable == (index != 0))
        }
        var loads = 0
        let skipped = try #require(await session.cleanup(.init(text: "Please send the report today.", language: "en"),
            modelKey: "rules-only") {
                loads += 1
                return .init(cleanup: { _, _, _ in nil }, stop: {})
            })
        #expect(loads == 0)
        #expect(skipped.modelCalls == 0)
        #expect(skipped.modelAccepted == 0)
        #expect(skipped.modelFallbacks == 0)
        #expect(skipped.rulesSkipped == 1)
        await session.invalidate()
    }

    @Test("one batched model invocation may accept multiple regions without inventing extra calls")
    func batchedModelOutcomeCounts() async throws {
        let session = DictationCleanupSession(gate: TranslationInferenceGate())
        let input = DictationTranscriptionResult(regions: [
            .init(text: "Send the report, I mean the revised one.", language: "en-US"),
            .init(text: "Schicke den Bericht, ich meine den revidierten.", language: "de-DE"),
        ])
        let mock = BatchMockModel(batchOutput: input.regions.map(\.text))
        let result = try #require(await session.cleanup(input, modelKey: "batch") { mock.load("batch") })
        #expect(mock.batchCalls == 1)
        #expect(mock.singleCalls.isEmpty)
        #expect(result.modelCalls == 1)
        #expect(result.modelAccepted == 2)
        #expect(result.modelFallbacks == 0)
        #expect(result.rulesSkipped == 0)
        await session.invalidate()
    }

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
        #expect(result?.text == input.text)
        #expect(result?.regions == input.regions)
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
        #expect(result?.modelCleanupUnavailable == true)
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
