import AVFoundation
import Testing

@testable import sAiity

@Suite struct StreamingASRBackendTests {
    @Test("dropped backlog does not shift captions onto another speaker's audio")
    func capturedClockIncludesDroppedAudio() async throws {
        let engine = RecordingEngine()
        let backend = StreamingASRBackend(name: "Clock", engine: engine)
        try await backend.prepare(locale: .init(identifier: "auto")) { _ in }
        try await backend.start { _ in }
        let format = try #require(await backend.inputFormat)
        let count = 16_000 * 60
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count)))
        buffer.frameLength = AVAudioFrameCount(count)
        buffer.floatChannelData![0].update(repeating: 0.2, count: count)
        backend.feed(buffer)
        await backend.drain(toAudioSample: count)
        #expect(engine.processedSamples.count < count)
        #expect(backend.audioClockEndForTests == count)
        await backend.release()
    }
    final class FakeEngine: FluidStreamingEngine, @unchecked Sendable {
        let sampleRate = 16_000.0
        var loads = 0
        var resets = 0
        var teardowns = 0
        var finishResult: String?
        var finishCalls = 0
        var processError: Error?
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
        func process(_ samples: [Float]) async throws {
            if let processError { throw processError }
        }
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

    final class GatedEngine: FluidStreamingEngine, @unchecked Sendable {
        let sampleRate = 16_000.0
        private let lock = NSLock()
        private var started = false
        private var released = false
        private var continuation: CheckedContinuation<Void, Never>?
        private var batches: [[Float]] = []
        private var inFlight = 0
        private var peak = 0
        private let finalText: (@Sendable ([Float]) -> String?)?

        init(finalText: (@Sendable ([Float]) -> String?)? = nil) { self.finalText = finalText }
        var inputs: [[Float]] { lock.withLock { batches } }
        var maximumInFlight: Int { lock.withLock { peak } }

        var processStarted: Bool { lock.withLock { started } }

        func load(progress: @escaping @Sendable (String) -> Void) async throws {}
        func reset() async { #expect(lock.withLock { inFlight == 0 }) }
        func setPartial(_ callback: @escaping @Sendable (String) -> Void) async {}

        func process(_ samples: [Float]) async throws {
            lock.withLock {
                started = true
                batches.append(samples)
                inFlight += 1
                peak = max(peak, inFlight)
            }
            defer { lock.withLock { inFlight -= 1 } }
            await withCheckedContinuation { continuation in
                let resumeImmediately = lock.withLock { () -> Bool in
                    if released { return true }
                    self.continuation = continuation
                    return false
                }
                if resumeImmediately { continuation.resume() }
            }
        }

        func releaseProcess() {
            let pending = lock.withLock { () -> CheckedContinuation<Void, Never>? in
                released = true
                let value = continuation
                continuation = nil
                return value
            }
            pending?.resume()
        }

        func finishSession() async -> String? {
            #expect(lock.withLock { inFlight == 0 })
            return lock.withLock { finalText?(batches.last ?? []) }
        }
        func teardown() async { #expect(lock.withLock { inFlight == 0 }) }
    }

    final class SegmentedEngine: FluidStreamingEngine, @unchecked Sendable {
        let sampleRate = 16_000.0
        var events: [String] = []
        var finishResults: [String?] = []
        var languages: [String?] = []
        var finishIndex = 0
        var waitsForCancellation = false
        private let startLock = NSLock()
        private var didStart = false
        var processStarted: Bool { startLock.withLock { didStart } }

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
            startLock.withLock { didStart = true }
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

    final class LockedFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var storage = false

        var value: Bool { lock.withLock { storage } }
        func set() { lock.withLock { storage = true } }
    }

    final class MetricsLog: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: StreamingASRMetrics?

        var value: StreamingASRMetrics? { lock.withLock { storage } }
        func set(_ metrics: StreamingASRMetrics) { lock.withLock { storage = metrics } }
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

    @Test("stop drains a final pending batch before releasing the engine")
    func stopDrainsFinalBatch() async throws {
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
        await backend.stop()

        #expect(engine.processedSamples == [1.0, 2.0, 3.0, 4.0])
        await backend.release()
    }

    @Test("processing failures are reported and never counted as consumed audio")
    func processingFailureIsNotCounted() async throws {
        struct TestError: Error {}
        let engine = FakeEngine()
        engine.processError = TestError()
        let metrics = MetricsLog()
        let backend = StreamingASRBackend(name: "Test", engine: engine,
                                          onMetrics: { metrics.set($0) })
        try await backend.prepare(locale: Locale(identifier: "en-US")) { _ in }
        try await backend.start { _ in }

        let format = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1_600)!
        buffer.frameLength = 1_600
        backend.feed(buffer)
        try await Task.sleep(for: .milliseconds(100))
        await backend.stop()

        #expect(metrics.value?.processingErrorCount == 1)
        #expect(metrics.value?.processedAudioSamples == 0)
        await backend.release()
    }

    @Test("fatal processing closes admission and releases every pending drain")
    func failureClosesAudioAndUnblocksAllDrains() async throws {
        struct Failed: Error {}
        let engine = FakeEngine()
        engine.processError = Failed()
        engine.finishResult = "unfinished draft"
        let failed = LockedFlag()
        let backend = StreamingASRBackend(name: "Test", engine: engine)
        backend.setFailureHandler { _ in failed.set() }
        try await backend.prepare(locale: .init(identifier: "en")) { _ in }
        try await backend.start { _ in }
        let format = try #require(await backend.inputFormat)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1_600))
        buffer.frameLength = 1_600
        async let first: Void = backend.drain(toAudioSample: 1_600)
        async let second: Void = backend.drain(toAudioSample: 1_600)
        backend.feed(buffer)
        await first
        await second
        // A time bound, not a yield count: under a busy full-suite run a
        // thousand yields can pass before the failure handler is scheduled.
        let deadline = ContinuousClock.now + .seconds(5)
        while !failed.value, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        #expect(failed.value)
        backend.feed(buffer)
        #expect(backend.pendingSampleCountForTests == 0)
        #expect(await backend.finishDictation() == nil)
        #expect(engine.finishCalls == 0)
        await backend.release()
    }

    @Test("drain waits for the audio watermark before a gap flush")
    func drainWaitsForProcessedAudio() async throws {
        let engine = GatedEngine()
        let backend = StreamingASRBackend(name: "Test", engine: engine)
        try await backend.prepare(locale: Locale(identifier: "en-US")) { _ in }
        try await backend.start { _ in }

        let format = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1_600)!
        buffer.frameLength = 1_600
        backend.feed(buffer)
        for _ in 0..<100 where !engine.processStarted {
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        #expect(engine.processStarted)

        let completed = LockedFlag()
        let drain = Task {
            await backend.drain(toAudioSample: 1_600)
            completed.set()
        }
        try await Task.sleep(nanoseconds: 30_000_000)
        #expect(!completed.value)

        engine.releaseProcess()
        await drain.value
        #expect(completed.value)
        await backend.release()
    }

    @Test("flushing after the watermark keeps the final word")
    func gapFlushKeepsFinalWord() async throws {
        let engine = FakeEngine()
        let backend = StreamingASRBackend(name: "Test", engine: engine)
        let emitted = ChunkLog()
        try await backend.prepare(locale: Locale(identifier: "en-US")) { _ in }
        try await backend.start { emitted.append($0) }

        engine.partial?("Please keep the final word")
        await backend.drain(toAudioSample: 0)
        await backend.flushPending()

        let values = emitted.values
        #expect(values.last?.text == "Please keep the final word")
        #expect(values.last?.isFinal == true)
        #expect(values.dropLast().allSatisfy { !$0.isFinal })
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
        let deadline = ContinuousClock.now + .seconds(2)
        while !engine.processStarted, ContinuousClock.now < deadline { await Task.yield() }
        try #require(engine.processStarted, "Cancellation regression must enter native processing first")
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
