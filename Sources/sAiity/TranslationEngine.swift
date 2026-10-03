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
    /// Nil means the model *declined* — nothing to translate, or it produced
    /// nothing usable for this line. That is routine: the caller keeps the
    /// original line and leaves the engine loaded.
    ///
    /// A throw means the engine itself failed — a native error, not a quiet
    /// answer. These two used to be the same thing, because this returned a
    /// non-throwing `String?` and every implementation ended in `try?`. So a
    /// Metal allocation failure, a decode error, or an MLX abort surfaced as
    /// "the model declined to translate this line", which is the opposite of
    /// what happened and reads to the user exactly like a model refusing.
    ///
    /// It also made the two callers disagree about the same nil: the caption
    /// path kept the translator loaded forever while the status line claimed
    /// translation was running, and the dictation path retired the engine on
    /// the first line the model legitimately declined. Retiring MADLAD is
    /// terminal — `TranslationRuntimeFallback` has no fallback to offer — so
    /// both outcomes ended with translation silently dead.
    func translate(_ text: String, from source: String, to target: String) async throws -> String?
    /// Optional one-call path for several independent regions. Engines that do
    /// not support strict markers return nil, and a malformed marker response is
    /// also nil — the caller falls back to the sequential path for both. A
    /// throw keeps its meaning: the engine failed.
    func translateRegions(_ regions: [TranslationRegion], to target: String) async throws -> [String]?
    func stop() async
}

extension Translating {
    func translateRegions(_ regions: [TranslationRegion], to target: String) async throws -> [String]? {
        nil
    }
}

/// A source span passed to a translator without flattening code-switched text
/// into one misleading source-language claim.
struct TranslationRegion: Equatable, Sendable {
    let text: String
    let source: String
}

/// Shared by captions and dictation. Unknown or mixed source text must reach
/// automatic translation; one source-language hint cannot skip an entire line.
enum TranslationProcedure {
    static func isAlreadyInTarget(_ text: String, target: String) -> Bool {
        // A high-confidence dominant reading can hide a short foreign word
        // ("Can you bitte send it today?"). Such words must reach translation.
        let protected = DictationVocabulary.termsPresent(in: text)
        let words = text.split(whereSeparator: { !$0.isLetter }).map(String.init)
        if words.contains(where: { word in
            guard word.count >= 4, !protected.contains(word),
                  let reading = LanguageRecognizerPool.shared.classify(word), reading.probability >= 0.9 else { return false }
            return !TranslationLanguage.isSame(reading.language.rawValue, as: target)
        }) { return false }
        let spans = CaptionLanguageSpanDetector.analyze(text)
        guard !spans.isEmpty, !CaptionLanguageSpanDetector.isMixed(spans),
              let reading = LanguageRecognizerPool.shared.classify(text), reading.probability >= 0.9,
              TranslationLanguage.isSame(reading.language.rawValue, as: target) else { return false }
        return spans.allSatisfy { TranslationLanguage.isSame($0.language ?? "und", as: target) }
    }

    static func translate(_ regions: [TranslationRegion], to target: String,
                          engine: any Translating) async throws -> String? {
        var output = Array<String?>(repeating: nil, count: regions.count)
        var pending: [Int] = []
        for index in regions.indices {
            if isAlreadyInTarget(regions[index].text, target: target) { output[index] = regions[index].text }
            else { pending.append(index) }
        }
        if pending.count > 1,
           let batch = try await engine.translateRegions(pending.map { regions[$0] }, to: target),
           batch.count == pending.count {
            for (index, text) in zip(pending, batch) where !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                output[index] = text
            }
        }
        for index in pending where output[index] == nil {
            try Task.checkCancellation()
            let region = regions[index]
            guard let text = try await engine.translate(region.text, from: region.source, to: target),
                  !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                NSLog("sAiity translation: incomplete region output, original preserved")
                return nil
            }
            output[index] = text
        }
        try Task.checkCancellation()
        return regions.isEmpty ? nil : output.compactMap { $0 }.reduce("") { CaptionTextMerger.concatenate($0, $1) }
    }
}

/// Marker framing for a batched native translation. The parser is deliberately
/// strict: a malformed or reordered response is a batch miss, never a reason
/// to put marker text on the user's clipboard.
enum TranslationBatchMarkers {
    private static let prefix = "<sAiity-translation-region-"

