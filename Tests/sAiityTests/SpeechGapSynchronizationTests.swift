import AVFoundation
import Foundation
import Testing

@testable import sAiity

/// The capture queue and the settings UI both write the speech-gap state, and
/// they never stopped: `classify` runs fifty times a second on
/// ScreenCaptureKit's callback queue while `applySpeechGapSettings()` runs on
/// the main actor the moment the Pause-length slider moves. Nothing separated
/// them, so a slider drag mid-session was two threads writing one state
/// machine — a threshold read half-updated, a gap event lost, or a hold applied
/// to quiet banked under a different one.
///
/// These pin the synchronization, not the acoustics: the level fixtures and the
/// field cases live in `SpeechGapDetectorTests`.
@Suite("Speech gap synchronization")
struct SpeechGapSynchronizationTests {
    /// 20 ms buffers at 48 kHz, matching what SCStream delivers.
    private static let frames = 960
    private static let rate: Float = 48_000
    /// 750 ms — the shipped default.
    private static let holdFrames = 36_000

    /// Speech is never one level: a constant tone equals its own noise floor and
    /// would read as one long pause.
    private func speak(_ gate: SpeechGapGate, ms: Int) {
        var i = 0
        while i < ms / 100 {
            _ = gate.consume(rms: i.isMultiple(of: 2) ? 0.08 : 0.035,
                             frames: 5 * Self.frames, sampleRate: Self.rate)
            i += 1
        }
    }

    @discardableResult
    private func quiet(_ gate: SpeechGapGate, ms: Int) -> Range<Int>? {
        var fired: Range<Int>?
        for _ in 0..<(ms / 20) {
            if let gap = gate.consume(rms: 0.0095, frames: Self.frames,
                                      sampleRate: Self.rate).gap {
                fired = gap
            }
        }
        return fired
    }

    @Test("a pause that closed a sentence is reported with its sample range")
    func pauseFiresThroughTheGate() {
        let gate = SpeechGapGate(holdFrames: Self.holdFrames)
        speak(gate, ms: 2_000)
        let fired = quiet(gate, ms: 1_000)

        #expect(fired != nil, "a full stop in speech must close a sentence")
        #expect((fired?.lowerBound ?? 0) < (fired?.upperBound ?? 0))
        #expect(gate.fireCount == 1)
    }

    @Test("a setting change discards the quiet banked under the old hold")
    func applyingSettingsForgetsAccumulatedQuiet() {
        let gate = SpeechGapGate(holdFrames: Self.holdFrames)
        speak(gate, ms: 2_000)
        // 400 ms is a breath, not a stop — but it is quiet the detector has
        // already banked.
        #expect(quiet(gate, ms: 400) == nil)

        // The same hold, re-applied because the user nudged the slider. A
        // threshold change must not fire immediately on quiet accumulated under
        // the previous one, so the detector starts over.
        gate.apply(enabled: true, holdFrames: Self.holdFrames)
        #expect(quiet(gate, ms: 400) == nil,
                "the reset let banked quiet carry over into the new threshold")
        #expect(gate.fireCount == 0)

