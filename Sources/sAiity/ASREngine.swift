import Foundation

/// Which recognition engine to run. Nemotron is the supported on-device path;
/// the raw Parakeet case remains only so old preferences and model files can be
/// read without silently re-entering the product surface.
enum ASREngine: String, CaseIterable, Sendable {
    case nemotron
    /// Whisper large-v3-turbo. **Measured, and not offered.**
    ///
    /// It is a real adapter behind the same seam and it transcribes well — fed a
    /// whole utterance in one pass it returns the sentence correctly, which is
    /// what the model is capable of. It fails as a *live* caption engine for two
    /// measured reasons, both recorded in `WhisperTurboEngine`:
    ///
    ///   - It is not a streaming decoder. Re-decoding a window every pass gives
    ///     a real-time factor of **3.6–4.6** — it needs three to five seconds
    ///     of compute per second of speech, so it structurally cannot keep up
    ///     with a live meeting. Nemotron measures **0.05**, twenty times faster
    ///     than real time.
    ///   - Its cumulative text revises between passes (a comma becomes a
    ///     period), and `CaptionTranscriptReconciler` accepts a revision only
    ///     while it still extends what it already committed. One revised
    ///     character and it goes permanently silent, so the session's remaining
    ///     speech is dropped. Nemotron's RNN-T output only ever grows, so this
    ///     never happens to it.
    ///
    /// Word error rate followed from that: 0.60 against Nemotron's 0.05 on the
    /// same three fixtures, almost entirely from *missing* words rather than
    /// wrong ones.
    ///
    /// The case stays so the model keeps a registry row — a 626 MB download the
    /// user made for this experiment has to be visible and deletable, not
    /// measured as "other files" — but it is out of the picker, and a stored
    /// preference for it normalizes to no selection.
    case whisperTurbo
    /// Qwen3-ASR 0.6B, 4-bit. Pause-final captions. See `QwenASREngine`.
    case qwen06
    /// Qwen3-ASR 1.7B, 4-bit. Same caption behaviour, larger weights.
    case qwen17
    /// Legacy on-disk value. Keep the raw case so old preferences can be read
    /// and normalized without making it selectable again.
    case parakeetEou

    static var allCases: [ASREngine] { [.nemotron, .qwen06, .qwen17, .whisperTurbo] }

    /// The engines a user may pick. Whisper stays out: see `whisperTurbo`.
    static let userSelectableCases: [ASREngine] = [.nemotron, .qwen06, .qwen17]

    static let primaryCases: [ASREngine] = [.nemotron]
    /// Empty. Kept as a named list so the shape survives the measurement that
    /// emptied it, and so a future engine has somewhere obvious to go.
    static let advancedCases: [ASREngine] = []

    var isAdvanced: Bool { !Self.primaryCases.contains(self) }

    static func visibleSelection(_ engine: ASREngine?) -> ASREngine? {
        guard let engine, userSelectableCases.contains(engine) else { return nil }
        return engine
    }

    /// What the user has chosen — or nothing, which is the honest state of a
    /// Mac where no recognition model has been downloaded yet. Legacy values
    /// are deliberately normalized away rather than silently selecting a model
    /// the user can no longer choose.
    static var selected: ASREngine? {
        get {
            visibleSelection(UserDefaults.standard.string(forKey: "asrEngine")
                .flatMap(ASREngine.init(rawValue:)))
        }
        set {
            if let value = visibleSelection(newValue) {
                UserDefaults.standard.set(value.rawValue, forKey: "asrEngine")
            } else {
                UserDefaults.standard.removeObject(forKey: "asrEngine")
            }
        }
    }

    /// The engine to suggest when nothing is chosen. A suggestion is not a
    /// selection: it is rendered as a badge and a Download button, never as a
    /// filled radio.
    static let recommended: ASREngine = .nemotron

    /// The engine the pipeline runs. Only reached once `selected` is non-nil —
    /// `AppDelegate.start()` refuses to begin otherwise — so the fallback here
    /// keeps the backend types non-optional without ever deciding anything.
    static var effective: ASREngine { selected ?? recommended }

