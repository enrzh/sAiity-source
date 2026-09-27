import AVFoundation
import FluidAudio
import Foundation

/// The narrow surface sAiity needs from a FluidAudio cache-aware streaming
/// recogniser. Everything above this — buffering, committing, teardown order —
/// is shared, because getting any of it wrong is a crash or a corrupt
/// transcript rather than a cosmetic bug.
protocol FluidStreamingEngine: AnyObject, Sendable {
    var sampleRate: Double { get }
    func load(progress: @escaping @Sendable (String) -> Void) async throws
    func reset() async
    /// The engine's running transcript. Cumulative for the whole session on
    /// both engines, not a delta.
    func setPartial(_ callback: @escaping @Sendable (String) -> Void) async
    func process(_ samples: [Float]) async throws
    /// Flush the tail and return the complete session transcript.
    func finishSession() async -> String?
    func teardown() async
    /// Language identified from audio, when the engine can do that at all.
    func detectedLanguage() async -> String?
}

extension FluidStreamingEngine {
    func detectedLanguage() async -> String? { nil }
}

struct StreamingASRMetrics: Sendable {
    let realTimeFactor: Double
    let peakBacklogSeconds: Double
    let droppedAudioSeconds: Double
    let processedAudioSamples: Int
    let processedBatchCount: Int
    let overloadEvents: Int
    let processingErrorCount: Int
}

/// Drives a `FluidStreamingEngine` for the caption pipeline.
///
/// This class exists for one reason, and it is not tidiness:
///
/// **Exactly one `process()` may be in flight, ever.** FluidAudio's managers
/// `await` inside their own drain loops, and Swift actors are re-entrant across
/// await points. We get roughly 50 audio callbacks a second; letting two calls
/// overlap lets the second run the buffer compaction — `removeFirst(offset);
/// offset = 0` — while the first is suspended. The first then resumes with a
/// stale offset and eventually removes more items than the array holds, which
/// traps. That was a real, reproduced crash, not a theoretical one.
///
/// Parakeet EOU has the same shape (`prefix` → `await` → `removeFirst`); it
/// does not trap, because a `min()` saves it — it silently decodes the same
/// audio twice and drops twice as much instead. Which is worse.
///
/// It crashed again in the field on 2026-08-05, from the other direction: this
/// type *documented* the invariant without enforcing it. `start()` assigned over
/// `pump` without reclaiming the previous one, and an unreferenced `Task` keeps
/// running — so a second `start()` (an engine switch racing a stop) left two
/// pumps driving one actor. `stopPump()` now makes that structurally impossible,
/// and `pump` is under its own lock so two callers cannot both think they own it.
///
/// What is enforced here: at most one pump exists, and it has fully left the
/// engine before `stop()` calls `finishSession()`. What is *not* enforced here:
/// a caller invoking `start()` and `stop()` concurrently on the same instance
/// would still overlap a new pump with the teardown. AppDelegate prevents that
/// with its session state machine and a single-flight restart chain; if this
/// type ever gains another caller, that has to be enforced rather than assumed.
final class StreamingASRBackend: TranscriptionBackend, DictationSegmentTranscriber, @unchecked Sendable {
    let name: String
    private let engine: any FluidStreamingEngine

    private var format: AVAudioFormat?
    private var emit: (@Sendable (TranscriptChunk) -> Void)?
    private var sessionStarted = false

    private let commitLock = NSLock()
    private var reconciler = CaptionTranscriptReconciler()

    /// Where to break an unpunctuated run, or nil to keep waiting.
    ///
    /// Always cuts at a space: splitting mid-word gives the translator a
    /// fragment that is not a word in any language, and it will happily invent
    /// something from it.
    static func rollingCommitPoint(_ text: String, since: Date) -> String.Index? {
        CaptionTranscriptReconciler.rollingCommitPoint(text, since: since)
    }

