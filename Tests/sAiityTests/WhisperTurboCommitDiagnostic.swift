import AVFoundation
import Foundation
import Testing

@testable import sAiity

/// Diagnostic for the rolling commit in `WhisperTurboEngine`.
///
/// Fed whole audio in one call, so it separates "the commit loses text" from
/// "the incremental path loses text". Needs the 626 MB weights; opt in with
/// SAIITY_WHISPER_DIAG=1 and SAIITY_WHISPER_DIAG_WAV=/path/to.wav.
@Suite("Whisper turbo commit diagnostic")
struct WhisperTurboCommitDiagnostic {
    private static var enabled: Bool {
        ProcessInfo.processInfo.environment["SAIITY_WHISPER_DIAG"] == "1"
    }

    @Test("A whole utterance in one process() call commits all of it",
          .enabled(if: enabled), .timeLimit(.minutes(10)))
    func wholeUtteranceCommits() async throws {
        let path = try #require(ProcessInfo.processInfo.environment["SAIITY_WHISPER_DIAG_WAV"])
        let url = URL(fileURLWithPath: path)
        let file = try AVAudioFile(forReading: url)
        let buffer = try #require(AVAudioPCMBuffer(
            pcmFormat: file.processingFormat,
            frameCapacity: AVAudioFrameCount(file.length)))
        try file.read(into: buffer)
        let samples = Array(UnsafeBufferPointer(start: buffer.floatChannelData![0],
                                               count: Int(buffer.frameLength)))

        let engine = WhisperTurboEngine()
        try await engine.load { note in print("diag: \(note)") }
        await engine.setPartial { text in print("diag partial: \(text)") }
        try await engine.process(samples)
        print("diag window after one pass: \(engine.debugWindowSeconds) s")
        print("diag committed: \(engine.debugCommitted)")
        let full = await engine.finishSession()
        print("diag finish: \(full ?? "<nil>")")
        await engine.teardown()
    }
}