    /// Dictation's streaming path has always been able to persist its engine
    /// separately. Normalize a retired Parakeet value to the supported
    /// Nemotron path instead of letting an old preference resurrect it.
    static var dictationSelected: ASREngine? {
        get {
            guard let raw = UserDefaults.standard.string(forKey: "dictationStreamingEngine"),
                  let value = ASREngine(rawValue: raw) else { return nil }
            return visibleSelection(value)
        }
        set {
            if let value = visibleSelection(newValue) {
                UserDefaults.standard.set(value.rawValue, forKey: "dictationStreamingEngine")
            } else {
                UserDefaults.standard.removeObject(forKey: "dictationStreamingEngine")
            }
        }
    }

    static var dictationEffective: ASREngine {
        dictationSelected ?? recommended
    }

    var displayName: String {
        switch self {
        case .nemotron: return String(localized: "Nemotron")
        case .whisperTurbo: return String(localized: "Whisper turbo")
        case .qwen06: return String(localized: "Qwen3-ASR 0.6B")
        case .qwen17: return String(localized: "Qwen3-ASR 1.7B")
        case .parakeetEou: return String(localized: "Parakeet")
        }
    }

    var summary: String {
        switch self {
        case .nemotron:
            return String(localized: "634 MB. Automatic recognition with continuous caption updates. The adapter can expose the first audio language tag; complete source-language coverage is not declared here.")
        case .whisperTurbo:
            return String(localized: "626 MB. Re-reads a window of audio for each update and can fall behind continuous speech. Its declared caption language set is listed separately; the adapter exposes an audio language tag.")
        case .qwen06:
            return String(localized: "700 MB. Automatic recognition with a line when the speaker pauses, or after 10 seconds of continuous speech. This adapter exposes no audio language tag, and its complete source-language coverage is not declared here.")
        case .qwen17:
            return String(localized: "2.1 GB. The same pause-based automatic recognition as Qwen3-ASR 0.6B, with larger weights. This adapter exposes no audio language tag, and its complete source-language coverage is not declared here.")
        case .parakeetEou:
            return String(localized: "English only, 437 MB. A fifth of Nemotron's parameters, so it reaches the first word sooner, and it detects the end of an utterance itself, so sentences break where the speaker actually stopped. Pick this if you only caption English; it will produce confident nonsense on anything else.")
        }
    }

    /// The compact label used in the everyday settings surface. The full
    /// explanation stays available in help and on the Models page.
    var shortSummary: String {
        switch self {
        case .nemotron:
            return String(localized: "Multilingual · 634 MB · detects language automatically")
        case .whisperTurbo:
            return String(localized: "41 languages · 626 MB · strongest on accented speech")
        case .qwen06:
            return String(localized: "Multilingual · 700 MB · a line when the speaker pauses")
        case .qwen17:
            return String(localized: "Multilingual · 2.1 GB · same pause captions, heavier")
        case .parakeetEou:
            return String(localized: "English only · 437 MB · fastest")
        }
    }

    /// True when this engine needs weights fetched before use.
    var needsDownload: Bool {
        switch self {
        case .nemotron:
            return !NemotronEngine.isDownloaded(chunkMs: NemotronEngine.selectedChunkMs)
        case .whisperTurbo:
            return !WhisperTurboEngine.isDownloaded()
        case .qwen06:
            return !QwenASREngine.isDownloaded(.small)
        case .qwen17:
            return !QwenASREngine.isDownloaded(.large)
        case .parakeetEou: return !ParakeetEouEngine.isDownloaded()
        }
    }

    /// Declared source coverage, independent of installation and measured quality.
    /// The pinned Nemotron/Qwen libraries do not expose a complete static code
    /// set here. Automatic recognition alone does not establish that set.
    var coverage: LanguageCoverage {
        switch self {
        case .nemotron, .qwen06, .qwen17: return .unknown
        case .whisperTurbo: return .only(WhisperTurboEngine.reliableLanguages)
        case .parakeetEou: return .only(["en"])
        }
    }

    /// Auto recognition does not require a source-language selection, even when
    /// complete coverage or an audio language tag is unavailable to the app.
    var automaticallyRecognizesLanguage: Bool { self != .parakeetEou }

