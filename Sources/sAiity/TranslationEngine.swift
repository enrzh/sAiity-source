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

/// When translation happens.
///
/// Whole sentences is the default and the quality choice: the translator is
/// handed one finished thought, once. Live retranslates the still-growing
/// sentence on every committed clause, so a rough translation appears within a
/// couple of seconds and settles when the sentence closes — at the price of
/// several translator runs per sentence. Display-only: whatever mode is set,
/// the transcript records the one translation made at the close.
enum TranslationTiming: String, CaseIterable, Sendable {
    case sentence
    case live

    @Defaults(rawKey: "translationTiming") static var current: TranslationTiming = .sentence

    var displayName: String {
        switch self {
        case .sentence: return String(localized: "Whole sentences")
        case .live: return String(localized: "Live")
        }
    }
}

/// Which translator to use.
///
/// The ordering here is the honest recommendation order, and the summaries say
/// why — including for the opt-in specialist and the slower generic LLM path.
enum TranslationEngine: String, CaseIterable, Sendable, Codable {
    case madlad
    case hyMT2
    case qwen

    /// Keep the normal path deliberately small. The other engines remain
    /// available for users who knowingly want to trade certainty for a
    /// specialist or an experimental local LLM.
    static let primaryCases: [TranslationEngine] = [.madlad]
    static let advancedCases: [TranslationEngine] = [.hyMT2, .qwen]

    var isAdvanced: Bool { self != .madlad }

    /// The chosen translator, or nothing. Same reasoning as `ASREngine.selected`:
    /// defaulting to MADLAD badged a 1.86 GB model "in use" on a Mac that had
    /// never downloaded it and had translation switched off.
    @Defaults(optionalRawKey: "translationEngine") static var selected: TranslationEngine?

    /// Suggested when nothing is chosen: the measured fast path and the broad
    /// coverage default. Specialist and generic alternatives stay opt-in.
    static let recommended: TranslationEngine = .madlad

    /// The translator to build once one is needed. Guarded by `selected` at the
    /// point translation is switched on.
    static var effective: TranslationEngine { selected ?? recommended }

    var displayName: String {
        switch self {
        case .madlad: return String(localized: "MADLAD")
        case .hyMT2: return HyMT2Translator.displayName
        case .qwen: return String(localized: "Local LLM")
        }
    }

    var summary: String {
        switch self {
        case .madlad:
            return String(localized: "MADLAD-400-3B, a dedicated translation model on MLX. Best quality of the local options and Apache-2.0, so it can ship. 1.86 GB, and about 0.2 seconds per sentence once loaded, measured — the fastest of the downloadable engines, and it only ever translates, so it cannot wander off answering the speaker.")
        case .hyMT2:
            return String(localized: "Optional specialist for 37 languages. Keep it in Advanced until a language-pair benchmark shows it beats MADLAD for your use case.")
        case .qwen:
            return String(localized: "Experimental local LLM translation. Useful for cleanup and language experiments, but less predictable than a dedicated translation model. Choose a Qwen, Gemma, or custom GGUF under Advanced.")
        }
    }

    /// The weights' own terms. Shown per model on the Models page — this is the
    /// summary for the engine picker.
    ///
    /// Deliberately specific: "Apache-2.0" alone was doing a lot of work here,
    /// covering both a Google model and a set of community requantisations.
    var licence: String {
        switch self {
        case .madlad: return String(localized: "Apache-2.0 (Google MADLAD-400)")
        case .hyMT2: return String(localized: "Apache-2.0 (Tencent Hy-MT2)")
        case .qwen: return String(localized: "Per model — shown on each row under Models")
        }
    }

    func makeTranslator() -> Translating? {
        switch self {
        case .madlad: return MADLADTranslator()
        case .hyMT2: return HyMT2Translator()
        case .qwen: return LocalLLMTranslator()
        }
    }

    /// The registry id of the files this engine would load right now — nil
    /// for the LLM path when no model is selected, in which case there is no
    /// asset whose health could be in question.
    var activeAssetID: String? {
        switch self {
        case .madlad: return AssetID.madlad
        case .hyMT2: return AssetID.hyMT2
        case .qwen: return LocalModel.selected.map { AssetID.llm(file: $0.file) }
        }
    }

    /// This engine's registry entries. Plural because Qwen offers several model
    /// sizes, each a separate download.
    var assetDescriptors: [ModelAsset] {
        switch self {
        case .madlad:
            return [ModelAsset(
                id: AssetID.madlad,
                family: .translation,
                title: "MADLAD-400-3B",
                detail: summary,
                // Fastest of the downloadable translators, best quality, and
                // the only one that only ever translates.
                recommended: true,
                licence: "Apache-2.0 (Google MADLAD-400) · huggingface.co/aufklarer",
                advertisedBytes: 1_860 * 1_048_576,
                storage: .directory(
                    MADLADTranslator.modelsDirectory,
                    markers: ["int4/model.safetensors", "int4/tokenizer.json", "int4/config.json"]),
                removal: .remove(MADLADTranslator.modelsDirectory),
                use: .whenTranslator(.madlad),
                install: { sink in try await MADLADTranslator.downloadWeights(progress: sink) })]

        case .hyMT2:
            return [ModelAsset(
                id: AssetID.hyMT2,
                family: .translation,
                title: "Hy-MT2-1.8B Q4_K_M",
                detail: summary,
                recommended: false,
                licence: "Apache-2.0 (Tencent Hy-MT2)",
                advertisedBytes: HyMT2Translator.modelBytes,
                storage: .file(HyMT2Translator.localURL,
                               expectedBytes: HyMT2Translator.modelBytes),
                removal: .remove(HyMT2Translator.localURL),
                use: .whenTranslator(.hyMT2),
                install: { sink in try await HyMT2Translator.download(progress: sink) })]

        case .qwen:
            return LocalModel.all.map { m in
                ModelAsset(
                    id: AssetID.llm(file: m.file),
                    family: .translation,
                    title: m.label,
                    detail: m.note,
                    // The one line where the catalogue's own recommendation
                    // used to die on the way to the Models page.
                    recommended: m.recommended,
                    licence: m.licence,
                    advertisedBytes: m.bytes,
                    storage: .file(m.localURL, expectedBytes: m.bytes),
                    removal: .remove(m.localURL),
                    use: .whenQwenVariant(file: m.file),
                    // An imported file has nothing to download — it is already
                    // in place, so it gets no install path at all.
                    install: m.downloadURL.map { url in
                        let destination = m.localURL
                        let expectedBytes = m.bytes
                        return { @Sendable sink in
                            try await FileDownloader.download(from: url,
                                                              to: destination,
                                                              expectedBytes: expectedBytes,
                                                              requireMagic: FileDownloader.ggufMagic,
                                                              progress: sink)
                        }
                    })
            }
        }
    }
}
