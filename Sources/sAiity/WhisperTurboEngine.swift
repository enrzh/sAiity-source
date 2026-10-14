import AVFoundation
import Foundation
import WhisperKit

/// Whisper large-v3-turbo, exposed to the caption pipeline as a streaming
/// recogniser.
///
/// ## Why this is not Nemotron, stated plainly
///
/// Nemotron is a cache-aware FastConformer + RNN-T. It genuinely streams: each
/// chunk is encoded once with carried state, so decoding N seconds of audio
/// costs one pass over N seconds. Whisper is an encoder-decoder with a fixed
/// 30 s receptive field and no carried state, so "streaming" here means
/// re-decoding an overlapping window and keeping the text that stopped moving.
///
/// That is a real cost, and this type pays it deliberately: every pass decodes
/// the whole window again. In steady state a pass covers a few seconds of audio
/// rather than the 30 s Whisper is nominally built for, so the waste is bounded
/// — but it is not free, and it is the reason this is a non-default engine
/// rather than a replacement for Nemotron.
///
/// ## How the commit works
///
/// The window is decoded whole and comes back with word-level timings. A word
/// is settled only if it ends at least `commitHorizonSeconds` before the live
/// edge, because Whisper revises the tail of a window as more audio arrives —
/// committing at the edge would freeze text the next pass would have rewritten,
/// and the pipeline has already moved it into a caption line by then.
///
/// The callback therefore carries `committed + volatile` as one cumulative
/// string, and `CaptionTranscriptReconciler` re-splits it every pass. The
/// committed prefix only ever grows, which is what makes that safe.
///
/// A little already-committed audio is kept at the front of the window as left
/// context. It is re-decoded every pass and then discarded by timestamp, so the
/// model is never asked to start a sentence with no acoustic history, and the
/// discarded words cannot be counted twice.
///
/// ## Measured result: do not offer this as a live caption engine
///
/// This adapter is correct — fed a whole utterance in one `process()` call it
/// returns the sentence accurately, and the commit rule is unit-tested against
/// the boundary cases. The model is not the problem. Two things around it are,
///
///   - **It cannot keep up.** Measured on three fixtures against Nemotron on
///     identical audio: a real-time factor of **3.6–4.6**, meaning three to
///     five seconds of compute per second of speech. Nemotron measures **0.05** —
///     twenty times faster than real time. Re-decoding a window every pass is
///     what buys the commit rule, and that multiplier is the whole cost. A
///     live meeting cannot be captioned at 4x real time, and no amount of
///     tuning moves this by an order of magnitude.
///
///   - **It starves the reconciler.** This engine's cumulative text *revises*
///     between passes — a comma becomes a period, a word is re-timed — because
///     that is what a fixed-receptive-field model does when it sees more audio.
///     `CaptionTranscriptReconciler.accepts(_:)` admits a revision only while it
///     still extends what it has already committed, and returns `.none`
///     otherwise, on the deliberate grounds that a rewriting engine would
///     otherwise duplicate caption lines. So the first revised character
///     silences it for the rest of the session and the remaining speech is
///     dropped without error. Nemotron's RNN-T output only ever grows, so this
///     never arises for it.
///
/// The second is a design incompatibility with a component Nemotron also
/// depends on, not a bug here. Changing the reconciler to tolerate a revising
/// engine means changing the path that demonstrably works, for an engine that
/// cannot caption live audio anyway. So `ASREngine` keeps the case — the 626 MB
/// needs a registry row so it can be deleted, not measured as stray bytes — but
/// takes it out of the picker.
///
/// The benchmark lives in `CaptionASRPerformanceTests.installedWhisperTurboBenchmark`
/// and the commit rule in `WhisperTurboEngineTests`, so this stays re-answerable
/// if either the reconciler or the hardware changes.
final class WhisperTurboEngine: FluidStreamingEngine, @unchecked Sendable {
    /// Argmax recommends the September 2024 checkpoint for multilingual work —
    /// measurably better than the 2023 v3 on Spanish, Hindi and Korean — and the
    /// 626 MB variant over the 955 MB one, which is under 1% WER apart for a
    /// third fewer bytes.
    static let modelIdentifier = "openai_whisper-large-v3-v20240930_626MB"
    /// Whisper's native input rate, and what the capture path already produces.
    let sampleRate: Double = 16_000

