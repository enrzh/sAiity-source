import Foundation

/// Which recognition engine to run. All are fully on-device; they differ in what
/// they are good at, and the difference is real enough that the honest answer is
/// to let the user pick per situation rather than choose for them.
enum ASREngine: String, CaseIterable, Sendable {
    case nemotron
    case parakeetEou

    static var current: ASREngine {
        get { ASREngine(rawValue: UserDefaults.standard.string(forKey: "asrEngine") ?? "") ?? .nemotron }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "asrEngine") }
    }

    var displayName: String {
        switch self {
        case .nemotron: return "Nemotron"
        case .parakeetEou: return "Parakeet"
        }
    }

    var summary: String {
        switch self {
        case .nemotron:
            return "One multilingual model, 634 MB, downloaded once. Its own metadata declares 121 "
                 + "language tags — European, Asian and African — and it identifies the spoken "
                 + "language from audio rather than being told, so there is no per-language "
                 + "switching. Better on noisy and music-backed audio; slightly higher latency."
        case .parakeetEou:
            return "English only, 437 MB. A fifth of Nemotron's parameters, so it reaches the "
                 + "first word sooner, and it detects the end of an utterance itself, so sentences "
                 + "break where the speaker actually stopped. Pick this if you only caption "
                 + "English; it will produce confident nonsense on anything else."
        }
    }

    /// True when this engine needs weights fetched before use.
    var needsDownload: Bool {
        switch self {
        case .nemotron: return !NemotronEngine.isDownloaded()
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

    func makeBackend() -> TranscriptionBackend {
        switch self {
        case .nemotron:
            return StreamingASRBackend(name: "NVIDIA Nemotron (streaming, on-device)",
                                       engine: NemotronEngine())
        case .parakeetEou:
            return StreamingASRBackend(name: "Parakeet EOU (streaming, on-device)",
                                       engine: ParakeetEouEngine())
        }
    }

    /// This engine's entry in the model registry. Owning the descriptor here
    /// rather than in a central switch is what makes a new engine case produce a
    /// working Models row without touching the UI.
    var assetDescriptor: ModelAsset {
        switch self {
        case .nemotron:
            return ModelAsset(
                id: "asr.nemotron",
                family: .recognition,
                title: "Nemotron (multilingual)",
                detail: summary,
                advertisedBytes: 634 * 1_048_576,
                storage: .directory(NemotronEngine.assetDirectory,
                                    markers: ["multilingual/\(NemotronEngine.chunkMs)ms/metadata.json"]),
                removal: .remove(NemotronEngine.assetDirectory),
                use: .whenRecognitionEngine(.nemotron),
                install: { sink in try await NemotronEngine.downloadWeights(progress: sink) })

        case .parakeetEou:
            return ModelAsset(
                id: "asr.parakeetEou",
                family: .recognition,
                title: "Parakeet EOU (English)",
                detail: summary,
                advertisedBytes: 437 * 1_048_576,
                storage: .directory(ParakeetEouEngine.assetDirectory,
                                    markers: ParakeetEouEngine.markers),
                removal: .remove(ParakeetEouEngine.assetDirectory),
                use: .whenRecognitionEngine(.parakeetEou),
                install: { sink in try await ParakeetEouEngine.downloadWeights(progress: sink) })
        }
    }
}

/// What languages a recognition engine can handle.
enum LanguageCoverage: Sendable {
    /// Multilingual, with the language identified from the audio itself.
    case manyDetectedFromAudio
    case only(Set<String>)
}
