import Foundation

/// A text-to-text translator for committed caption lines.
///
/// Deliberately narrow, mirroring `TranscriptionBackend`: prepare, translate,
/// stop. That keeps every engine swappable without the caption pipeline knowing
/// which one is running.
protocol Translating: AnyObject, Sendable {
    var name: String { get }
    /// Download/load whatever is needed. `progress` reports human-readable state.
    func prepare(from source: String, to target: String,
                 progress: @escaping @Sendable (String) -> Void) async throws
    /// Nil means "could not translate" — the caller keeps the original line
    /// rather than showing nothing.
    func translate(_ text: String, from source: String, to target: String) async -> String?
    func stop() async
}

/// Which translator to use.
///
/// The ordering here is the honest recommendation order, and the summaries say
/// why — including for the two that are slower than they sound.
enum TranslationEngine: String, CaseIterable, Sendable, Codable {
    case apple
    case whisper
    case madlad
    case qwen

    static var current: TranslationEngine {
        get { TranslationEngine(rawValue: UserDefaults.standard.string(forKey: "translationEngine") ?? "") ?? .apple }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "translationEngine") }
    }

    var displayName: String {
        switch self {
        case .apple: return "Apple"
        case .whisper: return "Whisper"
        case .madlad: return "MADLAD"
        case .qwen: return "Qwen"
        }
    }

    var summary: String {
        switch self {
        case .apple:
            return "Runs on the Neural Engine — a sentence comes back in tens of milliseconds. "
                 + "~40–80 MB per language pair, any target language. The fastest option."
        case .whisper:
            return "Speech straight to English in one model pass, skipping the separate "
                 + "translation step. English only, 1.5 GB, and in practice SLOWER than Apple: "
                 + "it re-decodes a moving window rather than encoding once."
        case .madlad:
            return "MADLAD-400-3B, a dedicated translation model on MLX. Best quality of the "
                 + "local options and Apache-2.0, so it can ship. 1.86 GB, and about 0.2 seconds "
                 + "per sentence once loaded, measured — the fastest of the downloadable engines, "
                 + "and it only ever translates, so it cannot wander off answering the speaker."
        case .qwen:
            return "A small local LLM doing the translation — about 1.2 seconds per "
                 + "sentence on the recommended 2B model, measured. Most flexible of the "
                 + "options, since it can be instructed about tone or terminology. "
                 + "Stay at 2B or above: the 0.8B model is fast but keeps answering or "
                 + "echoing the caption instead of translating it."
        }
    }

    /// Whisper is not a text translator at all: it replaces the recognition
    /// engine and emits English directly. Everything else post-processes text.
    var replacesRecognition: Bool { self == .whisper }

    /// Whisper's translate task has exactly one target.
    var englishOnly: Bool { self == .whisper }

    /// Licence of the MODEL WEIGHTS, which is what constrains shipping — the
    /// Swift packages are all permissive.
    var licence: String {
        switch self {
        case .apple: return "Apple system framework"
        case .whisper: return "MIT (model and package)"
        case .madlad: return "Apache-2.0"
        case .qwen: return "Apache-2.0 (most Qwen releases)"
        }
    }

    func makeTranslator() -> Translating? {
        switch self {
        case .apple: return AppleTranslator()
        case .whisper: return nil            // handled by swapping the ASR backend
        case .madlad: return MADLADTranslator()
        case .qwen: return QwenTranslator()
        }
    }

    /// This engine's registry entries. Plural because Qwen offers several model
    /// sizes, each a separate download.
    var assetDescriptors: [ModelAsset] {
        switch self {
        case .apple:
            return [ModelAsset(
                id: "mt.apple",
                family: .system,
                title: "Apple translation languages",
                detail: "Downloaded and removed by macOS, roughly 40–80 MB per language pair. "
                      + "The Translation framework exposes no removal API, so no app can delete these.",
                advertisedBytes: nil,
                storage: .opaque,
                removal: .systemOnly(
                    reason: "macOS manages translation languages. Remove them in Language & Region.",
                    route: .languageAndRegion),
                use: .never,
                install: nil)]

        case .whisper:
            return [ModelAsset(
                id: "mt.whisper",
                family: .translation,
                title: "Whisper large-v3",
                detail: summary,
                advertisedBytes: 2_900 * 1_048_576,
                storage: .directory(
                    WhisperTranslateBackend.modelsDirectory,
                    markers: ["models/argmaxinc/whisperkit-coreml/openai_whisper-large-v3/AudioEncoder.mlmodelc",
                              "models/argmaxinc/whisperkit-coreml/openai_whisper-large-v3/TextDecoder.mlmodelc",
                              "models/argmaxinc/whisperkit-coreml/openai_whisper-large-v3/MelSpectrogram.mlmodelc"]),
                removal: .remove(WhisperTranslateBackend.modelsDirectory),
                use: .whenTranslator(.whisper),
                install: { sink in try await WhisperTranslateBackend.downloadWeights(progress: sink) })]

        case .madlad:
            return [ModelAsset(
                id: "mt.madlad",
                family: .translation,
                title: "MADLAD-400-3B",
                detail: summary,
                advertisedBytes: 1_860 * 1_048_576,
                storage: .directory(
                    MADLADTranslator.modelsDirectory,
                    markers: ["int4/model.safetensors", "int4/tokenizer.json", "int4/config.json"]),
                removal: .remove(MADLADTranslator.modelsDirectory),
                use: .whenTranslator(.madlad),
                install: { sink in try await MADLADTranslator.downloadWeights(progress: sink) })]

        case .qwen:
            return QwenModel.all.map { m in
                ModelAsset(
                    id: "mt.qwen.\(m.file)",
                    family: .translation,
                    title: m.label,
                    detail: m.note,
                    advertisedBytes: m.bytes,
                    storage: .file(m.localURL, expectedBytes: m.bytes),
                    removal: .remove(m.localURL),
                    use: .whenQwenVariant(file: m.file),
                    install: { sink in
                        try await FileDownloader.download(from: m.downloadURL, to: m.localURL,
                                                          expectedBytes: m.bytes, progress: sink)
                    })
            }
        }
    }
}
