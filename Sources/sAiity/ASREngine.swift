import Foundation

/// Which recognition engine to run. Nemotron is the supported on-device path;
/// the raw Parakeet case remains only so old preferences and model files can be
/// read without silently re-entering the product surface.
enum ASREngine: String, CaseIterable, Sendable {
    case nemotron
    /// Whisper large-v3-turbo, as a second opinion on quality rather than a
    /// faster path. Not a fallback: it is chosen deliberately, and it is
    /// recommended by nothing.
    case whisperTurbo
    /// Legacy on-disk value. Keep the raw case so old preferences can be read
    /// and normalized without making it selectable again.
    case parakeetEou

    static var allCases: [ASREngine] { [.nemotron, .whisperTurbo] }

    /// The engines a user may pick.
    static let userSelectableCases: [ASREngine] = [.nemotron, .whisperTurbo]

    /// Nemotron is the first thing anyone should download: one model, 121
    /// languages, and a real streaming decoder whose cost tracks the audio it is
    /// given. Whisper turbo re-decodes a window on every pass to get the same
    /// effect, so it is a deliberate trade for the languages where Whisper is
    /// stronger, not an upgrade.
    static let primaryCases: [ASREngine] = [.nemotron]
    /// Behind the advanced disclosure, for the same reason Hy-MT2 is: a second
    /// opinion, not a default.
    static let advancedCases: [ASREngine] = [.whisperTurbo]

    /// True for anything that is not the recommended first choice.
    var isAdvanced: Bool { self != .nemotron }

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
        case .parakeetEou: return String(localized: "Parakeet")
        }
    }

    var summary: String {
        switch self {
        case .nemotron:
            return String(localized: "One multilingual model, 634 MB, downloaded once. Its own metadata declares 121 language tags — European, Asian and African — and it identifies the spoken language from audio rather than being told, so there is no per-language switching. Better on noisy and music-backed audio; slightly higher latency.")
        case .whisperTurbo:
            return String(localized: "626 MB. A larger, more widely trained model that is often the more accurate of the two on the languages it is good at, and the only one here that transcribes accented and non-native speech as well as native speech. It is not a streaming model: it re-reads a window of audio every time it produces an update, so it costs more work per second of captions and can fall behind on a fast speaker. It covers fewer languages than Nemotron, and identifies the language from the audio.")
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
        case .parakeetEou: return !ParakeetEouEngine.isDownloaded()
        }
    }

    /// What this engine can actually recognise. Nemotron reads its own list from
    /// the metadata it downloaded; before that we have nothing honest to say, so
    /// the answer is "unknown" rather than a guess.
    var coverage: LanguageCoverage {
        switch self {
        case .nemotron: return .manyDetectedFromAudio
        case .whisperTurbo: return .only(WhisperTurboEngine.reliableLanguages)
        case .parakeetEou: return .only(["en"])
        }
    }

    /// True when the engine identifies the spoken language itself, so there is
    /// no locale for the user to choose.
    ///
    /// Whisper reports a language tag from the decode itself, so it qualifies —
    /// but it is a per-window guess that can change between passes, which is a
    /// weaker promise than Nemotron's and one the translation path has to be
    /// able to survive.
    var identifiesLanguageFromAudio: Bool { self == .nemotron || self == .whisperTurbo }

    /// Whether speech in this language would be recognised at all. An
    /// English-only engine pointed at German does not fail — it produces
    /// confident nonsense, which is worse.
    func canHear(_ bcp47: String) -> Bool {
        let base = bcp47.split(separator: "-").first.map(String.init) ?? bcp47
        switch coverage {
        case .manyDetectedFromAudio: return true
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
                // that genuinely streams and covers 121 languages.
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

/// What languages a recognition engine can handle.
enum LanguageCoverage: Sendable {
    /// Multilingual, with the language identified from the audio itself.
    case manyDetectedFromAudio
    case only(Set<String>)
}