    static func encode(_ regions: [TranslationRegion]) -> String? {
        guard regions.count > 1 else { return nil }
        guard !regions.contains(where: { $0.text.contains(prefix) }) else { return nil }
        return regions.enumerated().map { index, region in
            "\(marker(index))\n\(region.text.trimmingCharacters(in: .whitespacesAndNewlines))\n"
        }.joined()
    }

    static func decode(_ raw: String, count: Int) -> [String]? {
        guard count > 1 else { return nil }
        let whole = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard whole.hasPrefix(marker(0)) else { return nil }

        var result: [String] = []
        result.reserveCapacity(count)
        for index in 0..<count {
            let current = marker(index)
            guard let currentRange = whole.range(of: current) else { return nil }
            let contentStart = currentRange.upperBound
            let contentEnd: String.Index
            if index + 1 < count {
                guard let nextRange = whole.range(of: marker(index + 1),
                                                  range: contentStart..<whole.endIndex) else {
                    return nil
                }
                contentEnd = nextRange.lowerBound
            } else {
                contentEnd = whole.endIndex
            }
            let value = whole[contentStart..<contentEnd]
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty,
                  !value.contains(prefix),
                  !value.contains("<sAiity-translation-region-") else { return nil }
            result.append(String(value))
        }
        return result.count == count ? result : nil
    }

    private static func marker(_ index: Int) -> String {
        prefix + String(index) + ">"
    }
}

/// Compares language identity without treating a regional/script variant as a
/// different translation pair. Translation engines should never be called for
/// a region that already is in the requested target language: besides wasting
/// time, some local engines can fail on that path when their Metal runtime is
/// unavailable.
enum TranslationLanguage {
    static func baseCode(_ code: String) -> String {
        code.replacingOccurrences(of: "_", with: "-")
            .split(separator: "-")
            .first?
            .lowercased() ?? ""
    }

    static func isSame(_ source: String?, as target: String) -> Bool {
        guard let source else { return false }
        let sourceCode = baseCode(source)
        let targetCode = baseCode(target)
        guard !sourceCode.isEmpty, !targetCode.isEmpty else { return false }
        return sourceCode != "auto" && sourceCode == targetCode
    }
}

/// Native MLX/llama calls are not safe to overlap, even when they belong to
/// different Swift tasks. Keep one FIFO gate for every translation operation so
/// a live caption cannot enter while dictation is loading or decoding.
actor TranslationInferenceGate {
    private var tail: Task<Void, Never>?

    func run<T: Sendable>(_ operation: @escaping @Sendable () async throws -> T) async throws -> T {
        let previous = tail
        let queuedAt = ContinuousClock.now
        let current = Task { () throws -> T in
            await previous?.value
            try Task.checkCancellation()
            let waited = queuedAt.duration(to: .now).components
            Task { @MainActor in
                Diagnostics.recordTiming(operation: "translator.gate-wait",
                    seconds: Double(waited.seconds) + Double(waited.attoseconds) / 1e18, cold: false)
            }
            return try await operation()
        }
        tail = Task {
            _ = try? await current.value
        }
        // Cancellation skips queued work, but never releases the gate before an
        // already-running native operation drains safely.
        return try await withTaskCancellationHandler {
            let value = try await current.value
            try Task.checkCancellation()
            return value
        } onCancel: {
            current.cancel()
        }
    }
}

/// When translation happens.
///
/// Whole sentences translates a finished thought once. Live coalesces interim
/// words into revisable subtitle translations while speech continues. Saved
/// transcripts always receive the authoritative translation at sentence close.
enum TranslationTiming: String, CaseIterable, Sendable {
    case sentence
    case live

    @Defaults(rawKey: "translationTiming") static var current: TranslationTiming = .sentence

    var displayName: String {
        switch self {
        case .sentence: return String(localized: "Whole sentences")
        case .live: return String(localized: "Realtime")
        }
    }
}

/// Which translator to use.
///
/// MADLAD is the recommendation; Hy-MT2 is a selectable alternative. The raw
/// local-LLM case remains internal for old preferences and cleanup models.
enum TranslationEngine: String, CaseIterable, Sendable, Codable {
    case madlad
    case hyMT2
    case qwen