    /// How much new audio triggers a pass.
    ///
    /// This is the latency dial, and the cost dial with it: a shorter step
    /// revises the caption sooner and re-decodes more often. 0.75 s is below
    /// the time it takes to read a caption line, so the step is not what the
    /// user waits on.
    static let stepSeconds: Double = 0.75

    /// How far back from the live edge a word must end before it is committed.
    static let commitHorizonSeconds: Double = 1.5

    /// Already-committed audio kept at the front of the window.
    ///
    /// Two seconds is enough for the decoder to see how the utterance started.
    /// Too little and boundary words are lost; too much and every pass re-decodes
    /// audio that was settled long ago.
    static let leftContextSeconds: Double = 2.0

    /// Ceiling on the window, and the only place audio is ever dropped
    /// uncommitted.
    ///
    /// Steady state settles at roughly `leftContext + commitHorizon + step`, so
    /// this is never reached while recognition is working. It bounds the case
    /// where it is not: a decode that returns no words at all — silence, or a
    /// model that has stopped producing output — would otherwise grow the
    /// window without limit and re-decode all of it every step. Same reasoning
    /// as `StreamingASRBackend.maxPendingSeconds`: stale audio is worthless
    /// against a machine that is not keeping up.
    static let maximumWindowSeconds: Double = 24

    // MARK: - Languages
    //
    // Whisper's own card claims 99 languages, and large-v3 is trained on all of
    // them. This list is deliberately shorter, and the reason matters: the
    // model's published evaluation separates the languages it is genuinely good
    // at from the long tail where it transcribes *something* confidently and
    // wrongly. Parakeet was cut from this surface for exactly that failure, and
    // `canHear` exists to refuse it rather than invite it.
    //
    // So this is the reliable subset, not the claimed one. A language absent
    // here is one this engine will not claim to hear — a smaller promise than
    // Whisper makes, and an honest one.

    static let reliableLanguages: Set<String> = [
        "ar", "bg", "ca", "cs", "da", "de", "el", "en", "es", "et", "eu",
        "fa", "fi", "fr", "gl", "he", "hi", "hr", "hu", "id", "it", "ja",
        "ko", "lt", "lv", "ms", "nb", "nl", "no", "pl", "pt", "ro", "ru",
        "sk", "sl", "sv", "th", "tr", "uk", "vi", "zh",
    ]

    // MARK: - Model location
    //
    // The dictation Whisper models' directory convention, so the registry's
    // completion markers and this engine's completeness check cannot disagree
    // about what a model is.

    static var assetDirectory: URL {
        ModelRegistry.root.appendingPathComponent("whisper-\(modelIdentifier)", isDirectory: true)
    }

    static var stagingDirectory: URL {
        ModelRegistry.root.appendingPathComponent("whisper-\(modelIdentifier).partial", isDirectory: true)
    }

    /// Referenced from the dictation type rather than restated, so the two
    /// cannot drift into disagreeing about what a WhisperKit model is.
    static let requiredBundles = WhisperDictationBackend.ModelChoice.requiredBundles