        // And it is still a working detector afterwards, not a disarmed one.
        speak(gate, ms: 1_000)
        #expect(quiet(gate, ms: 1_000) != nil)
    }

    @Test("disabling gaps stops the detector instead of pausing it")
    func disablingGapsFreezesTheDetector() {
        let gate = SpeechGapGate(holdFrames: Self.holdFrames)
        speak(gate, ms: 2_000)

        gate.apply(enabled: false, holdFrames: Self.holdFrames)
        #expect(quiet(gate, ms: 5_000) == nil, "a gap fired with the setting off")
        #expect(gate.fireCount == 0)

        // Re-enabling re-reads the detector from scratch, so the silence the
        // disabled window swallowed is not replayed as a finished sentence.
        gate.apply(enabled: true, holdFrames: Self.holdFrames)
        #expect(quiet(gate, ms: 1_000) == nil,
                "a pause it never looked at was replayed as a gap")
        speak(gate, ms: 1_000)
        #expect(quiet(gate, ms: 1_000) != nil)
    }

    @Test("a new session starts from a clean gate")
    func resetClearsTheSession() {
        let gate = SpeechGapGate(holdFrames: Self.holdFrames)
        speak(gate, ms: 2_000)
        #expect(quiet(gate, ms: 1_000) != nil)
        #expect(gate.fireCount == 1)

        gate.reset()

        #expect(gate.fireCount == 0)
        // The floor learned from the last video must not decide this one: after
        // a reset the same bed is this material's floor, so nothing is armed and
        // nothing fires.
        #expect(quiet(gate, ms: 1_000) == nil)
    }

    @Test("the diagnostics window reports a floor, a threshold and a count")
    func diagnosticsWindowIsSampledNotAccumulated() {
        let gate = SpeechGapGate(holdFrames: Self.holdFrames)
        var readings: [SpeechGapGate.Diagnostics] = []
        for _ in 0..<20 {
            let reading = gate.consume(rms: 0.0095, frames: 12_000,
                                        sampleRate: Self.rate)
            if let sample = reading.diagnostics { readings.append(sample) }
        }

        // 20 buffers × 12 000 frames = 240 000 = exactly one five-second window,
        // so the last buffer is the one that completes it — and the window does
        // not carry over into the next one.
        #expect(readings.count == 1)
        #expect(readings.first?.floor == 0.0095)
        #expect((readings.first?.threshold ?? 0) >= SpeechGapDetector.absoluteThreshold)
        #expect(readings.first?.fires == 0)
    }

    /// The race itself: two threads, one detector, run until both are done.
    ///
    /// Without a lock this is a torn read of a struct of counters from two
    /// threads — a crash under a sanitizer, and in the field a Pause-length
    /// slider that sometimes stops a session from ever closing a sentence again.
    /// What is asserted is the contract that makes it safe: the run finishes, and
    /// a known-good pause still fires exactly once afterwards.
    @Test("settings changes and capture buffers cannot race")
    func settingsChangesAndCaptureBuffersDoNotRace() {
        let gate = SpeechGapGate(holdFrames: Self.holdFrames)

        let settings = DispatchQueue(label: "test.speech-gap.settings")
        let capture = DispatchQueue(label: "test.speech-gap.capture")
        let done = DispatchGroup()

        done.enter()
        settings.async {
            for step in 0..<4_000 {
                // A slider drag: hold and enabled, applied as one transaction.
                gate.apply(enabled: !step.isMultiple(of: 5),
                           holdFrames: 14_400 + (step % 28) * 1_920)
            }
            done.leave()
        }
        done.enter()
        capture.async {
            for step in 0..<40_000 {
                let level: Float = step.isMultiple(of: 3) ? 0.05 : 0.0095
                _ = gate.consume(rms: level, frames: Self.frames, sampleRate: Self.rate)
            }
            done.leave()
        }
        done.wait()

        // The gate is still a working detector, not a scrambled one.
        let after = gate.fireCount
        gate.apply(enabled: true, holdFrames: Self.holdFrames)
        speak(gate, ms: 2_000)
        #expect(quiet(gate, ms: 1_000) != nil, "the gate stopped working after the race")
        #expect(gate.fireCount == after + 1)
    }
}

/// The same race, through the production class: `classify` on the capture queue
/// against `applySpeechGapSettings` on the main actor. ScreenCaptureKit cannot
/// be started from a unit test, so the buffers are built here and the capture
/// callback's real body is what runs.
@Suite("System audio capture gap handling")
struct SystemAudioCaptureGapTests {
    /// Speech in the alternating loud/soft pattern the detector needs. A
    /// constant level equals its own noise floor, so the onset threshold stays
    /// above it and nothing ever arms — the same trap the first fixture in
    /// `SpeechGapDetectorTests` walked into.
    private func speech(_ capture: SystemAudioCapture, ms: Int) {
        var i = 0
        while i < ms / 100 {
            capture.feed(level: i.isMultiple(of: 2) ? 0.08 : 0.035, buffers: 5)
            i += 1
        }
    }

    /// A full stop under the material's bed, long enough for the 750 ms hold.
    private func pause(_ capture: SystemAudioCapture) {
        capture.feed(level: 0.0095, buffers: 50)
    }