    /// Session clock for subtitle timings. The engine's callback carries no
    /// timestamps (those came from Apple's engine, which is gone), so without
    /// this every SRT cue read 00:00:00 — ordered, and useless as subtitles.
    /// Commit time is within one chunk (~2.2 s) of when the words were spoken,
    /// which is accurate enough for a subtitle file.
    private var sessionStart = Date()
    private var lastFinalEnd: Double = 0
    private var audioClockEndSamples = 0
    /// Guards the cue-timing read-modify-write in `stampedFinal`, which is
    /// reached from both the engine's callback thread and the caller's.
    private let timingLock = NSLock()

    /// A final chunk stamped from the processed-audio clock.
    ///
    /// The start is the LATER of "where the previous final ended" and "now minus
    /// roughly how long this text takes to say". Without the second bound, the
    /// first cue after any quiet stretch — including the model-loading minute at
    /// session start — claimed the whole gap and showed on screen for it. The
    /// old wall-clock estimate also drifted when the model backlog changed.
    /// ~14 chars/second is unhurried speech; err long rather than short, since a
    /// subtitle that lingers reads better than one that flashes.
    ///
    /// `timingLock` is not optional here. This runs on two different threads:
    /// the engine's own partial-callback thread (see the `setPartial` closure)
    /// and the caller of `flushPending` / `transcribeDictation`. Reading
    /// `lastFinalEnd` and writing the new end must be one step, or two finals
    /// landing close together can both read the same previous end and emit
    /// overlapping cues.
    private func stampedFinal(_ text: String) -> TranscriptChunk {
        let range = timingLock.withLock { () -> (start: Double, end: Double) in
            let wallNow = Date().timeIntervalSince(sessionStart)
            let audioNow = pendingLock.withLock {
                Double(audioClockEndSamples) / max(engine.sampleRate, 1)
            }
            let now = audioNow > 0 ? audioNow : wallNow
            let range = CaptionTiming.range(for: text,
                                            audioEnd: now,
                                            previousEnd: lastFinalEnd)
            lastFinalEnd = range.end
            return range
        }
        return TranscriptChunk(text: text, isFinal: true,
                               start: range.start, end: range.end)
    }

    private let pendingLock = NSLock()
    private var pending = FloatRingBuffer()
    /// Reused by the pump so handing a batch to the engine does not trigger a
    /// copy-on-write copy when `pending` is cleared.
    private var processing: [Float] = []
    private var processedAudioSamples = 0
    private var processingWallSeconds = 0.0
    private var processedBatchCount = 0
    private var peakPendingSamples = 0
    private var droppedPendingSamples = 0
    private var overloadEvents = 0
    private var processingErrorCount = 0
    private var acceptingAudio = true
    /// True while the backlog is over its cap, so the log records the onset
    /// rather than one line per audio callback, fifty times a second.
    private var overflowing = false
    private let onPerformance: (@Sendable (Double, Double) -> Void)?
    private let onMetrics: (@Sendable (StreamingASRMetrics) -> Void)?
    private let onBackpressure: (@Sendable (Double) -> Void)?

    /// How much un-processed audio may pile up before the oldest is dropped.
    ///
    /// Capture never stops — not even in digital silence — so `feed` runs at
    /// roughly 64 KB/s for the life of the stream, and nothing about the pump
    /// falling behind is self-correcting: a batch that takes longer than the
    /// audio it contains makes the next batch bigger, which takes longer still.
    /// Unbounded, that is about 230 MB an hour, and a backend that has been
    /// stopped and replaced drains at zero.
    ///
    /// Ten seconds is far more slack than a healthy pump ever uses (it drains
    /// every 80 ms). Reaching this cap means recognition is not keeping up, and
    /// at that point stale audio is worthless — captions are supposed to track
    /// what is being said now. Dropping the oldest is strictly better than
    /// taking the machine down.
    private static let maxPendingSeconds: Double = 10
    private var maxPendingSamples: Int { Int(engine.sampleRate * Self.maxPendingSeconds) }