    /// True when the bytes are on disk and look complete.
    ///
    /// The same enumeration the dictation path uses, deliberately. A directory
    /// that exists is not a model, and a half-written `.mlmodelc` counted as
    /// ready is how a caption session starts and then produces nothing.
    static func isDownloaded() -> Bool {
        let folder = assetDirectory
        return requiredBundles.allSatisfy { name in
            let url = folder.appendingPathComponent(name)
            guard let values = try? url.resourceValues(
                forKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey]),
                  values.isDirectory == true, values.isSymbolicLink != true else { return false }
            guard let enumerator = FileManager.default.enumerator(
                at: url,
                includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]
            ) else { return false }
            return enumerator.contains { item in
                guard let itemURL = item as? URL,
                      let values = try? itemURL.resourceValues(
                        forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
                else { return false }
                return values.isRegularFile == true && values.isSymbolicLink != true
                    && (values.fileSize ?? 0) > 0
            }
        }
    }

    /// Fetch the weights without loading them, the way every Download button
    /// does. Resumable: WhisperKit's downloader writes each file to
    /// `<file>.incomplete` and moves it into place, so the staging directory is
    /// the resume state and is deliberately never cleared on failure — deleting
    /// it would make every cancelled 626 MB fetch cost another 626 MB.
    static func downloadWeights(progress: @escaping ProgressSink) async throws {
        if isDownloaded() { return }
        try FileManager.default.createDirectory(at: ModelRegistry.root, withIntermediateDirectories: true)
        let downloaded = try await WhisperKit.download(
            variant: modelIdentifier,
            downloadBase: stagingDirectory,
            useBackgroundSession: false,
            from: "argmaxinc/whisperkit-coreml",
            token: nil,
            endpoint: Constants.defaultRemoteEndpoint,
            progressCallback: { p in
                progress(DownloadProgress(fraction: p.fractionCompleted,
                                          note: String(localized: "Downloading Whisper turbo…")))
            })
        try Task.checkCancellation()
        // Rename-out-of-the-way-then-rename-back, as the dictation path does, so
        // a failure here cannot leave the user with no model after a paid-for
        // transfer.
        let fm = FileManager.default
        let superseded = ModelRegistry.root.appendingPathComponent("whisper-turbo.superseded",
                                                                  isDirectory: true)
        try? fm.removeItem(at: superseded)
        let hadPrevious = fm.fileExists(atPath: assetDirectory.path)
        if hadPrevious { try fm.moveItem(at: assetDirectory, to: superseded) }
        do {
            try fm.moveItem(at: downloaded, to: assetDirectory)
        } catch {
            if hadPrevious { try? fm.moveItem(at: superseded, to: assetDirectory) }
            throw error
        }
        try? fm.removeItem(at: stagingDirectory)
        try? fm.removeItem(at: superseded)
    }

    // MARK: - Session state

    private let lock = NSLock()
    private var whisper: WhisperKit?
    private var onPartial: (@Sendable (String) -> Void)?
    /// Audio still in play: left context at the front, undecided audio behind it.
    private var window = FloatRingBuffer()
    /// Samples at the front of `window` that are already-committed context. They
    /// are re-decoded so the model has history, and then discarded by timestamp.
    private var contextSamples = 0
    private var committedText = ""
    private var volatileText = ""
    private var detected: String?

    /// Every engine that currently holds loaded weights.
    ///
    /// The registry's `unload` hook is synchronous — Settings calls it from a
    /// button handler — while unloading CoreML is not. So deletion cannot await
    /// the unload, and the engine has to be reachable synchronously to drop its
    /// reference. Weak, because a registry that kept engines alive would defeat
    /// the teardown it exists to make safe.
    private static let resident = ResidentEngines()

    /// Drop the loaded model without awaiting the unload.
    ///
    /// Unlinking a file a resident CoreML model still has mapped frees nothing,
    /// so without this the app would sit on 626 MB of weights the user has
    /// just deleted, and a re-download would land underneath a model still
    /// reading the old bytes.
    static func forgetLoadedModel() {
        for engine in resident.takeAll() {
            let model = engine.lock.withLock { () -> WhisperKit? in
                let m = engine.whisper
                engine.whisper = nil
                return m
            }
            if let model { Task { await model.unloadModels() } }
        }
    }

    // MARK: - FluidStreamingEngine

    func load(progress: @escaping @Sendable (String) -> Void) async throws {
        if !Self.isDownloaded() {
            progress(String(localized: "Downloading Whisper turbo…"))
            try await Self.downloadWeights { p in progress(p.note) }
        }
        progress(String(localized: "Loading Whisper turbo…"))
        let model = try await WhisperKit(model: Self.modelIdentifier,
                                         modelRepo: nil,
                                         modelFolder: Self.assetDirectory.path,
                                         prewarm: false,
                                         load: false,
                                         download: false)
        do {
            try await model.setupModels(model: Self.modelIdentifier,
                                        modelRepo: nil,
                                        modelFolder: Self.assetDirectory.path,
                                        download: false)
            try await LocalGeneration.loadModel { try await model.loadModels(prewarmMode: true) }
        } catch {
            await model.unloadModels()
            throw error
        }
        lock.withLock { whisper = model }
        Self.resident.add(self)
        progress(String(localized: "Whisper turbo ready."))
    }

    func setPartial(_ callback: @escaping @Sendable (String) -> Void) async {
        lock.withLock { onPartial = callback }
    }

    func reset() async {
        lock.withLock {
            window.removeAll(keepingCapacity: true)
            contextSamples = 0
            committedText = ""
            volatileText = ""
        }
    }

    /// Fold a batch in and decode once enough new audio has arrived.
    ///
    /// The decode is awaited rather than fired. `StreamingASRBackend` guarantees
    /// exactly one `process()` is ever in flight and leans on that to keep
    /// engine state single-threaded; a second concurrent decode here would
    /// reintroduce the class of bug that class exists to prevent.
    func process(_ samples: [Float]) async throws {
        let due = lock.withLock { () -> Bool in
            window.append(contentsOf: samples)
            let undecided = window.count - contextSamples
            return Double(undecided) / sampleRate >= Self.stepSeconds
        }
        guard due, let model = lock.withLock({ whisper }) else { return }
        try await decodeWindow(model)
    }

    private func decodeWindow(_ model: WhisperKit) async throws {
        let audio = lock.withLock { window.ordered() }
        guard !audio.isEmpty else { return }
        let options = DecodingOptions(language: nil,
                                      detectLanguage: true,
                                      wordTimestamps: true)
        let decoding = ContinuousClock.now
        let results = await model.transcribe(audioArrays: [audio], decodeOptions: options, callback: nil)
        await LocalGeneration.recordModelTiming("model.recognition", since: decoding, cold: false, calls: 1)
        // `transcribe` returns `[[TranscriptionResult]?]` — one optional array per
        // input buffer, and we passed one buffer. `compactMap` flattens that
        // outer layer; `first` alone would still be optional-of-optional.
        let segments = results.compactMap { $0 }.first ?? []

        let windowSeconds = Double(audio.count) / sampleRate
        let split = Self.split(segments: segments,
                               contextSeconds: lock.withLock { Double(contextSamples) / sampleRate },
                               windowSeconds: windowSeconds)

        let (callback, cumulative) = lock.withLock { () -> ((@Sendable (String) -> Void)?, String) in
            if detected == nil { detected = segments.first?.language }
            if split.language != nil { detected = split.language }

            if !split.settled.isEmpty {
                let addition = split.settled.joined(separator: " ")
                committedText = committedText.isEmpty ? addition : committedText + " " + addition
            }
            volatileText = split.volatile

            if split.decidedUpTo > 0 {
                // Everything the settled words covered can leave the window,
                // bar the left context the next pass needs to hear how the
                // sentence started.
                let keep = min(Int(Self.leftContextSeconds * sampleRate),
                               Int(split.decidedUpTo * sampleRate))
                let drop = Int(split.decidedUpTo * sampleRate) - keep
                if drop > 0 { window.dropFirst(drop) }
                contextSamples = keep
            }

            // The overload valve. Only reachable when a decode produced nothing,
            // because anything with words settles up to the horizon.
            let cap = Int(Self.maximumWindowSeconds * sampleRate)
            if window.count > cap {
                let excess = window.count - cap
                window.dropFirst(excess)
                contextSamples = max(0, contextSamples - excess)
                NSLog("sAiity whisper turbo: window over %.0fs with nothing to commit — dropping oldest audio",
                      Self.maximumWindowSeconds)
            }

            let joined = [committedText, volatileText].filter { !$0.isEmpty }.joined(separator: " ")
            return (onPartial, joined)
        }
        if let callback, !cumulative.isEmpty { callback(cumulative) }
    }

    /// The commit rule, as a pure function so it can be tested without a model.
    ///
    /// Three buckets, in timestamp order:
    ///
    ///   - ending within the left context: already committed on an earlier pass.
    ///     Kept in the window so the decoder has history, and dropped here so it
    ///     cannot be counted twice.
    ///   - ending at or before the commit horizon: settled. Whisper has stopped
    ///     moving this text and, with more audio, will not start moving it again.
    ///   - after the horizon: volatile. The reconciler decides when to show it.
    ///
    /// The context test is on the word's **end**, not its start. The context is
    /// always exactly the span ending at the previous commit point, so
    /// "ends inside it" is precisely "was already committed". Testing the start
    /// instead looks equivalent and is not: a word Whisper has re-timed so it
    /// now straddles the boundary starts inside the context and ends outside it,
    /// and dropping that word loses a real word from the transcript. Revising
    /// timings is the normal behaviour of this model, not an edge case.
    static func split(segments: [TranscriptionResult],
                      contextSeconds: Double,
                      windowSeconds: Double,
                      horizon: Double = commitHorizonSeconds)
        -> (settled: [String], volatile: String, decidedUpTo: Double, language: String?) {
        let commitBefore = windowSeconds - horizon
        var settled: [String] = []
        var pending: [String] = []
        var decidedUpTo: Double = 0
        var language: String?

        for segment in segments {
            if language == nil { language = segment.language }
            for word in segment.allWords {
                let end = Double(word.end)
                guard end > contextSeconds else { continue }
                let text = word.word.trimmingCharacters(in: .whitespaces)
                guard !text.isEmpty else { continue }
                if end <= commitBefore {
                    settled.append(text)
                    decidedUpTo = max(decidedUpTo, end)
                } else {
                    pending.append(text)
                }
            }
        }
        return (settled, pending.joined(separator: " "), decidedUpTo, language)
    }

    /// Decode whatever is left and return the complete session transcript.
    ///
    /// The tail is decoded with no commit horizon: no more audio is coming, so
    /// nothing can revise it, and withholding it would drop real speech.
    ///
    /// Only the audio *after* the commit point is decoded. The window still
    /// holds `leftContextSeconds` of already-committed audio so the live passes
    /// have history, and decoding that again here would splice the tail onto a
    /// second copy of the prefix. That is not cosmetic: the pipeline's
    /// reconciler only accepts a final string that extends the one it already
    /// committed, so a duplicated prefix makes it reject the whole flush — and
    /// the last sentence of every session silently never reaches the transcript.
    func finishSession() async -> String? {
        guard let model = lock.withLock({ whisper }) else { return nil }
        let audio = lock.withLock { () -> [Float] in
            let all = window.ordered()
            guard contextSamples < all.count else { return [] }
            return Array(all[contextSamples...])
        }
        guard !audio.isEmpty else {
            return lock.withLock { committedText.isEmpty ? nil : committedText }
        }
        let options = DecodingOptions(language: nil, detectLanguage: true, wordTimestamps: false)
        let decoding = ContinuousClock.now
        let results = await model.transcribe(audioArrays: [audio], decodeOptions: options, callback: nil)
        await LocalGeneration.recordModelTiming("model.recognition", since: decoding, cold: false, calls: 1)
        let segments = results.compactMap { $0 }.first ?? []
        let tail = segments.map(\.text).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        return lock.withLock {
            if detected == nil { detected = segments.first?.language }
            window.removeAll(keepingCapacity: true)
            contextSamples = 0
            let whole = [committedText, tail].filter { !$0.isEmpty }.joined(separator: " ")
            return whole.isEmpty ? nil : whole
        }
    }

    func teardown() async {
        let model = lock.withLock { () -> WhisperKit? in
            let m = whisper
            whisper = nil
            return m
        }
        Self.resident.remove(self)
        if let model { await model.unloadModels() }
    }

    /// The language Whisper reported for the audio — a decode-time tag, not one
    /// inferred from the transcript's spelling. Nil until a decode produced one.
    func detectedLanguage() async -> String? {
        lock.withLock { detected }
    }
}

