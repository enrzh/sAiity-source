import Foundation
import SaiityLLM

/// TranslateGemma's specialized translation path, separate from cleanup choices.
final class TranslateGemmaTranslator: Translating, TranslationLanguageProvider, @unchecked Sendable {
    let name = "TranslateGemma 4B"
    static let modelFile = "translategemma-4b-it.Q4_K_M.gguf"
    static let modelBytes: Int64 = 2_489_909_760
    static let modelSHA256 = "81200d03e843d2ec1ece6eeafe7d13cb6e5211e1fcd336ade55790b683a08330"
    static let revision = "b89d835d2f2b802f50f3a30f1f963c7c43de4723"
    static let downloadURL = URL(string: "https://huggingface.co/mradermacher/translategemma-4b-it-GGUF/resolve/\(revision)/\(modelFile)?download=true")!
    static var localURL: URL { ModelRegistry.root.appendingPathComponent("translategemma").appendingPathComponent(modelFile) }
    static var isDownloaded: Bool {
        (try? localURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) == Int(modelBytes)
    }
    // Public TranslateGemma report, WMT24++ table: declared variants, not measured app quality.
    private static let languageNames: [String: String] = [
        "en": "English", "en-US": "English", "en-GB": "English",
        "ar-EG": "Arabic", "ar-SA": "Arabic", "bg-BG": "Bulgarian", "bn-IN": "Bengali",
        "ca-ES": "Catalan", "cs-CZ": "Czech", "da-DK": "Danish", "de-DE": "German",
        "el-GR": "Greek", "es-MX": "Spanish", "et-EE": "Estonian", "fa-IR": "Persian",
        "fi-FI": "Finnish", "fil-PH": "Filipino", "fr-CA": "French", "fr-FR": "French",
        "gu-IN": "Gujarati", "he-IL": "Hebrew", "hi-IN": "Hindi", "hr-HR": "Croatian",
        "hu-HU": "Hungarian", "id-ID": "Indonesian", "is-IS": "Icelandic", "it-IT": "Italian",
        "ja-JP": "Japanese", "kn-IN": "Kannada", "ko-KR": "Korean", "lt-LT": "Lithuanian",
        "lv-LV": "Latvian", "ml-IN": "Malayalam", "mr-IN": "Marathi", "nl-NL": "Dutch",
        "no-NO": "Norwegian", "pa-IN": "Punjabi", "pl-PL": "Polish", "pt-BR": "Portuguese",
        "pt-PT": "Portuguese", "ro-RO": "Romanian", "ru-RU": "Russian", "sk-SK": "Slovak",
        "sl-SI": "Slovenian", "sr-RS": "Serbian", "sv-SE": "Swedish", "sw-KE": "Swahili",
        "sw-TZ": "Swahili", "ta-IN": "Tamil", "te-IN": "Telugu", "th-TH": "Thai",
        "tr-TR": "Turkish", "uk-UA": "Ukrainian", "ur-PK": "Urdu", "vi-VN": "Vietnamese",
        "zh-CN": "Chinese", "zh-TW": "Chinese", "zu-ZA": "Zulu"
    ]
    static let canonicalCodes: Set<String> = Set(languageNames.keys).union(
        languageNames.keys.map { TranslationLanguage.baseCode($0) }).union(["zh-Hans", "zh-Hant"])
    static func supportedCanonicalCodes() async -> Set<String> { canonicalCodes }
    static func nativeCode(for canonical: String) -> String? {
        let normalized = canonical.replacingOccurrences(of: "_", with: "-")
        if let exact = languageNames.keys.first(where: { $0.caseInsensitiveCompare(normalized) == .orderedSame }) { return exact }
        switch normalized.lowercased() {
        case "zh-hans", "zh": return "zh-CN"
        case "zh-hant": return "zh-TW"
        case "pt": return "pt-PT"
        case "fr": return "fr-FR"
        case "ar": return "ar-SA"
        case "sw": return "sw-KE"
        default:
            guard !normalized.contains("-") else { return nil }
            return languageNames.keys.sorted().first { TranslationLanguage.baseCode($0) == normalized.lowercased() }
        }
    }
    static func prompt(_ text: String, source: String, target: String) -> String? {
        guard let sourceCode = nativeCode(for: source), let targetCode = nativeCode(for: target),
              let sourceName = languageNames[sourceCode], let targetName = languageNames[targetCode] else { return nil }
        // Figure 3 in the official report; only source/target names and exact input are substituted.
        return "You are a professional \(sourceName) (\(sourceCode)) to \(targetName) (\(targetCode)) translator. Your goal is to accurately convey the meaning and nuances of the original \(sourceName) text while adhering to \(targetName) grammar, vocabulary, and cultural sensitivities. Produce only the \(targetName) translation, without any additional explanations or commentary. Please translate the following \(sourceName) text into \(targetName):\n\n\n\(text)"
    }
    static func download(progress: @escaping ProgressSink) async throws {
        try await FileDownloader.download(from: downloadURL, to: localURL, expectedBytes: modelBytes,
            requireMagic: FileDownloader.ggufMagic, expectedSHA256: modelSHA256, progress: progress)
    }
    private var model: LLM?
    private let flightLock = NSLock()
    private var inFlight = false
    func prepare(from source: String, to target: String, progress: @escaping @Sendable (String) -> Void) async throws {
        try LocalGeneration.checkDeadline()
        guard Self.nativeCode(for: target) != nil else { throw TranslationEngineError.notAvailable(String(localized: "TranslateGemma does not support that language variant.")) }
        guard Self.isDownloaded else { throw TranslationEngineError.notAvailable(String(localized: "Download TranslateGemma in Models before using it.")) }
        if model != nil { return }
        let url = Self.localURL
        model = try await LocalGeneration.loadModel {
            let task = Task.detached(priority: .userInitiated) {
                LLM(from: url, template: .gemma, temp: 0, maxTokenCount: 2048)
            }
            let loaded = await task.value
            guard let loaded else { throw BackendError.notPrepared }
            loaded.postprocess = { _ in }
            loaded.update = { _ in }
            return loaded
        }
        progress(String(localized: "TranslateGemma ready."))
    }
    func translate(_ text: String, from source: String, to target: String) async throws -> String? {
        try LocalGeneration.checkDeadline()
        let knownSource = Self.nativeCode(for: source) == nil
            ? LanguageDetector.sourceLanguage(in: text, hint: source) ?? source : source
        guard let model, let prompt = Self.prompt(text, source: knownSource, target: target) else { return nil }
        guard flightLock.withLock({ if inFlight { return false }; inFlight = true; return true }) else { return nil }
        defer { flightLock.withLock { inFlight = false } }
        model.history = []
        guard let output = try await LocalGeneration.run(model, user: prompt, payload: text) else { return nil }
        switch TranslationOutputValidator.sanitize(output, input: text, target: target, source: knownSource) {
        case .ok(let valid): return valid
        case .rejected: return nil
        }
    }
    func stop() async {
        let outgoing = model
        model = nil
        await outgoing?.core.waitForGeneration()
        MemoryPolicy.releaseCaches()
    }
}
