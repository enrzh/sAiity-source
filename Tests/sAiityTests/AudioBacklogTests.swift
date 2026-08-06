import AVFoundation
import Foundation
import Testing

@testable import sAiity

/// The audio path had two ways to consume memory without bound, and neither was
/// visible from the outside until the Mac ran out of it.
///
/// Capture never stops — it delivers buffers roughly fifty times a second for
/// the life of the stream, digital silence included — so anything that stops the
/// pump draining turns `feed` into a leak that grows for as long as the app is
/// open. In the field that came to about 230 MB an hour.
@Suite struct AudioBacklogTests {

    /// Records what it is given and can be told to stall, so a test can hold the
    /// pump still while audio keeps arriving.
    final class RecordingEngine: FluidStreamingEngine, @unchecked Sendable {
        let sampleRate: Double = 16_000
        private let lock = NSLock()
        private var _batches: [Int] = []
        var batches: [Int] { lock.withLock { _batches } }

        func load(progress: @escaping @Sendable (String) -> Void) async throws {}
        func setPartial(_ callback: @escaping @Sendable (String) -> Void) async {}
        func process(_ samples: [Float]) async throws {
            lock.withLock { _batches.append(samples.count) }
        }
        func finishSession() async -> String? { nil }
        func teardown() async {}
    }

    private static func audio(seconds: Double, rate: Double = 16_000) -> AVAudioPCMBuffer {
        let fmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate,
                                channels: 1, interleaved: false)!
        let frames = AVAudioFrameCount(rate * seconds)
        let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: frames)!
        buf.frameLength = frames
        // Non-zero, so nothing downstream can mistake this for the silence path.
        buf.floatChannelData![0].update(repeating: 0.05, count: Int(frames))
        return buf
    }

    @Test("Un-processed audio is capped, not accumulated")
    func backlogIsBounded() {
        let backend = StreamingASRBackend(name: "test", engine: RecordingEngine())
        // No pump is running, which is the state a stopped-and-replaced backend
        // is left in — the case that leaked for as long as the app stayed open.
        for _ in 0..<60 { backend.feed(Self.audio(seconds: 1)) }

        let queued = backend.pendingSampleCountForTests
        let cap = Int(16_000 * 10.0)
        #expect(queued <= cap, "backlog grew to \(queued) samples, cap is \(cap)")
        // And it really did keep the most recent audio rather than dropping
        // everything on the floor.
        #expect(queued > cap / 2, "backlog collapsed to \(queued); it should hold the recent tail")
    }

    @Test("Trimming keeps the newest audio, not the oldest")
    func trimDropsFromTheFront() {
        let backend = StreamingASRBackend(name: "test", engine: RecordingEngine())
        backend.feed(Self.audio(seconds: 9))
        let beforeOverflow = backend.pendingSampleCountForTests
        #expect(beforeOverflow == Int(16_000 * 9), "nothing should be dropped under the cap")

        backend.feed(Self.audio(seconds: 4))
        // 13 s fed against a 10 s cap: the removal count is count - cap, which is
        // strictly less than count. Getting that arithmetic wrong is precisely
        // what traps inside FluidAudio's own compaction.
        #expect(backend.pendingSampleCountForTests == Int(16_000 * 10))
    }

    @Test("Stopping releases the queue rather than keeping its capacity")
    func stopReleasesTheQueue() async {
        let backend = StreamingASRBackend(name: "test", engine: RecordingEngine())
        for _ in 0..<20 { backend.feed(Self.audio(seconds: 1)) }
        #expect(backend.pendingSampleCountForTests > 0)
        await backend.stop()
        #expect(backend.pendingSampleCountForTests == 0)
    }
}

/// The capture callback outlives the backend under it. Switching recognition
/// engine or latency tier builds a new backend, and because both engines want
/// the same 16 kHz format the capture session is never rebuilt — so a closure
/// that captured the backend directly went on feeding the old one forever.
@Suite struct BackendSinkTests {

    final class CountingBackend: TranscriptionBackend, @unchecked Sendable {
        let name: String
        private let lock = NSLock()
        private var _fed = 0
        var fed: Int { lock.withLock { _fed } }

        init(name: String) { self.name = name }
        var inputFormat: AVAudioFormat? { get async { nil } }
        func prepare(locale: Locale, progress: @escaping @Sendable (String) -> Void) async throws {}
        func start(onChunk: @escaping @Sendable (TranscriptChunk) -> Void) async throws {}
        func feed(_ buffer: AVAudioPCMBuffer) { lock.withLock { _fed += 1 } }
        func flushPending() async {}
        func stop() async {}
        func detectedLanguage() async -> String? { nil }
    }

    private static func silence() -> AVAudioPCMBuffer {
        let fmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000,
                                channels: 1, interleaved: false)!
        let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: 160)!
        buf.frameLength = 160
        return buf
    }

    @Test("Audio follows the current backend across a switch")
    func retargetingSendsAudioToTheNewBackend() {
        let old = CountingBackend(name: "old")
        let new = CountingBackend(name: "new")
        let sink = BackendSink()

        sink.point(at: old)
        sink.feed(Self.silence())
        sink.feed(Self.silence())

        sink.point(at: new)
        sink.feed(Self.silence())

        #expect(old.fed == 2)
        // The regression this guards: the replaced backend kept receiving every
        // buffer, with no pump to drain it, while the engine that was supposed
        // to be running got nothing and captions stopped without a word.
        #expect(new.fed == 1, "audio did not follow the switch")
    }

    @Test("A sink with no backend drops audio instead of trapping")
    func nilBackendIsSafe() {
        let sink = BackendSink()
        sink.feed(Self.silence())
        sink.point(at: nil)
        sink.feed(Self.silence())
    }
}
