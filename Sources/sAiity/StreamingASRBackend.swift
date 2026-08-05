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
final class StreamingASRBackend: TranscriptionBackend, @unchecked Sendable {
    let name: String
    private let engine: any FluidStreamingEngine

    private var format: AVAudioFormat?
    private var emit: (@Sendable (TranscriptChunk) -> Void)?

    /// The partial callback is CUMULATIVE for the session — the whole
    /// transcript, every time, not a delta. Left alone that means nothing is
    /// ever final, so the transcript store, translation and language detection
    /// (all keyed off finals) would never fire.
    private let commitLock = NSLock()
    private var committed = ""
    /// The last cumulative text seen, so a silence flush can commit the rest.
    private var lastSeen = ""
    /// When the last final was emitted, for the rolling commit below.
    private var lastCommitAt = Date()

    /// How long an unpunctuated phrase may sit uncommitted before it is sent on
    /// anyway, and how long it must be to be worth sending.
    private static let maxVolatileSeconds: TimeInterval = 3.5
    private static let minRollingChars = 28
    /// A hard length ceiling, for speech that runs on without a pause.
    private static let maxVolatileChars = 110

    /// Where to break an unpunctuated run, or nil to keep waiting.
    ///
    /// Always cuts at a space: splitting mid-word gives the translator a
    /// fragment that is not a word in any language, and it will happily invent
    /// something from it.
    static func rollingCommitPoint(_ text: String, since: Date) -> String.Index? {
        let n = text.count
        guard n >= minRollingChars else { return nil }
        let overdue = Date().timeIntervalSince(since) >= maxVolatileSeconds
        guard overdue || n >= maxVolatileChars else { return nil }
        // Leave the last few words volatile: the engine is still most likely to
        // revise its most recent tokens, and committing them invites a visible
        // correction after the fact.
        let keepBack = text.index(text.endIndex, offsetBy: -min(12, n / 4))
        let head = text[..<keepBack]
        guard !head.isEmpty else { return nil }

        // A clause break is the best cut — it exists in both writing systems.
        if let p = head.lastIndex(where: { Self.clauseBreaks.contains($0) }) {
            return text.index(after: p)
        }
        if let space = head.lastIndex(of: " ") { return text.index(after: space) }
        // Japanese, Chinese and Thai are written without spaces. Requiring one
        // meant this never fired for them, so nothing was committed — and so
        // nothing was translated — until the speaker stopped talking entirely.
        // Those scripts break acceptably at any character.
        return keepBack
    }

    private static let clauseBreaks: Set<Character> = ["、", "，", ",", ";", "；", ":", "：", "…"]

    private let pendingLock = NSLock()
    private var pending: [Float] = []
    private var pump: Task<Void, Never>?

