import AVFoundation
import Foundation
import Testing

@testable import sAiity

/// The whole caption path with real models: speech in, subtitles out.
///
/// Everything here is the production code and the real weights — Nemotron for
/// recognition, Hy-MT2 for translation, `Export` for the subtitle file. It is
/// the closest this environment gets to running the app, and it covers the
/// chain that a unit test cannot: a recogniser's actual wording, fed through
/// real timings, translated for real, and written as a real SRT.
///
/// Opt in — it needs the installed Nemotron tier and the Hy-MT2 weights:
///
///   SAIITY_E2E_DIR=/fixtures SAIITY_E2E_SMOKE=1 swift test -c release \
///     -Xswiftc -enable-testing -Xswiftc -DSAIITY_TEST_HOOKS --filter E2E
@Suite("Caption end to end")
struct CaptionEndToEndTests {
    private static var enabled: Bool {
        ProcessInfo.processInfo.environment["SAIITY_E2E_SMOKE"] == "1"
    }

    private static var fixtureDir: URL? {
        ProcessInfo.processInfo.environment["SAIITY_E2E_DIR"]
            .map { URL(fileURLWithPath: $0, isDirectory: true) }
    }

    private static func samples(_ url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                                      frameCapacity: AVAudioFrameCount(file.length))!
        try file.read(into: buffer)
        let channel = buffer.floatChannelData![0]
        return Array(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
    }

    private static func buffer(_ slice: ArraySlice<Float>) -> AVAudioPCMBuffer {
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                   sampleRate: 16_000, channels: 1, interleaved: false)!
        let out = AVAudioPCMBuffer(pcmFormat: format,
                                   frameCapacity: AVAudioFrameCount(slice.count))!
        out.frameLength = AVAudioFrameCount(slice.count)
        for (i, v) in slice.enumerated() { out.floatChannelData![0][i] = v }
        return out
    }

    /// Recognise, then turn the finals into the segments a session would hold —
    /// the same `TranscriptChunk` timings, not invented ones.
    private func recognise(_ samples: [Float]) async throws -> [Segment] {
        let collected = Collector()
        let backend = StreamingASRBackend(name: "e2e", engine: NemotronEngine())
        try await backend.prepare(locale: Locale(identifier: "en-US")) { _ in }
        try await backend.start { chunk in collected.add(chunk) }
        let step = 3_200
        var offset = 0
        while offset < samples.count {
            let end = min(offset + step, samples.count)
            backend.feed(Self.buffer(samples[offset..<end]))
            offset = end
        }
        await backend.flushPending()
        await backend.stop()
        return collected.segments()
    }

    private final class Collector: @unchecked Sendable {
        private let lock = NSLock()
        private var finals: [TranscriptChunk] = []
        func add(_ chunk: TranscriptChunk) {
            guard chunk.isFinal else { return }
            let text = chunk.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return }
            lock.withLock { finals.append(chunk) }
        }
        func segments() -> [Segment] {
            lock.withLock { finals.enumerated() }.map { index, chunk in
                Segment(i: index, t0: chunk.start, t1: chunk.end, text: chunk.text,
                        loc: "en", tr: nil, trLoc: nil, words: nil)
            }
        }
    }

    @Test("speech becomes readable subtitles, and a real translation",
          .enabled(if: enabled), .timeLimit(.minutes(20)))
    func speechToSubtitles() async throws {
        let dir = try #require(Self.fixtureDir, "SAIITY_E2E_DIR is not set")
        let wav = dir.appendingPathComponent("en.wav")
        try #require(FileManager.default.fileExists(atPath: wav.path),
                     "missing \(wav.path)")
        try #require(NemotronEngine.isDownloaded(chunkMs: NemotronEngine.chunkMs),
                     "the Nemotron tier is not installed")

        let recognised = try await recognise(try Self.samples(wav))
        let text = CaptionTextMerger.join(recognised.map(\.text))
        if ProcessInfo.processInfo.environment["SAIITY_BENCHMARK_INCLUDE_TEXT"] == "1" { print("E2E recognised: \(text)") }
        #expect(!text.isEmpty, "the recogniser produced nothing")

        // The real translation, on the real wording. `prepare` is also what
        // checks the weights are present, so reaching a translation at all is
        // the download check.
        let translator = HyMT2Translator()
        try #require(HyMT2Translator.isDownloaded,
                     "installed Hy-MT2 weights required; downloads disabled")
        try await translator.prepare(from: "en", to: "de") { _ in }
        let translated = try await translator.translate(text, from: "en", to: "de")
        await translator.stop()
        if ProcessInfo.processInfo.environment["SAIITY_BENCHMARK_INCLUDE_TEXT"] == "1" { print("E2E translated: \(translated ?? "<nil>")") }
        let value = try #require(translated, "the translator declined its own caption line")
        #expect(value.caseInsensitiveCompare(text) != .orderedSame,
                "the model echoed the English back")
        #expect(TranslationLanguage.baseCode(
            LanguageDetector.languageCode(in: value) ?? "") == "de",
            "expected German, got: \(value)")

        // And the real subtitle file, with the real readability floor.
        let bilingual = recognised.enumerated().map { index, segment in
            var s = segment
            s.tr = index == recognised.count - 1 ? value : nil
            s.trLoc = s.tr == nil ? nil : "de"
            return s
        }
        let srt = Export.srt(bilingual)
        if ProcessInfo.processInfo.environment["SAIITY_BENCHMARK_INCLUDE_TEXT"] == "1" { print("E2E srt:\n\(srt)") }
        #expect(srt.contains("-->"), "no cue was written")
    }
}
