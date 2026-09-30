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

    private static func seconds(_ duration: Duration) -> Double {
        let c = duration.components
        return Double(c.seconds) + Double(c.attoseconds) / 1_000_000_000_000_000_000
    }
}