    /// Whether this adapter can expose an audio language tag. Nemotron returns
    /// its first tag; Whisper's per-window tag can change. Neither promises a
    /// language for every region. Qwen recognizes automatically but returns nil.
    var identifiesLanguageFromAudio: Bool {
        switch self {
        case .nemotron, .whisperTurbo: return true
        case .qwen06, .qwen17, .parakeetEou: return false
        }
    }

    /// Whether source support is declared. False for unknown coverage means
    /// unconfirmed, not known unsupported; callers must check `coverage` before
    /// warning that an engine cannot recognize a language.
    func canHear(_ bcp47: String) -> Bool {
        let base = bcp47.split(separator: "-").first.map(String.init) ?? bcp47
        switch coverage {
        case .unknown: return false
        case .only(let codes): return codes.contains(base)
        }
    }

    /// The registry id of the files this engine would load right now. The
    /// selected Nemotron tier matters: each tier is its own model directory,
    /// so damage in one says nothing about the other.
    var activeAssetID: String {
        switch self {
        case .nemotron:
            return AssetID.nemotron(chunkMs: NemotronEngine.selectedChunkMs)
        case .whisperTurbo:
            return AssetID.whisperTurbo
        case .qwen06:
            return AssetID.qwen06
        case .qwen17:
            return AssetID.qwen17
        case .parakeetEou:
            return AssetID.parakeetEou
        }
    }

    func makeBackend(onPerformance: (@Sendable (Double, Double) -> Void)? = nil,
                     onMetrics: (@Sendable (StreamingASRMetrics) -> Void)? = nil) -> TranscriptionBackend {
        switch self {
        case .nemotron:
            return StreamingASRBackend(name: String(localized: "NVIDIA Nemotron (streaming, on-device)"),
                                       engine: NemotronEngine(),
                                       onPerformance: onPerformance,
                                       onMetrics: onMetrics)
        case .whisperTurbo:
            return StreamingASRBackend(name: String(localized: "Whisper large-v3-turbo (on-device)"),
                                       engine: WhisperTurboEngine(),
                                       onPerformance: onPerformance,
                                       onMetrics: onMetrics)
        case .parakeetEou:
            return StreamingASRBackend(name: String(localized: "Parakeet EOU (streaming, on-device)"),
                                       engine: ParakeetEouEngine(),
                                       onPerformance: onPerformance,
                                       onMetrics: onMetrics)
        case .qwen06:
            return StreamingASRBackend(name: String(localized: "Qwen3-ASR 0.6B (on-device)"),
                                       engine: QwenASREngine(size: .small),
                                       onPerformance: onPerformance,
                                       onMetrics: onMetrics)
        case .qwen17:
            return StreamingASRBackend(name: String(localized: "Qwen3-ASR 1.7B (on-device)"),
                                       engine: QwenASREngine(size: .large),
                                       onPerformance: onPerformance,
                                       onMetrics: onMetrics)
        }
    }

