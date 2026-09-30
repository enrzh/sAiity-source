import AVFoundation
import Foundation
import Qwen3ASR
import Testing

@testable import sAiity

/// Is Qwen3-ASR worth building a streaming adapter for?
///
/// ## Why this is a probe and not an engine
///
/// The Whisper adapter was written before it was measured, and the measurement
/// then showed the number that mattered — 3.6–4.6 real-time factor — was mostly
/// the adapter's own re-decode multiplier rather than the model. Building first
/// and measuring second cost a 626 MB download and a day. This one measures
/// first, on the same fixtures and the same WER scorer as everything else, and
/// the answer decides whether any adapter gets written at all.
///
/// ## What it is actually testing
///
/// Not "is this model accurate" — the published numbers already say it is, and
/// accuracy was never the binding constraint. It is testing the one property
/// that decides whether the caption pipeline can use it at all:
///
/// **Is the streaming output append-only?** `CaptionTranscriptReconciler`
/// accepts a cumulative revision only while it extends what it has already
/// committed, and drops the rest of the session otherwise. Whisper failed here:
/// a comma became a period between passes, and everything after it was silently
/// discarded. `StreamingASR` claims append-only segments with a guaranteed
/// final on long monologues via `maxSegmentDuration` force-split. That claim is
/// what this checks, along with the throughput and the WER, in one run.
///
/// ## Running it
///
/// Needs the model fetched from Hugging Face (roughly 700 MB) plus a VAD model,
/// so it is opt-in and separate from the gated end-to-end suite:
///
///   SAIITY_QWEN_PROBE_DIR=/fixtures SAIITY_QWEN_PROBE=1 swift test -c release \
///     -Xswiftc -enable-testing -Xswiftc -DSAIITY_TEST_HOOKS --no-parallel \
///     --filter Qwen3ASRProbeTests
///
/// ## Partials
///
/// `emitPartialResults` defaults to off, which is why the first test sees none.
/// `transcribeStream` already walks the buffer in 32 ms VAD chunks. Calling it
/// again on a growing prefix would reset that VAD and re-decode from the start —
/// the Whisper cost — so the second test does not. It turns partials on at the
/// library's one-second interval and hands the cumulative text to
/// `CaptionTranscriptReconciler` on the audio clock.
///
/// Measured on the three fixtures: finals stay at WER 0 and real-time factor
/// stays under 0.5, but the first partial of each file ends in a period that is
/// not the real sentence end. The reconciler commits that fragment and drops
/// the correction ("Release machen.", "have to.", "versión oída."). Partials
/// do not belong on the cumulative caption path.
@Suite("Qwen3-ASR probe")
struct Qwen3ASRProbeTests {
    private static var enabled: Bool {
        ProcessInfo.processInfo.environment["SAIITY_QWEN_PROBE"] == "1"
    }

    private static var fixtureDir: URL? {
        ProcessInfo.processInfo.environment["SAIITY_QWEN_PROBE_DIR"]
            .map { URL(fileURLWithPath: $0, isDirectory: true) }
    }

