import AVFoundation
import Testing

@testable import sAiity

@Suite struct StreamingASRBackendTests {
    final class FakeEngine: FluidStreamingEngine, @unchecked Sendable {
        let sampleRate = 16_000.0
        var loads = 0
        var resets = 0
        var teardowns = 0
        var finishResult: String?
        var finishCalls = 0
        var partial: (@Sendable (String) -> Void)?

        func load(progress: @escaping @Sendable (String) -> Void) async throws {
            loads += 1
        }

        func reset() async {
            resets += 1
        }

        func setPartial(_ callback: @escaping @Sendable (String) -> Void) async {
            partial = callback
        }
        func process(_ samples: [Float]) async throws {}
        func finishSession() async -> String? {
            finishCalls += 1
            return finishResult
        }

        func teardown() async {
            teardowns += 1
        }

        func detectedLanguage() async -> String? { "en" }
    }

    final class RecordingEngine: FluidStreamingEngine, @unchecked Sendable {
        let sampleRate = 16_000.0
        private let lock = NSLock()
        private var batches: [[Float]] = []

        var processedSamples: [Float] {
            lock.withLock { batches.flatMap { $0 } }
        }

        func load(progress: @escaping @Sendable (String) -> Void) async throws {}
        func reset() async {}
        func setPartial(_ callback: @escaping @Sendable (String) -> Void) async {}

        func process(_ samples: [Float]) async throws {
            lock.withLock { batches.append(samples) }
        }

        func finishSession() async -> String? { nil }
        func teardown() async {}
    }

    final class SegmentedEngine: FluidStreamingEngine, @unchecked Sendable {
        let sampleRate = 16_000.0
        var events: [String] = []
        var finishResults: [String?] = []
        var languages: [String?] = []
        var finishIndex = 0
        var waitsForCancellation = false
        var processStarted = false

        func load(progress: @escaping @Sendable (String) -> Void) async throws {
            events.append("load")
        }

        func reset() async {
            events.append("reset")
        }

        func setPartial(_ callback: @escaping @Sendable (String) -> Void) async {
            events.append("partial")
        }

        func process(_ samples: [Float]) async throws {
            processStarted = true
            events.append("process-\(samples.first ?? -1)")
            if waitsForCancellation {
                try await Task.sleep(nanoseconds: 60_000_000_000)
            }
        }

        func finishSession() async -> String? {
            defer { finishIndex += 1 }
            events.append("finish")
            return finishResults[finishIndex]
        }

        func teardown() async {
            events.append("teardown")
        }

        func detectedLanguage() async -> String? {
            languages[max(0, finishIndex - 1)]
        }
    }

    final class ChunkLog: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [TranscriptChunk] = []

        func append(_ chunk: TranscriptChunk) {
            lock.withLock { storage.append(chunk) }
        }

        var values: [TranscriptChunk] {
            lock.withLock { storage }
        }