    /// This engine's registry entries. Owning the descriptors here rather than
    /// in a central switch is what makes a new engine case produce working
    /// Models rows without touching the UI. Plural, because Nemotron's latency
    /// tiers are each their own ~640 MB download with the chunk size baked into
    /// the encoder — a tier is a model, not a setting.
    var assetDescriptors: [ModelAsset] {
        switch self {
        case .nemotron:
            return NemotronEngine.availableChunkMs.map { ms in
                let fast = ms < NemotronEngine.chunkMs
                return ModelAsset(
                    id: AssetID.nemotron(chunkMs: ms),
                    family: .recognition,
                    title: fast ? String(localized: "Nemotron (multilingual, fast)")
                                 : String(localized: "Nemotron (multilingual)"),
                    // The balanced tier, not the fast one: its own detail text
                    // warns the fast tier costs roughly double the encoder work.
                    detail: fast
                        ? String(localized: "The same multilingual model decoding every \(ms) ms instead of \(NemotronEngine.chunkMs) — captions appear about twice as fast, for roughly double the encoder work per second of audio. Noticeable on battery. A separate download; both tiers can be installed.")
                        : summary,
                    // The balanced tier, not the fast one: its own detail text
                    // warns the fast tier costs roughly double the encoder work.
                    recommended: !fast,
                    licence: "NVIDIA Open Model License · huggingface.co/FluidInference",
                    advertisedBytes: 634 * 1_048_576,
                    // Each tier is measured and deleted as ITS OWN directory —
                    // removing one must not take the other tier with it.
                    storage: .directory(NemotronEngine.variantDirectory(chunkMs: ms),
                                        markers: ["metadata.json", NemotronEngine.completionMarker]),
                    removal: .remove(NemotronEngine.variantDirectory(chunkMs: ms)),
                    use: .whenNemotronTier(chunkMs: ms),
                    install: { sink in
                        try await NemotronEngine.downloadWeights(chunkMs: ms, progress: sink)
                    })
            }

        case .whisperTurbo:
            return [ModelAsset(
                id: AssetID.whisperTurbo,
                family: .recognition,
                title: String(localized: "Whisper large-v3 turbo (multilingual)"),
                detail: summary,
                // A deliberate second opinion, never a first choice. The Models
                // page sorts recommended rows to the top of each group, and
                // claiming this would put a 626 MB model above the Nemotron tier
                // that genuinely streams with automatic multilingual recognition.
                recommended: false,
                licence: "MIT · huggingface.co/argmaxinc/whisperkit-coreml",
                advertisedBytes: 626 * 1_048_576,
                storage: .stagedDirectory(final: WhisperTurboEngine.assetDirectory,
                                          staging: WhisperTurboEngine.stagingDirectory,
                                          markers: WhisperTurboEngine.requiredBundles),
                removal: .remove(WhisperTurboEngine.assetDirectory),
                use: .whenRecognitionEngine(.whisperTurbo),
                install: { sink in
                    try await WhisperTurboEngine.downloadWeights(progress: sink)
                },
                // A deleted model must not stay mapped: the CoreML weights are
                // still resident in the engine that loaded them, and unlinking
                // those bytes frees nothing.
                unload: { WhisperTurboEngine.forgetLoadedModel() })]

        case .qwen06:
            return [Self.qwenAsset(size: .small, engine: .qwen06)]
        case .qwen17:
            return [Self.qwenAsset(size: .large, engine: .qwen17)]
        case .parakeetEou:
            return [ModelAsset(
                id: AssetID.parakeetEou,
                family: .recognition,
                title: String(localized: "Parakeet EOU (English)"),
                detail: summary,
                // A deliberate narrowing, not a first choice — it produces
                // confident nonsense on anything but English.
                recommended: false,
                licence: "NVIDIA / CC-BY-4.0 · huggingface.co/FluidInference",
                advertisedBytes: 437 * 1_048_576,
                storage: .directory(ParakeetEouEngine.assetDirectory,
                                    markers: ParakeetEouEngine.markers),
                removal: .remove(ParakeetEouEngine.assetDirectory),
                use: .whenRecognitionEngine(.parakeetEou),
                install: { sink in try await ParakeetEouEngine.downloadWeights(progress: sink) })]
        }
    }

    private static func qwenAsset(size: QwenASREngine.Size, engine: ASREngine) -> ModelAsset {
        let title = engine.displayName
        return ModelAsset(
            id: engine.activeAssetID,
            family: .recognition,
            title: title,
            detail: engine.summary,
            recommended: false,
            licence: "Apache-2.0 · huggingface.co/aufklarer",
            advertisedBytes: size.advertisedBytes,
            storage: .directory(QwenASREngine.directory(for: size),
                                markers: ["vocab.json", "saiity-complete"]),
            removal: .remove(QwenASREngine.directory(for: size)),
            use: .whenRecognitionEngine(engine),
            install: { sink in
                try await QwenASREngine.downloadWeights(size: size, progress: sink)
            },
            unload: { QwenASREngine.forgetLoadedModel(size) })
    }
}

enum DictationRecognizer: String, CaseIterable, Sendable {
    case streaming, whisper
    static var selected: Self {
        get { Self(rawValue: UserDefaults.standard.string(forKey: "dictationRecognizer") ?? "streaming") ?? .streaming }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: "dictationRecognizer")
            WhisperDictationBackend.isSelected = newValue == .whisper
        }
    }
}

/// Declared source languages, not installation or measured recognition quality.
enum LanguageCoverage: Sendable {
    /// No complete source code set is available from the pinned declarations.
    case unknown
    case only(Set<String>)
}