    /// MADLAD and Hy-MT2 are the user-facing translation catalogue. The local
    /// LLM case below remains representable only for old raw preferences and
    /// cleanup compatibility; it is intentionally absent from `allCases`.
    static var allCases: [TranslationEngine] { [.madlad, .hyMT2] }

    /// Keep the normal path deliberately small. The other engines remain
    /// available internally for old preferences and cleanup compatibility, but
    /// never enter a product picker.
    static let primaryCases: [TranslationEngine] = [.madlad]
    /// Not a fallback and not a default: a second opinion for the 37 languages
    /// Hy-MT2 was trained on, at 40% less disk than MADLAD. It covers far fewer
    /// languages, so it belongs behind the advanced disclosure rather than
    /// beside the recommended engine.
    static let advancedCases: [TranslationEngine] = [.hyMT2]
    /// The engines a user may pick. MADLAD for coverage, Hy-MT2 for the
    /// languages it specialises in. The legacy LLM case remains available
    /// internally for old preferences and cleanup compatibility, but never
    /// appears in a picker.
    static let userSelectableCases: [TranslationEngine] = [.madlad, .hyMT2]

    static func visibleSelection(_ engine: TranslationEngine?) -> TranslationEngine? {
        guard let engine, userSelectableCases.contains(engine) else { return nil }
        return engine
    }

    var isAdvanced: Bool { self != .madlad }

    /// The chosen translator, or nothing. Same reasoning as `ASREngine.selected`:
    /// defaulting to MADLAD badged a 1.86 GB model "in use" on a Mac that had
    /// never downloaded it and had translation switched off. Legacy Hy-MT2 and
    /// local-LLM preferences normalize to no selection.
    static var selected: TranslationEngine? {
        get {
            visibleSelection(UserDefaults.standard.string(forKey: "translationEngine")
                .flatMap(TranslationEngine.init(rawValue:)))
        }
        set {
            if let value = visibleSelection(newValue) {
                UserDefaults.standard.set(value.rawValue, forKey: "translationEngine")
            } else {
                UserDefaults.standard.removeObject(forKey: "translationEngine")
            }
        }
    }

    /// Dictation can use a different local model than captions. Keep this
    /// optional so existing installations continue following their captions
    /// choice until a dedicated dictation engine is selected.
    static var dictationSelected: TranslationEngine? {
        get {
            visibleSelection(UserDefaults.standard.string(forKey: "dictationTranslationEngine")
                .flatMap(TranslationEngine.init(rawValue:)))
        }
        set {
            if let value = visibleSelection(newValue) {
                UserDefaults.standard.set(value.rawValue, forKey: "dictationTranslationEngine")
            } else {
                UserDefaults.standard.removeObject(forKey: "dictationTranslationEngine")
            }
        }
    }

    /// Suggested when nothing is chosen: the measured fast path and the broad
    /// coverage default. Legacy alternatives are compatibility-only.
    static let recommended: TranslationEngine = .madlad

    /// The translator to build once one is needed. Guarded by `selected` at the
    /// point translation is switched on.
    static var effective: TranslationEngine {
        visibleSelection(selected) ?? recommended
    }

    /// Preserve existing behavior when no dedicated dictation choice exists.
    static var dictationEffective: TranslationEngine {
        visibleSelection(dictationSelected ?? selected) ?? recommended
    }

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
            return String(localized: "Hy-MT2-1.8B, a translation specialist that runs on CPU. A second opinion for the 37 languages it was trained on, at 1.1 GB instead of 1.9 GB. Fewer languages than MADLAD, so reach for it when you want the smaller download or prefer its phrasing.")
        case .qwen:
            return String(localized: "Experimental local LLM translation. Useful for cleanup and language experiments, but less predictable than a dedicated translation model. Choose a Qwen, Gemma, or custom GGUF in Models.")
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
        case .qwen: return LocalModel.cleanupSelected.map { AssetID.llm(file: $0.file) }
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
                    family: .cleanup,
                    title: m.label,
                    detail: m.note,
                    // The one line where the catalogue's own recommendation
                    // used to die on the way to the Models page.
                    recommended: m.recommended,
                    licence: m.licence,
                    advertisedBytes: m.bytes,
                    storage: .file(m.localURL, expectedBytes: m.bytes),
                    removal: .remove(m.localURL),
                    use: .whenCleanupModel(file: m.file),
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