        func removeAll() {
            lock.withLock { storage.removeAll(keepingCapacity: true) }
        }
    }

    @Test("stopping a streaming backend keeps it reusable until release")
    func stopPreservesLoadedEngine() async throws {
        let engine = FakeEngine()
        let backend = StreamingASRBackend(name: "Test", engine: engine)

        try await backend.prepare(locale: Locale(identifier: "en-US")) { _ in }
        try await backend.start { _ in }
        await backend.stop()

        #expect(engine.loads == 1)
        #expect(engine.teardowns == 0)

        try await backend.start { _ in }
        await backend.stop()
        await backend.release()

        #expect(engine.loads == 1)
        #expect(engine.resets >= 2)
        #expect(engine.teardowns == 1)
    }

    @Test("streaming batches swap without dropping captured samples")
    func streamingBatchSwapConservesSamples() async throws {
        let engine = RecordingEngine()
        let backend = StreamingASRBackend(name: "Test", engine: engine)
        try await backend.prepare(locale: Locale(identifier: "en-US")) { _ in }
        try await backend.start { _ in }

        let format = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4)!
        buffer.frameLength = 4
        for (index, sample) in [1, 2, 3, 4].enumerated() {
            buffer.floatChannelData![0][index] = Float(sample)
        }
        backend.feed(buffer)

        for _ in 0..<100 where engine.processedSamples.count < 4 {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        await backend.stop()

        #expect(engine.processedSamples == [1.0, 2.0, 3.0, 4.0])
        await backend.release()
    }

    @Test("dictation completion returns the full engine result without emitting a caption")
    func dictationCompletionIsAuthoritativeAndSilent() async throws {
        let engine = FakeEngine()
        engine.finishResult = "Schedule a meeting with Sarah."
        let backend = StreamingASRBackend(name: "Test", engine: engine)
        let emitted = ChunkLog()

        try await backend.prepare(locale: Locale(identifier: "en-US")) { _ in }
        try await backend.start { emitted.append($0) }
        let result = await backend.finishDictation()

        #expect(result == "Schedule a meeting with Sarah.")
        #expect(engine.finishCalls == 1)
        #expect(emitted.values.isEmpty)

        try await backend.start { emitted.append($0) }
        _ = await backend.finishDictation()
        #expect(engine.loads == 1)
        #expect(engine.finishCalls == 2)
        await backend.release()
    }

    @Test("caption stop still emits only the uncommitted suffix")
    func captionStopKeepsRollingCommitBehavior() async throws {
        let engine = FakeEngine()
        engine.finishResult = "Already committed. tail"
        let backend = StreamingASRBackend(name: "Test", engine: engine)
        let emitted = ChunkLog()

        try await backend.prepare(locale: Locale(identifier: "en-US")) { _ in }
        try await backend.start { emitted.append($0) }
        engine.partial?("Already committed.")
        engine.partial?("Already committed. tail")
        emitted.removeAll()
        await backend.stop()

        #expect(engine.finishCalls == 1)
        #expect(emitted.values.map(\.text) == ["tail"])
        #expect(emitted.values.allSatisfy { $0.isFinal })
        await backend.release()
    }

    @Test("segmented dictation resets the recognizer and processes regions sequentially")
    func segmentedDictationResetsBetweenRegions() async throws {
        let engine = SegmentedEngine()
        engine.finishResults = ["Hallo", "world"]
        engine.languages = ["de", "en"]
        let backend = StreamingASRBackend(name: "Test", engine: engine)
        try await backend.prepare(locale: Locale(identifier: "auto")) { _ in }
        let regions = [
            DictationSpeechRegion(audioRange: 0..<2, coveredRange: 0..<2),
            DictationSpeechRegion(audioRange: 2..<4, coveredRange: 2..<4),
        ]

        let result = try await backend.transcribeDictation(samples: [1, 2, 3, 4], regions: regions)

        #expect(result.text == "Hallo world")
        #expect(result.languageMetadata.regionLanguages == ["de", "en"])
        #expect(result.languageMetadata.containsMultipleLanguages)
        #expect(engine.events.filter { $0 == "reset" }.count == 4)
        #expect(engine.events.filter { $0 == "process-1.0" } == ["process-1.0"])
        #expect(engine.events.filter { $0 == "process-3.0" } == ["process-3.0"])
        #expect(engine.events.firstIndex(of: "process-1.0")! < engine.events.firstIndex(of: "process-3.0")!)
        await backend.release()
    }

    @Test("cancellation during segmented dictation resets the engine")
    func segmentedDictationCancellation() async throws {
        let engine = SegmentedEngine()
        engine.waitsForCancellation = true
        let backend = StreamingASRBackend(name: "Test", engine: engine)
        try await backend.prepare(locale: Locale(identifier: "auto")) { _ in }
        let region = DictationSpeechRegion(audioRange: 0..<2, coveredRange: 0..<2)
        let task = Task {
            try await backend.transcribeDictation(samples: [1, 2], regions: [region])
        }
        for _ in 0..<100 where !engine.processStarted { await Task.yield() }
        task.cancel()

        do {
            _ = try await task.value
            #expect(Bool(false))
        } catch {
            #expect(error is CancellationError)
        }
        #expect(engine.events.filter { $0 == "reset" }.count >= 2)
        await backend.release()
    }
}