    private static func samples(_ url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        let buffer = try #require(AVAudioPCMBuffer(
            pcmFormat: file.processingFormat,
            frameCapacity: AVAudioFrameCount(file.length)))
        try file.read(into: buffer)
        let channel = try #require(buffer.floatChannelData)
        return Array(UnsafeBufferPointer(start: channel[0], count: Int(buffer.frameLength)))
    }

    @Test("Qwen3-ASR: WER, throughput, and whether streaming output appends",
          .enabled(if: Qwen3ASRProbeTests.enabled), .timeLimit(.minutes(40)))
    func probe() async throws {
        let dir = try #require(Qwen3ASRProbeTests.fixtureDir, "SAIITY_QWEN_PROBE_DIR is not set")
        let manifest = try DictationBenchmarkManifest.load(from: dir)
        let urls = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension.lowercased() == "wav" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        try #require(!urls.isEmpty, "no WAV fixtures in \(dir.path)")

        let modelId = ProcessInfo.processInfo.environment["SAIITY_QWEN_PROBE_MODEL"]
            ?? "aufklarer/Qwen3-ASR-0.6B-MLX-4bit"
        print("PROBE model: \(modelId)")

        let loadStart = ContinuousClock.now
        let streaming = try await StreamingASR.fromPretrained(
            asrModelId: modelId,
            progressHandler: { fraction, note in
                if fraction > 0.98 || fraction == 0 {
                    print("PROBE load \(String(format: "%.2f", fraction)) \(note)")
                }
            })
        let loadSeconds = Self.seconds(loadStart.duration(to: .now))
        print(String(format: "PROBE cold load: %.1f s", loadSeconds))

        for url in urls {
            let audio = try Self.samples(url)
            let audioSeconds = Double(audio.count) / 16_000

            let started = ContinuousClock.now
            var segments: [TranscriptionSegment] = []
            var lastFinalIndex = -1
            var appendOnly = true
            var sawPartial = false
            for try await segment in streaming.transcribeStream(audio: audio) {
                segments.append(segment)
                if segment.isFinal {
                    // A final that reuses or rewinds an earlier index is the
                    // exact failure mode that silences the reconciler.
                    if segment.segmentIndex < lastFinalIndex { appendOnly = false }
                    lastFinalIndex = segment.segmentIndex
                } else {
                    sawPartial = true
                }
            }
            let elapsed = Self.seconds(started.duration(to: .now))
            let rtf = elapsed / max(audioSeconds, 0.001)

            let finals = segments.filter(\.isFinal)
            let text = finals.map(\.text).joined(separator: " ")
            print("PROBE --- \(url.lastPathComponent)")
            print(String(format: "PROBE     audio=%.2fs elapsed=%.2fs rtf=%.3f (%.1fx realtime)",
                         audioSeconds, elapsed, rtf, audioSeconds / max(elapsed, 0.001)))
            print("PROBE     segments=\(segments.count) finals=\(finals.count) partials=\(sawPartial) appendOnly=\(appendOnly)")
            print("PROBE     text: \(text)")
            if let expected = manifest[url.lastPathComponent]?.expectedText {
                let wer = DictationBenchmarkScorer.wordErrorRate(reference: expected, hypothesis: text)
                print(String(format: "PROBE     WER=%.3f", wer))
            }
            // The thing this probe exists for.
            #expect(!finals.isEmpty, "no final segment for \(url.lastPathComponent) — cannot commit anything")
            #expect(appendOnly,
                    "\(url.lastPathComponent): final segment indices went backwards, so the reconciler would drop the rest of the session")
        }
    }

    /// Partials re-decode the active utterance every second. Finals stay exact.
    /// The partials do not: an early period gets committed and the correction is
    /// dropped. `transcribeStream` runs the whole buffer before the caller sees
    /// a segment, so a wall-clock on the first yielded partial is the whole pass
    /// and is not a live latency.
    @Test("Qwen3-ASR partials: cost, and whether they still extend the committed text",
          .enabled(if: Qwen3ASRProbeTests.enabled), .timeLimit(.minutes(40)))
    func partialProbe() async throws {
        let dir = try #require(Qwen3ASRProbeTests.fixtureDir, "SAIITY_QWEN_PROBE_DIR is not set")
        let manifest = try DictationBenchmarkManifest.load(from: dir)
        let urls = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension.lowercased() == "wav" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        try #require(!urls.isEmpty, "no WAV fixtures in \(dir.path)")

        let modelId = ProcessInfo.processInfo.environment["SAIITY_QWEN_PROBE_MODEL"]
            ?? "aufklarer/Qwen3-ASR-0.6B-MLX-4bit"
        print("PARTIAL model: \(modelId) interval=1s")
        let streaming = try await StreamingASR.fromPretrained(asrModelId: modelId) { fraction, note in
            if fraction > 0.98 || fraction == 0 {
                print("PARTIAL load \(String(format: "%.2f", fraction)) \(note)")
            }
        }
        let config = StreamingASRConfig(emitPartialResults: true)

        var worstRTF = 0.0
        var totalRewrites = 0
        var totalRejections = 0

        for url in urls {
            let audio = try Self.samples(url)
            let audioSeconds = Double(audio.count) / 16_000
            let started = ContinuousClock.now
            var segments: [TranscriptionSegment] = []
            for try await segment in streaming.transcribeStream(audio: audio, config: config) {
                segments.append(segment)
            }
            let elapsed = Self.seconds(started.duration(to: .now))
            let rtf = elapsed / max(audioSeconds, 0.001)
            worstRTF = max(worstRTF, rtf)

            let finals = segments.filter(\.isFinal)
            let partials = segments.filter { !$0.isFinal }
            var lastFinalIndex = -1
            var appendOnly = true
            var partialRewrites = 0
            var lastPartial: [Int: String] = [:]
            var committedFinals = ""
            var reconciler = CaptionTranscriptReconciler()
            let origin = Date()
            var rejections = 0

            for segment in segments {
                if segment.isFinal {
                    if segment.segmentIndex < lastFinalIndex { appendOnly = false }
                    lastFinalIndex = segment.segmentIndex
                    committedFinals = committedFinals.isEmpty
                        ? segment.text
                        : committedFinals + " " + segment.text
                } else if let previous = lastPartial[segment.segmentIndex] {
                    if !segment.text.hasPrefix(previous) { partialRewrites += 1 }
                }
                if !segment.isFinal { lastPartial[segment.segmentIndex] = segment.text }

                let cumulative = segment.isFinal
                    ? committedFinals
                    : (committedFinals.isEmpty ? segment.text : committedFinals + " " + segment.text)
                let committedBefore = reconciler.committedText
                if !committedBefore.isEmpty, !cumulative.hasPrefix(committedBefore) {
                    rejections += 1
                }
                _ = reconciler.update(
                    cumulativeText: cumulative,
                    now: origin.addingTimeInterval(TimeInterval(segment.endTime)))
            }
            _ = reconciler.flush(cumulativeText: committedFinals)
            let kept = reconciler.committedText.trimmingCharacters(in: .whitespacesAndNewlines)
            let text = finals.map(\.text).joined(separator: " ")
            totalRewrites += partialRewrites
            totalRejections += rejections

            print("PARTIAL --- \(url.lastPathComponent)")
            print(String(format: "PARTIAL     audio=%.2fs elapsed=%.2fs rtf=%.3f", audioSeconds, elapsed, rtf))
            print("PARTIAL     partials=\(partials.count) finals=\(finals.count) rewrites=\(partialRewrites) reconcilerRejections=\(rejections)")
            print("PARTIAL     kept: \(kept)")
            print("PARTIAL     text: \(text)")
            if let expected = manifest[url.lastPathComponent]?.expectedText {
                let wer = DictationBenchmarkScorer.wordErrorRate(reference: expected, hypothesis: text)
                print(String(format: "PARTIAL     WER=%.3f", wer))
            }
            for segment in partials {
                print(String(format: "PARTIAL     t=%.2f-%.2f idx=%d ",
                             segment.startTime, segment.endTime, segment.segmentIndex) + segment.text)
            }
            #expect(!finals.isEmpty, "no final segment for \(url.lastPathComponent)")
            #expect(appendOnly)
            // The period on the first partial is not the sentence end. Committing
            // it drops the rest of the recording. If this starts passing, partials
            // have become prefix-stable and the decision belongs back on the table.
            #expect(kept != text,
                    "\(url.lastPathComponent): partials extended the committed text; look again before feeding them to the reconciler")
        }
        print(String(format: "PARTIAL verdict worstRTF=%.3f rewrites=%d reconcilerRejections=%d",
                     worstRTF, totalRewrites, totalRejections))
    }

    private static func seconds(_ duration: Duration) -> Double {
        let c = duration.components
        return Double(c.seconds) + Double(c.attoseconds) / 1_000_000_000_000_000_000
    }
}