    /// Guards `pump` itself. Overwriting the property is not the same as
    /// stopping the task, and two callers must not both believe they own it.
    private let pumpLock = NSLock()
    private var pump: Task<Void, Never>?
    private var wakeContinuation: AsyncStream<Void>.Continuation?
    /// Waiters in `drain(toAudioSample:)`, keyed on the sample count they are
    /// waiting for. The pump resumes exactly the ones its progress has satisfied.
    private var pendingDrainContinuations: [Int: AsyncStream<Void>.Continuation] = [:]

    #if SAIITY_TEST_HOOKS
    /// Test-only view of the backlog. The cap is the whole point of `feed`, and
    /// an unbounded queue is invisible from the outside until the machine runs
    /// out of memory — which is exactly how it was found.
    var pendingSampleCountForTests: Int { pendingLock.withLock { pending.count } }
    #endif

    /// Cancel the running pump and wait for it to actually leave the engine.
    ///
    /// `cancel()` alone does NOT interrupt an in-flight `await engine.process()`
    /// — returning while that call is still suspended is precisely what lets a
    /// second pump, or a `finish()`, re-enter the actor and corrupt its buffer
    /// offset.
    private func stopPump(drainPending: Bool = false) async {
        let (p, wake) = pumpLock.withLock { () -> (Task<Void, Never>?, AsyncStream<Void>.Continuation?) in
            let p = pump
            pump = nil
            let wake = wakeContinuation
            wakeContinuation = nil
            return (p, wake)
        }
        if drainPending {
            pendingLock.withLock { acceptingAudio = false }
            // The pump consumes the bounded tail before observing the closed
            // input gate. Do not cancel it: cancellation would discard the
            // final 80–640 ms batch before the engine sees it.
            wake?.yield(())
            await p?.value
            wake?.finish()
        } else {
            pendingLock.withLock { acceptingAudio = false }
            wake?.finish()
            p?.cancel()
            await p?.value
        }
    }

    private func stopPumpAndClearPending() async {
        await stopPump(drainPending: true)
        logAndResetPerformance()
        // Not `keepingCapacity`: a stopped session should not retain its
        // high-water audio allocation while the loaded model remains cached.
        pendingLock.withLock {
            pending.removeAll(keepingCapacity: false)
            processing = []
            overflowing = false
            acceptingAudio = false
            // A drain waiter whose pump has just stopped will never be resumed
            // by progress. Finish it rather than leaving it suspended.
            let waiters = pendingDrainContinuations
            pendingDrainContinuations.removeAll()
            for (_, continuation) in waiters { continuation.finish() }
        }
    }

    init(name: String,
         engine: any FluidStreamingEngine,
         onPerformance: (@Sendable (Double, Double) -> Void)? = nil,
         onMetrics: (@Sendable (StreamingASRMetrics) -> Void)? = nil,
         onBackpressure: (@Sendable (Double) -> Void)? = nil) {
        self.name = name
        self.engine = engine
        self.onPerformance = onPerformance
        self.onMetrics = onMetrics
        self.onBackpressure = onBackpressure
    }

    var inputFormat: AVAudioFormat? {
        get async { format }
    }