#if SAIITY_TEST_HOOKS
extension WhisperTurboEngine {
    /// Test-only view of the commit state, for the diagnostic that separates
    /// "the commit rule drops text" from "the incremental path drops text".
    var debugCommitted: String { lock.withLock { committedText } }
    var debugVolatile: String { lock.withLock { volatileText } }
    var debugWindowSeconds: Double { lock.withLock { Double(window.count) / sampleRate } }
    var debugContextSeconds: Double { lock.withLock { Double(contextSamples) / sampleRate } }
}
#endif

/// The set of engines currently holding loaded weights, held weakly.
private final class ResidentEngines: @unchecked Sendable {
    private final class Weak {
        weak var engine: WhisperTurboEngine?
        init(_ engine: WhisperTurboEngine) { self.engine = engine }
    }

    private let lock = NSLock()
    private var entries: [Weak] = []

    func add(_ engine: WhisperTurboEngine) {
        lock.withLock {
            // Prune on the way in rather than growing a list that only ever
            // accumulates engines that have already been torn down.
            entries.removeAll { $0.engine == nil }
            entries.append(Weak(engine))
        }
    }

    func remove(_ engine: WhisperTurboEngine) {
        lock.withLock { entries.removeAll { $0.engine == nil || $0.engine === engine } }
    }

    /// The live engines, emptied. The caller owns the unloads.
    func takeAll() -> [WhisperTurboEngine] {
        lock.withLock {
            let live = entries.compactMap(\.engine)
            entries.removeAll()
            return live
        }
    }
}