    @Test("a finished sentence closes a gap through the capture path")
    func capturePathFiresAGap() {
        let previous = (SpeechGap.enabled, SpeechGap.holdMs)
        defer { SpeechGap.enabled = previous.0; SpeechGap.holdMs = previous.1 }

        let capture = SystemAudioCapture()
        let gaps = GapCounter<[Range<Int>]>([])
        capture.onSpeechGap = { range in gaps.withValue { $0.append(range) } }
        SpeechGap.enabled = true
        SpeechGap.holdMs = SpeechGap.defaultHoldMs
        capture.applySpeechGapSettings()

        speech(capture, ms: 2_000)
        pause(capture)

        #expect(gaps.value.count == 1, "no gap reached the caption pipeline")
        #expect(capture.gapFireCountForTests == 1)
    }

    @Test("gaps off means no gap, and turning them back on resumes cleanly")
    func disabledGapsProduceNothing() {
        let previous = (SpeechGap.enabled, SpeechGap.holdMs)
        defer { SpeechGap.enabled = previous.0; SpeechGap.holdMs = previous.1 }

        let capture = SystemAudioCapture()
        let gaps = GapCounter<[Range<Int>]>([])
        capture.onSpeechGap = { range in gaps.withValue { $0.append(range) } }
        SpeechGap.enabled = false
        capture.applySpeechGapSettings()

        speech(capture, ms: 2_000)
        pause(capture)
        #expect(gaps.value.isEmpty, "a gap fired with the setting off")
        #expect(capture.gapFireCountForTests == 0)

        SpeechGap.enabled = true
        capture.applySpeechGapSettings()
        speech(capture, ms: 2_000)
        pause(capture)
        #expect(gaps.value.count == 1)
    }

    /// A Pause-length slider drag landing on a running session, repeatedly, from
    /// another queue than the buffers.
    @Test("a settings change during capture never corrupts the running session")
    func settingsChangesDuringCaptureAreSafe() {
        let previous = (SpeechGap.enabled, SpeechGap.holdMs)
        defer { SpeechGap.enabled = previous.0; SpeechGap.holdMs = previous.1 }
        SpeechGap.enabled = true
        SpeechGap.holdMs = SpeechGap.defaultHoldMs

        let capture = SystemAudioCapture()
        let gaps = GapCounter(0)
        capture.onSpeechGap = { _ in gaps.withValue { $0 += 1 } }
        capture.applySpeechGapSettings()

        let settings = DispatchQueue(label: "test.capture.settings")
        let buffers = DispatchQueue(label: "test.capture.buffers")
        let done = DispatchGroup()
        done.enter()
        settings.async {
            for step in 0..<2_000 {
                SpeechGap.holdMs = SpeechGap.range.lowerBound
                    + (step % SpeechGap.range.count)   // 300…2000 ms
                capture.applySpeechGapSettings()
            }
            done.leave()
        }
        done.enter()
        buffers.async {
            for step in 0..<20_000 {
                capture.classifyForTests(level: step.isMultiple(of: 4) ? 0.05 : 0.0095)
            }
            done.leave()
        }
        done.wait()

        // The session still works: a full stop after speech closes a sentence,
        // exactly once.
        SpeechGap.holdMs = SpeechGap.defaultHoldMs
        capture.applySpeechGapSettings()
        let before = gaps.value
        speech(capture, ms: 2_000)
        pause(capture)
        #expect(gaps.value == before + 1,
                "the capture path stopped reporting gaps after a concurrent settings change")
    }
}

private extension SystemAudioCapture {
    /// `buffers` × 20 ms of a constant level, through the real `classify` body.
    func feed(level: Float, buffers: Int) {
        for _ in 0..<buffers {
            classifyForTests(level: level, frames: 960)
        }
    }
}

/// A value under a lock, for the counters an `onSpeechGap` closure keeps on
/// whatever queue the capture callback happens to be on.
final class GapCounter<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: Value

    init(_ value: Value) { storage = value }

    var value: Value { lock.withLock { storage } }

    @discardableResult
    func withValue<T>(_ body: (inout Value) -> T) -> T {
        lock.withLock { body(&storage) }
    }
}