    func prepare(locale: Locale, progress: @escaping @Sendable (String) -> Void) async throws {
        try await engine.load(progress: progress)
        format = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                               sampleRate: engine.sampleRate, channels: 1, interleaved: false)
    }

    func start(onChunk: @escaping @Sendable (TranscriptChunk) -> Void) async throws {
        // Reclaim a pump left over from an earlier start before creating
        // another. Assigning over the property was not enough: an unreferenced
        // Task keeps running, so a second start — an engine switch racing a
        // stop, say — left two pumps calling process() on one actor. That is
        // exactly the overlap this type exists to prevent, and it is how the
        // buffer-offset trap documented above was reached in the field.
        await stopPump()
        logAndResetPerformance()
        // Reset the streaming state while retaining the loaded weights. This
        // covers both the first start and a start after an interrupted session.
        await engine.reset()
        emit = onChunk
        commitLock.withLock { reconciler.reset(now: Date()) }
        // Same lock as the read-modify-write in `stampedFinal`: a callback from
        // a previous session can still be in flight when a new one starts.
        timingLock.withLock {
            sessionStart = Date()
            lastFinalEnd = 0
        }
        pendingLock.withLock {
            pending.removeAll(keepingCapacity: true)
            processing.removeAll(keepingCapacity: true)
            processedAudioSamples = 0
            processingWallSeconds = 0
            processedBatchCount = 0
            peakPendingSamples = 0
            droppedPendingSamples = 0
            overloadEvents = 0
            processingErrorCount = 0
            audioClockEndSamples = 0
            acceptingAudio = true
        }

        await engine.setPartial { [weak self] text in
            guard let self else { return }
            let output = self.commitLock.withLock {
                self.reconciler.update(cumulativeText: text)
            }
            if let finalText = output.finalText {
                onChunk(self.stampedFinal(finalText))
            }
            if let volatileText = output.volatileText {
                onChunk(TranscriptChunk(text: volatileText, isFinal: false))
            }
        }

        // The single pump. See the type doc for why this is a correctness
        // requirement rather than an optimisation. Audio arrival wakes the
        // pump immediately; the old fixed sleep added up to 80 ms before every
        // otherwise-idle stream could begin processing.
        let wakeStream = AsyncStream<Void>(bufferingPolicy: .bufferingNewest(1)) { continuation in
            pumpLock.withLock { wakeContinuation = continuation }
        }
        pumpLock.withLock {
            pump = Task { [weak self] in
                for await _ in wakeStream {
                    guard let self else { return }
                    while !Task.isCancelled {
                        let hasBatch = self.pendingLock.withLock { () -> Bool in
                            guard !self.pending.isEmpty else { return false }
                            self.pending.drain(upTo: self.processingBatchSamples(
                                pendingSamples: self.pending.count),
                                               into: &self.processing)
                            return !self.processing.isEmpty
                        }
                        guard hasBatch else {
                            if self.pendingLock.withLock({ !self.acceptingAudio }) { return }
                            break
                        }
                        let batchSamples = self.processing.count
                        self.pendingLock.withLock {
                            self.audioClockEndSamples = self.processedAudioSamples + batchSamples
                        }
                        let started = ContinuousClock.now
                        do {
                            try await self.engine.process(self.processing)
                        } catch is CancellationError {
                            self.pendingLock.withLock {
                                self.processing.removeAll(keepingCapacity: true)
                            }
                            return
                        } catch {
                            NSLog("sAiity ASR processing failed for \(self.name): \(error.localizedDescription)")
                            self.pendingLock.withLock {
                                self.processingErrorCount += 1
                                self.processing.removeAll(keepingCapacity: true)
                            }
                            return
                        }
                        let elapsed = started.duration(to: .now).components
                        let wallSeconds = Double(elapsed.seconds)
                            + Double(elapsed.attoseconds) / 1_000_000_000_000_000_000
                        self.pendingLock.withLock {
                            self.processedAudioSamples += batchSamples
                            self.processingWallSeconds += wallSeconds
                            self.processedBatchCount += 1
                            self.processing.removeAll(keepingCapacity: true)
                        }
                        // A drain waiter is woken by the pump's own progress, not
                        // by a timer. Resumed outside the lock: finishing a
                        // continuation can run arbitrary code.
                        self.resumeSatisfiedDrains()
                    }
                }
            }
        }
        sessionStarted = true
    }

    /// Finish every `drain(toAudioSample:)` waiter whose target this batch
    /// reached. Called once per processed batch, so the common case — nobody
    /// waiting — is a single locked read of an empty dictionary.
    private func resumeSatisfiedDrains() {
        let processed = pendingLock.withLock {
            processedAudioSamples + droppedPendingSamples
        }
        let ready = pendingLock.withLock {
            pendingDrainContinuations.filter { $0.key <= processed }
        }
        guard !ready.isEmpty else { return }
        for (target, continuation) in ready {
            _ = pendingLock.withLock { pendingDrainContinuations.removeValue(forKey: target) }
            continuation.finish()
        }
    }

    /// Cheap and non-blocking: copy the samples out and return. The pump owns
    /// all contact with the engine.
    func feed(_ buffer: AVAudioPCMBuffer) {
        guard let ch = buffer.floatChannelData else { return }
        let n = Int(buffer.frameLength)
        guard n > 0 else { return }
        let src = UnsafeBufferPointer(start: ch[0], count: n)
        let cap = maxPendingSamples
        var backpressureSeconds: Double?
        pendingLock.withLock {
            guard acceptingAudio else { return }
            pending.append(src)
            peakPendingSamples = max(peakPendingSamples, pending.count)
            // See maxPendingSeconds. `count > cap` is what makes the removal
            // count strictly smaller than the array — the unclamped version of
            // this arithmetic is what traps inside FluidAudio.
            guard pending.count > cap else {
                overflowing = false
                return
            }
            let dropped = pending.count - cap
            pending.dropFirst(dropped)
            droppedPendingSamples += dropped
            if !overflowing {
                overflowing = true
                overloadEvents += 1
                backpressureSeconds = Double(pending.count) / engine.sampleRate
                NSLog("sAiity asr: \(name) backlog over \(Int(Self.maxPendingSeconds))s — dropping oldest audio")
            }
        }
        if let backpressureSeconds { onBackpressure?(backpressureSeconds) }
        let wake = pumpLock.withLock { wakeContinuation }
        wake?.yield(())
    }

    /// Larger batches amortise model overhead when the pump is behind, while
    /// the normal path stays at 160 ms for responsive captions.
    static func processingBatchSeconds(forPendingSeconds seconds: Double) -> Double {
        switch seconds {
        case ..<0.75: return 0.16
        case ..<2.5: return 0.32
        default: return 0.64
        }
    }

    private func processingBatchSamples(pendingSamples: Int) -> Int {
        let seconds = Double(pendingSamples) / max(engine.sampleRate, 1)
        return max(1, Int(engine.sampleRate * Self.processingBatchSeconds(
            forPendingSeconds: seconds)))
    }

    private func logAndResetPerformance() {
        let metrics = pendingLock.withLock { () -> (Int, Double, Int, Int, Int, Int, Int) in
            defer {
                processedAudioSamples = 0
                processingWallSeconds = 0
                processedBatchCount = 0
                peakPendingSamples = 0
                droppedPendingSamples = 0
                overloadEvents = 0
                processingErrorCount = 0
            }
            return (processedAudioSamples, processingWallSeconds,
                    processedBatchCount, peakPendingSamples, droppedPendingSamples,
                    overloadEvents, processingErrorCount)
        }
        guard metrics.2 > 0 || metrics.4 > 0 || metrics.6 > 0 else { return }
        let audioSeconds = Double(metrics.0) / engine.sampleRate
        let realTimeFactor = metrics.1 / max(audioSeconds, 0.001)
        let peakBacklogSeconds = Double(metrics.3) / engine.sampleRate
        let droppedAudioSeconds = Double(metrics.4) / engine.sampleRate
        onPerformance?(realTimeFactor, peakBacklogSeconds)
        onMetrics?(StreamingASRMetrics(realTimeFactor: realTimeFactor,
                                       peakBacklogSeconds: peakBacklogSeconds,
                                       droppedAudioSeconds: droppedAudioSeconds,
                                       processedAudioSamples: metrics.0,
                                       processedBatchCount: metrics.2,
                                       overloadEvents: metrics.5,
                                       processingErrorCount: metrics.6))
        NSLog("sAiity caption timing: backend=%@ audio=%.3fs compute=%.3fs rtf=%.3f batches=%d peak-backlog=%.3fs dropped=%.3fs errors=%d",
              name, audioSeconds, metrics.1, realTimeFactor, metrics.2,
              peakBacklogSeconds, droppedAudioSeconds, metrics.6)
    }

    /// Audio went silent: whatever is still volatile is a finished utterance.
    /// Without this, speech that never gets sentence punctuation from the engine
    /// stays volatile forever and never reaches the transcript or the translator.
    func flushPending() async {
        // Scoped `withLock` rather than lock/unlock: the manual pair is
        // unavailable from an async context and becomes a hard error under the
        // Swift 6 language mode. Scoping it also makes it impossible to acquire
        // the lock and then suspend while holding it.
        let output = commitLock.withLock { reconciler.flush() }
        if let text = output.finalText { emit?(stampedFinal(text)) }
    }

    /// Capture and ASR use different sample rates. AppDelegate converts the
    /// capture watermark before calling this method; waiting here keeps the
    /// engine's single processing pump as the only owner of recogniser state.
    ///
    /// The pump is wake-driven, and so is this wait: registering a continuation
    /// keyed on the target sample count means the caller sleeps until the pump
    /// reports progress, rather than waking a hundred times a second to ask.
    func drain(toAudioSample sample: Int) async {
        let target = max(0, sample)
        if pendingLock.withLock({ processedAudioSamples + droppedPendingSamples >= target }) {
            return
        }
        let wake = AsyncStream<Void>(bufferingPolicy: .bufferingNewest(1)) { continuation in
            pendingLock.withLock {
                // Re-check under the lock: the pump may have advanced between
                // the check above and now, and registering a continuation the
                // pump has already passed would wait forever.
                if processedAudioSamples + droppedPendingSamples >= target {
                    continuation.finish()
                    return
                }
                pendingDrainContinuations[target] = continuation
            }
        }
        for await _ in wake {
            if pendingLock.withLock({ processedAudioSamples + droppedPendingSamples >= target }) {
                return
            }
        }
    }

    /// Deferred, authoritative dictation path. The live caption pump never
    /// enters this method: each region gets a fresh decoder state while the
    /// already-loaded engine and model weights remain resident.
    func transcribeDictation(samples: [Float],
                             regions: [DictationSpeechRegion]) async throws -> DictationTranscriptionResult {
        await stopPumpAndClearPending()
        sessionStarted = false
        emit = nil
        await engine.setPartial { _ in }

        var transcripts: [DictationRegionTranscript] = []
        do {
            for region in regions {
                try Task.checkCancellation()
                await engine.reset()
                let audio = Array(samples[region.audioRange])
                guard !audio.isEmpty else { continue }
                try await engine.process(audio)
                let text = await engine.finishSession()?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let language = await engine.detectedLanguage()
                if !text.isEmpty {
                    transcripts.append(DictationRegionTranscript(text: text, language: language))
                }
                // Keep the reset explicit even though finish() currently clears
                // the manager. This is the invariant that protects the next
                // region if the engine implementation changes.
                await engine.reset()
            }
        } catch {
            await engine.reset()
            throw error
        }
        return DictationTranscriptionResult(regions: transcripts)
    }

    /// Finish a short dictation utterance without sending the authoritative
    /// completion through the caption callback.
    func finishDictation() async -> String? {
        await stopPumpAndClearPending()
        let full = sessionStarted ? await engine.finishSession() : nil
        await engine.reset()
        sessionStarted = false
        emit = nil
        return full
    }

    func stop() async {
        // Waits for the pump to actually leave the engine. Calling finish()
        // while a process() is still suspended re-enters the actor and corrupts
        // its buffer offset exactly the way concurrent feeds did — verified, it
        // crashed here with the same "Can't remove more items than it has" trap.
        await stopPumpAndClearPending()

        if sessionStarted {
            // finish() returns the WHOLE session transcript; emit only what has
            // not already been committed, or the last line is duplicated.
            if let full = await engine.finishSession() {
                let output = commitLock.withLock { reconciler.flush(cumulativeText: full) }
                if let text = output.finalText { emit?(stampedFinal(text)) }
            }
        }
        await engine.reset()
        sessionStarted = false
        emit = nil
    }

    func release() async {
        await stop()
        await engine.teardown()
        format = nil
    }

    func detectedLanguage() async -> String? { await engine.detectedLanguage() }
}
