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
                    do { try await Task.sleep(for: .seconds(3)) }
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
        let deadline = ContinuousClock.now.advanced(by: .seconds(1))
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