    init(name: String, engine: any FluidStreamingEngine) {
        self.name = name
        self.engine = engine
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
        emit = onChunk
        commitLock.withLock { committed = ""; lastSeen = ""; lastCommitAt = Date() }
        pendingLock.withLock { pending.removeAll(keepingCapacity: true) }

        await engine.setPartial { [weak self] text in
            guard let self else { return }
            self.commitLock.lock()
            // A transducer commits tokens rather than revising them, so the
            // cumulative text normally only grows. Guard the exception anyway.
            if !text.hasPrefix(self.committed) { self.committed = "" }
            self.lastSeen = text
            let pendingText = String(text.dropFirst(self.committed.count))

            // Commit whole sentences: a finished sentence is stable, translates
            // well, and is the right unit for a transcript line.
            var finalPart = ""
            // Latin punctuation needs a following space or end-of-string, so a
            // decimal point does not end a sentence. CJK full stops do not —
            // Japanese and Chinese run straight on with no space, so requiring
            // one meant a sentence boundary was NEVER found in those languages.
            if let r = pendingText.range(of: "(?:[.!?](?:\\s|$))|[。！？…]",
                                         options: [.regularExpression, .backwards]) {
                finalPart = String(pendingText[..<r.upperBound])
                self.committed += finalPart
            } else if let cut = Self.rollingCommitPoint(pendingText, since: self.lastCommitAt) {
                // Nothing translated until the audio stopped, because only
                // punctuation or silence produced a final — and the multilingual
                // Nemotron frequently emits no punctuation at all. Watching a
                // film, that meant no translation until the film did.
                //
                // So commit a phrase on its own once one has been waiting long
                // enough, at a word boundary. Slightly awkward units are the
                // price of subtitles that keep up with continuous speech.
                finalPart = String(pendingText[..<cut])
                self.committed += finalPart
            }
            if !finalPart.isEmpty { self.lastCommitAt = Date() }
            let tail = String(pendingText.dropFirst(finalPart.count))
            self.commitLock.unlock()

            let f = finalPart.trimmingCharacters(in: .whitespacesAndNewlines)
            if !f.isEmpty { onChunk(TranscriptChunk(text: f, isFinal: true)) }
            let v = tail.trimmingCharacters(in: .whitespacesAndNewlines)
            if !v.isEmpty { onChunk(TranscriptChunk(text: v, isFinal: false)) }
        }

        // The single pump. See the type doc for why this is a correctness
        // requirement rather than an optimisation.
        pump = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let batch: [Float] = self.pendingLock.withLock {
                    defer { self.pending.removeAll(keepingCapacity: true) }
                    return self.pending
                }
                guard !batch.isEmpty else {
                    try? await Task.sleep(nanoseconds: 80_000_000)
                    continue
                }
                try? await self.engine.process(batch)
            }
        }
    }

    /// Cheap and non-blocking: copy the samples out and return. The pump owns
    /// all contact with the engine.
    func feed(_ buffer: AVAudioPCMBuffer) {
        guard let ch = buffer.floatChannelData else { return }
        let n = Int(buffer.frameLength)
        guard n > 0 else { return }
        let src = UnsafeBufferPointer(start: ch[0], count: n)
        pendingLock.withLock { pending.append(contentsOf: src) }
    }

    /// Audio went silent: whatever is still volatile is a finished utterance.
    /// Without this, speech that never gets sentence punctuation from the engine
    /// stays volatile forever and never reaches the transcript or the translator.
    func flushPending() async {
        // Scoped `withLock` rather than lock/unlock: the manual pair is
        // unavailable from an async context and becomes a hard error under the
        // Swift 6 language mode. Scoping it also makes it impossible to acquire
        // the lock and then suspend while holding it.
        let rest = commitLock.withLock { () -> String in
            let r = lastSeen.hasPrefix(committed)
                ? String(lastSeen.dropFirst(committed.count)) : lastSeen
            committed = lastSeen
            lastCommitAt = Date()
            return r
        }
        let t = rest.trimmingCharacters(in: .whitespacesAndNewlines)
        if !t.isEmpty { emit?(TranscriptChunk(text: t, isFinal: true)) }
    }

    func stop() async {
        // cancel() does NOT interrupt an in-flight `await engine.process(...)`.
        // Calling finish() while that call is still suspended re-enters the
        // actor and corrupts its buffer offset exactly the way concurrent feeds
        // did — verified, it crashed here with the same "Can't remove more items
        // than it has" trap. Wait for the pump to actually leave the engine.
        pump?.cancel()
        await pump?.value
        pump = nil
        pendingLock.withLock { pending.removeAll(keepingCapacity: true) }

        // finish() returns the WHOLE session transcript; emit only what has not
        // already been committed, or the last line is duplicated.
        if let full = await engine.finishSession() {
            let rest = commitLock.withLock { () -> String in
                let r = full.hasPrefix(committed) ? String(full.dropFirst(committed.count)) : full
                committed = full
                return r
            }
            let t = rest.trimmingCharacters(in: .whitespacesAndNewlines)
            if !t.isEmpty { emit?(TranscriptChunk(text: t, isFinal: true)) }
        }
        await engine.teardown()
        emit = nil
    }

    func detectedLanguage() async -> String? { await engine.detectedLanguage() }
}
