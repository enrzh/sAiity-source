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
    case madlad
    case qwen

    static var current: TranslationEngine {
        get { TranslationEngine(rawValue: UserDefaults.standard.string(forKey: "translationEngine") ?? "") ?? .apple }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "translationEngine") }
    }

    var displayName: String {
        switch self {
        case .apple: return "Apple"
        case .madlad: return "MADLAD"
        case .qwen: return "Qwen"
        }
    }

    var summary: String {
        switch self {
        case .apple:
            return "Runs on the Neural Engine — a sentence comes back in tens of milliseconds. "
                 + "~40–80 MB per language pair, any target language. The fastest option."
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

    /// The weights' own terms. Shown per model on the Models page — this is the
    /// summary for the engine picker.
    ///
    /// Deliberately specific: "Apache-2.0" alone was doing a lot of work here,
    /// covering both a Google model and a set of community requantisations.
    var licence: String {
        switch self {
        case .apple: return "Apple system framework — nothing to download from us"
        case .madlad: return "Apache-2.0 (Google MADLAD-400)"
        case .qwen: return "Apache-2.0 (Alibaba Qwen); GGUF builds by unsloth"
        }
    }

    func makeTranslator() -> Translating? {
        switch self {
        case .apple: return AppleTranslator()
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
                licence: "Apple system framework",
                advertisedBytes: nil,
                storage: .opaque,
                removal: .systemOnly(
                    reason: "macOS manages translation languages. Remove them in Language & Region.",
                    route: .languageAndRegion),
                use: .never,
                install: nil)]

        case .madlad:
            return [ModelAsset(
                id: "mt.madlad",
                family: .translation,
                title: "MADLAD-400-3B",
                detail: summary,
                licence: "Apache-2.0 (Google MADLAD-400) · huggingface.co/aufklarer",
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
                    licence: "Apache-2.0 (Qwen) · huggingface.co/unsloth",
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
