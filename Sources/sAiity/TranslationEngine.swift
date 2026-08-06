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
    case madlad
    case qwen

    @Defaults(rawKey: "translationEngine") static var current: TranslationEngine = .madlad

    var displayName: String {
        switch self {
        case .madlad: return "MADLAD"
        case .qwen: return "Local LLM"
        }
    }

    var summary: String {
        switch self {
        case .madlad:
            return "MADLAD-400-3B, a dedicated translation model on MLX. Best quality of the "
                 + "local options and Apache-2.0, so it can ship. 1.86 GB, and about 0.2 seconds "
                 + "per sentence once loaded, measured — the fastest of the downloadable engines, "
                 + "and it only ever translates, so it cannot wander off answering the speaker."
        case .qwen:
            return "A small local LLM doing the translation — about 1.2 seconds per "
                 + "sentence on the recommended Qwen 2B, measured. Most flexible of the "
                 + "options: choose from Qwen and Gemma builds, or add your own GGUF by "
                 + "URL or from disk. Stay at 2B-class or above; sub-billion models keep "
                 + "answering or echoing the caption instead of translating it."
        }
    }

    /// The weights' own terms. Shown per model on the Models page — this is the
    /// summary for the engine picker.
    ///
    /// Deliberately specific: "Apache-2.0" alone was doing a lot of work here,
    /// covering both a Google model and a set of community requantisations.
    var licence: String {
        switch self {
        case .madlad: return "Apache-2.0 (Google MADLAD-400)"
        case .qwen: return "Per model — shown on each row under Models"
        }
    }

    func makeTranslator() -> Translating? {
        switch self {
        case .madlad: return MADLADTranslator()
        case .qwen: return LocalLLMTranslator()
        }
    }

    /// This engine's registry entries. Plural because Qwen offers several model
    /// sizes, each a separate download.
    var assetDescriptors: [ModelAsset] {
        switch self {
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
            return LocalModel.all.map { m in
                ModelAsset(
                    id: "mt.llm.\(m.file)",
                    family: .translation,
                    title: m.label,
                    detail: m.note,
                    licence: m.licence,
                    advertisedBytes: m.bytes,
                    storage: .file(m.localURL, expectedBytes: m.bytes),
                    removal: .remove(m.localURL),
                    use: .whenQwenVariant(file: m.file),
                    // An imported file has nothing to download — it is already
                    // in place, so it gets no install path at all.
                    install: m.downloadURL.map { url in
                        { sink in
                            try await FileDownloader.download(from: url, to: m.localURL,
                                                              expectedBytes: m.bytes, progress: sink)
                        }
                    })
            }
        }
    }
}
