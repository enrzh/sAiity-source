import Foundation

/// Which recognition engine to run. All are fully on-device; they differ in what
/// they are good at, and the difference is real enough that the honest answer is
/// to let the user pick per situation rather than choose for them.
enum ASREngine: String, CaseIterable, Sendable {
    case nemotron
    case parakeetEou

    /// What the user has chosen — or nothing, which is the honest state of a
    /// Mac where no recognition model has been downloaded yet.
    ///
    /// This was `= .nemotron`, and a non-optional default is not a small lie:
    /// Settings painted Nemotron as the selected engine, the Models page badged
    /// it "in use", and neither had any bytes behind it. Pressing Start then
    /// committed to a 634 MB download nobody had agreed to. Nothing is chosen
    /// on the user's behalf here; `recommended` is what the UI offers instead.
    @Defaults(optionalRawKey: "asrEngine") static var selected: ASREngine?

    /// The engine to suggest when nothing is chosen. A suggestion is not a
    /// selection: it is rendered as a badge and a Download button, never as a
    /// filled radio.
    static let recommended: ASREngine = .nemotron

    /// The engine the pipeline runs. Only reached once `selected` is non-nil —
    /// `AppDelegate.start()` refuses to begin otherwise — so the fallback here
    /// keeps the backend types non-optional without ever deciding anything.
    static var effective: ASREngine { selected ?? recommended }

    var displayName: String {
        switch self {
        case .nemotron: return String(localized: "Nemotron")
        case .parakeetEou: return String(localized: "Parakeet")
        }
    }

    var summary: String {
        switch self {
        case .nemotron:
            return String(localized: "One multilingual model, 634 MB, downloaded once. Its own metadata declares 121 language tags — European, Asian and African — and it identifies the spoken language from audio rather than being told, so there is no per-language switching. Better on noisy and music-backed audio; slightly higher latency.")
        case .parakeetEou:
            return String(localized: "English only, 437 MB. A fifth of Nemotron's parameters, so it reaches the first word sooner, and it detects the end of an utterance itself, so sentences break where the speaker actually stopped. Pick this if you only caption English; it will produce confident nonsense on anything else.")
        }
    }

    /// True when this engine needs weights fetched before use.
    var needsDownload: Bool {
        switch self {
        case .nemotron:
            return !NemotronEngine.isDownloaded(chunkMs: NemotronEngine.selectedChunkMs)
        case .parakeetEou: return !ParakeetEouEngine.isDownloaded()
        }
    }

    /// What this engine can actually recognise. Nemotron reads its own list from
    /// the metadata it downloaded; before that we have nothing honest to say, so
    /// the answer is "unknown" rather than a guess.
    var coverage: LanguageCoverage {
        switch self {
        case .nemotron: return .manyDetectedFromAudio
        case .parakeetEou: return .only(["en"])
        }
    }

    /// True when the engine identifies the spoken language itself, so there is
    /// no locale for the user to choose.
    var identifiesLanguageFromAudio: Bool { self == .nemotron }

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
        case .parakeetEou:
            return AssetID.parakeetEou
        }
    }

    func makeBackend() -> TranscriptionBackend {
        switch self {
        case .nemotron:
            return StreamingASRBackend(name: String(localized: "NVIDIA Nemotron (streaming, on-device)"),
                                       engine: NemotronEngine())
        case .parakeetEou:
            return StreamingASRBackend(name: String(localized: "Parakeet EOU (streaming, on-device)"),
                                       engine: ParakeetEouEngine())
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
                                        markers: ["metadata.json"]),
                    removal: .remove(NemotronEngine.variantDirectory(chunkMs: ms)),
                    use: .whenNemotronTier(chunkMs: ms),
                    install: { sink in
                        try await NemotronEngine.downloadWeights(chunkMs: ms, progress: sink)
                    })
            }

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
