import Foundation
import LLM

/// Tencent Hy-MT2-1.8B Q4_K_M, used as an opt-in translation specialist.
///
/// The model card's GGUF uses Hunyuan role markers rather than ChatML. Keeping
/// the template here, next to the model lifecycle, prevents the generic Qwen
/// path from silently feeding it the wrong framing.
final class HyMT2Translator: Translating, @unchecked Sendable {
    static let displayName = "Hy-MT2"
    let name = "Hy-MT2 (translation specialist)"

    static let modelBytes: Int64 = 1_133_080_448
    static let modelFile = "Hy-MT2-1.8B-Q4_K_M.gguf"
    static let downloadURL = URL(string: "https://huggingface.co/tencent/Hy-MT2-1.8B-GGUF/resolve/main/Hy-MT2-1.8B-Q4_K_M.gguf?download=true")!
    static let generationTemperature: Float = 0.1
    static let retryTemperature: Float = 0.15

    static var modelsDirectory: URL {
        ModelRegistry.root.appendingPathComponent("hymt2", isDirectory: true)
    }

    static var localURL: URL {
        modelsDirectory.appendingPathComponent(modelFile)
    }

    /// Hy-MT2 has no default system prompt. These are the exact special tokens
    /// documented for its user, assistant, and end-of-turn framing.
    static let template = Template(
        prefix: "<｜hy_begin▁of▁sentence｜>",
        user: ("<｜hy_User｜>", "<｜hy_EOT｜>"),
        bot: ("<｜hy_Assistant｜>", "<｜hy_EOT｜>"),
        stopSequence: "<｜hy_EOT｜>",
        systemPrompt: nil)

    static func prompt(targetName: String, source: String) -> String {
        template.preprocess(instruction(targetName: targetName, source: source),
                            [], .none)
    }

    private static func instruction(targetName: String, source: String) -> String {
        """
        Translate into \(targetName). Output only the translation, with no explanation, label, or answer to the speaker.
        <SOURCE>
        \(source)
        </SOURCE>
        """
    }

    static func retryPrompt(targetName: String, source: String) -> String {
        """
        Translate the source text into \(targetName). The previous response was invalid. Output only the translation.
        <SOURCE>
        \(source)
        </SOURCE>
        """
    }

    static func download(progress: @escaping ProgressSink) async throws {
        try await FileDownloader.download(
            from: downloadURL,
            to: localURL,
            expectedBytes: modelBytes,
            requireMagic: FileDownloader.ggufMagic,
            progress: progress)
    }

    private var llm: LLM?

    func prepare(from _: String, to target: String,
                 progress: @escaping @Sendable (String) -> Void) async throws {
        guard HyMT2LanguageProvider.nativeCode(for: target) != nil else {
            throw TranslationEngineError.notAvailable(
                String(localized: "\(Self.displayName) cannot translate into \(AppLanguage(code: target).displayName)."))
        }

        if !Self.isDownloaded {
            progress(String(localized: "Downloading \(Self.displayName)…"))
            try await DownloadCoordinator.shared.run(AssetID.hyMT2) {
                try await Self.download { p in
                    if let fraction = p.fraction {
                        progress(String(localized: "Downloading \(Self.displayName)… \(Int(fraction * 100))%"))
                    } else {
                        progress(String(localized: "Downloading \(Self.displayName)…"))
                    }
                }
            }
        }

        progress(String(localized: "Loading \(Self.displayName)…"))
        let url = Self.localURL
        let loaded: LLM? = await Task.detached(priority: .userInitiated) {
            guard let model = LLM(
                from: url,
                template: Self.template,
                topK: 20,
                topP: 0.6,
                temp: Self.generationTemperature,
                repeatPenalty: 1.05,
                maxTokenCount: 2048) else {
                return nil
            }
            model.postprocess = { _ in }
            model.update = { _ in }
            return model
        }.value

        guard let loaded else {
            throw TranslationEngineError.notAvailable(
                String(localized: "Could not load \(Self.displayName)."))
        }
        llm = loaded
        progress(String(localized: "\(Self.displayName) ready."))
    }

    private let flightLock = NSLock()
    private var inFlight = false

    private func generate(_ input: String, temperature: Float? = nil) async -> String? {
        guard let llm else { return nil }
        llm.history = []
        llm.temp = temperature ?? Self.generationTemperature
        await llm.respond(to: input, thinking: .none)
        return llm.output
    }

    func translate(_ text: String, from _: String, to target: String) async -> String? {
        guard llm != nil,
              let targetName = HyMT2LanguageProvider.nativeCode(for: target) else {
            return nil
        }

        let busy = flightLock.withLock { () -> Bool in
            if inFlight { return true }
            inFlight = true
            return false
        }
        if busy { return nil }
        defer { flightLock.withLock { inFlight = false } }

        let user = Self.instruction(targetName: targetName, source: text)
        guard let raw = await generate(user) else { return nil }
        switch TranslationOutputValidator.sanitize(raw, input: text, target: target) {
        case .ok(let output):
            return output
        case .rejected(let why, let retryable):
            NSLog("sAiity hy-mt2: rejected (\(why)), \(raw.count) chars")
            guard retryable else { return nil }

            let retry = Self.retryPrompt(targetName: targetName, source: text)
            guard let rawRetry = await generate(retry, temperature: Self.retryTemperature),
                  case .ok(let output) = TranslationOutputValidator.sanitize(
                    rawRetry, input: text, target: target) else {
                return nil
            }
            return output
        }
    }

    func stop() async {
        llm = nil
    }

    private static var isDownloaded: Bool {
        let size = (try? FileManager.default.attributesOfItem(atPath: localURL.path)[.size] as? Int) ?? 0
        return Int64(size) == modelBytes
    }
}
