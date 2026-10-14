import Foundation
import AVFoundation
import Testing

@testable import sAiity

@Suite struct CaptionSpeakerTests {
    @Test("duplicate and invalid speaker frames cannot invent coverage across a hole")
    func incompleteTimelineDoesNotLabel() {
        var timeline = CaptionSpeakerTimeline()
        timeline.append([.init(start: 0, end: 0.3, speakers: [0])])
        timeline.append([.init(start: 0, end: 0.3, speakers: [1]),
                         .init(start: 0.45, end: 0.5, speakers: []),
                         .init(start: .nan, end: .infinity, speakers: [0])])
        #expect(timeline.annotation(start: 0, end: 0.5) == nil)
        #expect(timeline.frames.count == 2)
        #expect(timeline.confirmedThrough == 0.5)
    }
    private struct Reference: Decodable {
        struct Turn: Decodable {
            let start: Double
            let end: Double
            let speaker: String?
            let overlapping: Bool
        }
        let turns: [Turn]
    }

    @Test("installed speaker model matches local audio turns without downloading",
          .enabled(if: ProcessInfo.processInfo.environment["SAIITY_SPEAKER_BENCHMARK_DIR"] != nil))
    func installedModel() async throws {
        let root = try #require(ProcessInfo.processInfo.environment["SAIITY_SPEAKER_BENCHMARK_DIR"])
        try #require(CaptionSpeakerTracker.isInstalled, "Install Speaker identification first; downloads disabled")
        let directory = URL(fileURLWithPath: root, isDirectory: true)
        let reference = try JSONDecoder().decode(Reference.self, from: Data(contentsOf: directory.appendingPathComponent("speakers.json")))
        try #require(!reference.turns.isEmpty, "No reference speaker turns")
        let file = try AVAudioFile(forReading: directory.appendingPathComponent("speakers.wav"))
        try #require(file.fileFormat.sampleRate == 16_000 && file.fileFormat.channelCount == 1,
                     "Expected 16 kHz mono PCM")
        try #require(file.length > 0 && file.length <= 16_000 * 60)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)))
        try file.read(into: buffer)
        let channel = try #require(buffer.floatChannelData?[0])
        let samples = Array(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
        let engine = try CaptionSpeakerTracker.installedEngine()
        defer { engine.stop() }
        var timeline = CaptionSpeakerTimeline()
        let started = ContinuousClock.now
        for offset in stride(from: 0, to: samples.count, by: 3_200) {
            timeline.append(try engine.process(Array(samples[offset..<min(samples.count, offset + 3_200)])))
        }
        timeline.append(try engine.finish())
        var mapping: [String: String] = [:]
        for turn in reference.turns {
            let result = try #require(timeline.annotation(start: turn.start, end: turn.end), "Unidentified reference turn")
            #expect(result.overlapping == turn.overlapping)
            if let expected = turn.speaker {
                let observed = try #require(result.speaker)
                if let earlier = mapping[expected] { #expect(observed == earlier, "Voice identity changed") }
                else { #expect(!mapping.values.contains(observed), "Two speakers collapsed into one"); mapping[expected] = observed }
            }
        }
        let elapsed = started.duration(to: .now).components
        print("SAIITY_SPEAKERS_BENCHMARK seconds=\(Double(elapsed.seconds)+Double(elapsed.attoseconds)/1e18) memoryBytes=\(MemoryPolicy.physicalFootprint()) turns=\(reference.turns.count)")
    }
    private func frames(_ speaker: [Int], start: Int, count: Int) -> [CaptionSpeakerTimeline.Frame] {
        (start..<(start + count)).map { .init(start: Double($0) / 10, end: Double($0 + 1) / 10, speakers: speaker) }
    }

    @Test("speaker evidence stays stable across pauses and leaves uncertain transitions unlabelled")
    func speakerTurns() {
        var timeline = CaptionSpeakerTimeline()
        timeline.append(frames([0], start: 0, count: 10))
        timeline.append(frames([], start: 10, count: 10))
        timeline.append(frames([1], start: 20, count: 10))
        timeline.append(frames([0], start: 30, count: 10))
        #expect(timeline.annotation(start: 0, end: 1)?.speaker == "voice-1")
        #expect(timeline.annotation(start: 1, end: 2) == nil)
        #expect(timeline.annotation(start: 2, end: 3)?.speaker == "voice-2")
        #expect(timeline.annotation(start: 3, end: 4)?.speaker == "voice-1")
        #expect(timeline.annotation(start: 2, end: 4)?.speaker == "voice-1,2")
        #expect(CaptionSpeakerAnnotation.label(speaker: "voice-1,2", overlapping: false, localized: false) == "Speakers 1, 2")
        #expect(timeline.annotation(start: 4, end: 5) == nil)
    }

    @Test("overlap is marked without guessing whose words the ASR recovered")
    func overlapAndRetention() {
        var timeline = CaptionSpeakerTimeline()
        timeline.append(frames([0, 1], start: 0, count: 10))
        #expect(timeline.annotation(start: 0, end: 1) == .init(speaker: nil, overlapping: true))
        timeline.append(frames([0], start: 10, count: 36_000))
        #expect(timeline.frames.count <= 1_201)
        #expect(timeline.annotation(start: 0, end: 1) == nil)
        #expect(timeline.annotation(start: .nan, end: 1) == nil)
        #expect(CaptionSpeakerAnnotation.label(speaker: "speaker-0", overlapping: false) == nil)
        #expect(CaptionSpeakerAnnotation.label(speaker: "voice-0", overlapping: false) == nil)
    }

    @Test("the bubble keeps speaker labels paired with their original and translation")
    func historyAndExports() {
        var history = CaptionHistory()
        history.upsertOriginal("Hello", sentenceID: 2)
        history.setSpeaker("Speaker 1", forSentenceID: 2)
        history.upsertTranslation("Hallo", forSentenceID: 2, stale: false)
        history.upsertOriginal("Hello again", sentenceID: 2)
        #expect(history.entries[0].speakerLabel == "Speaker 1")
        history.clear()
        history.setSpeaker("Speaker 2", forSentenceID: 2)
        #expect(history.entries.isEmpty)
        let segment = Segment(i: 0, t0: 0, t1: 2, text: "Hello", loc: "en",
                              tr: "Hallo", trLoc: "de", words: nil, speaker: "voice-1")
        #expect(Export.txt([segment]).contains("[Speaker 1] Hello\nHallo"))
        #expect(Export.srt([segment]).contains("[Speaker 1] Hello"))
        #expect(Export.vtt([segment]).contains("[Speaker 1] Hello"))
    }

    final class Observation: @unchecked Sendable {
        let lock = NSLock()
        var batches: [[Float]] = []
        var concurrent = 0
        var peak = 0
        var stops = 0
        var failures = 0
        var finishes = 0
        func engine(blocked: DispatchSemaphore? = nil) -> CaptionSpeakerTracker.Engine {
            .init(process: { samples in
                self.lock.withLock { self.concurrent += 1; self.peak = max(self.peak, self.concurrent) }
                blocked?.wait()
                self.lock.withLock { self.batches.append(samples); self.concurrent -= 1 }
                return []
            }, finish: { self.lock.withLock { self.finishes += 1 }; return [] },
            stop: { self.lock.withLock { self.stops += 1 } })
        }
    }

    @Test("speaker processing serializes and drains all accepted PCM before release")
    func processingOwnership() async {
        let observation = Observation()
        let tracker = CaptionSpeakerTracker(engine: observation.engine(), onUpdate: { _ in }, onFailure: { _ in })
        let samples = (0..<8_000).map(Float.init)
        tracker.feed(samples)
        await tracker.stop()
        await tracker.stop()
        #expect(observation.lock.withLock { observation.batches.flatMap { $0 }.elementsEqual(samples) })
        #expect(observation.peak == 1)
        #expect(observation.stops == 1)
        #expect(observation.finishes == 1)
    }

    @Test("stop returns final speaker evidence before a new session can invalidate callbacks")
    func finalEvidence() async {
        let engine = CaptionSpeakerTracker.Engine(process: { _ in [] },
            finish: { self.frames([0], start: 0, count: 10) }, stop: {})
        let tracker = CaptionSpeakerTracker(engine: engine, onUpdate: { _ in }, onFailure: { _ in })
        let final = await tracker.stop()
        #expect(final.annotation(start: 0, end: 1)?.speaker == "voice-1")
    }

    @Test("speaker overload fails once after native work ends and cannot grow memory")
    func boundedBacklog() async throws {
        let observation = Observation()
        let blocked = DispatchSemaphore(value: 0)
        let tracker = CaptionSpeakerTracker(engine: observation.engine(blocked: blocked), onUpdate: { _ in },
            onFailure: { _ in observation.lock.withLock { observation.failures += 1 } })
        tracker.feed(Array(repeating: 0.2, count: 3_200))
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while observation.lock.withLock({ observation.concurrent }) == 0, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(1))
        }
        tracker.feed(Array(repeating: 0.2, count: CaptionSpeakerTracker.maximumPendingSamples + 1))
        blocked.signal()
        await tracker.stop()
        #expect(observation.failures == 1)
        #expect(observation.stops == 1)
        #expect(observation.peak == 1)
        #expect(observation.finishes == 0)
    }

    @Test("missing speaker weights never initiate a download")
    func noImplicitDownload() throws {
        if !CaptionSpeakerTracker.isInstalled {
            #expect(throws: TranslationEngineError.self) { _ = try CaptionSpeakerTracker.installedEngine() }
        }
        #expect(CaptionSpeakerTracker.asset.id == "captions.speakers.lseend")
        if case .remove(let url) = CaptionSpeakerTracker.asset.removal {
            #expect(url.standardizedFileURL.path.hasPrefix(ModelRegistry.root.path + "/"))
        }
    }
}
