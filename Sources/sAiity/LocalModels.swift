import Foundation

/// A GGUF model the local-LLM translator can run: a built-in from the curated
/// list, or one the user added themselves.
///
/// Built-ins were verified against HuggingFace with real requests — sizes are
/// exact Content-Length values, not guesses; a wrong entry is a row that 404s.
struct LocalModel: Identifiable, Sendable, Equatable, Codable {

    /// Where the weights come from.
    enum Source: Sendable, Equatable, Codable {
        /// A curated HuggingFace build: repo + filename.
        case huggingFace(repo: String, file: String)
        /// A direct URL the user pasted. Anything serving a GGUF works.
        case url(String)
        /// A `.gguf` the user picked from disk — copied into our models
        /// directory, because referencing it in place would break the moment
        /// its owner (Ollama's blob store, a Downloads clean-up) removed it,
        /// and would put bytes outside the registry's ownership.
        case importedFile
    }

    let source: Source
    /// The filename inside our models directory. Unique — it is the identity.
    let file: String
    var id: String { file }
    let label: String
    /// Nil for a pasted URL whose server sent no Content-Length. Everywhere
    /// this is consumed must treat nil as "unknown", never as zero — comparing
    /// a real size against zero is how a truncated file reads as complete.
    let bytes: Int64?
    let recommended: Bool
    let note: String
    /// The weights' terms. Custom models get "your own model" — we cannot know.
    let licence: String

    var sizeText: String {
        bytes.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? String(localized: "size unknown")
    }

    // MARK: - Built-ins

    static let builtIn: [LocalModel] = [
        LocalModel(source: .huggingFace(repo: "unsloth/Qwen3.5-0.8B-GGUF",
                                        file: "Qwen3.5-0.8B-Q4_K_M.gguf"),
                   file: "Qwen3.5-0.8B-Q4_K_M.gguf",
                   label: String(localized: "Qwen3.5 0.8B"), bytes: 533 * 1_048_576, recommended: false,
                   note: String(localized: "Fast, but too small for usable translation — it drops and invents meaning. Listed for completeness."),
                   licence: "Apache-2.0 (Alibaba Qwen) · huggingface.co/unsloth"),
        LocalModel(source: .huggingFace(repo: "unsloth/Qwen3.5-2B-GGUF",
                                        file: "Qwen3.5-2B-Q4_K_M.gguf"),
                   file: "Qwen3.5-2B-Q4_K_M.gguf",
                   label: String(localized: "Qwen3.5 2B"), bytes: 1281 * 1_048_576, recommended: true,
                   note: String(localized: "The smallest size whose translation quality holds up. A sensible first choice if you want an LLM doing this."),
                   licence: "Apache-2.0 (Alibaba Qwen) · huggingface.co/unsloth"),
        LocalModel(source: .huggingFace(repo: "unsloth/Qwen3.5-2B-GGUF",
                                        file: "Qwen3.5-2B-Q5_K_M.gguf"),
                   file: "Qwen3.5-2B-Q5_K_M.gguf",
                   label: String(localized: "Qwen3.5 2B (Q5)"), bytes: 1435 * 1_048_576, recommended: false,
                   note: String(localized: "Slightly better quality than Q4 for ~150 MB more."),
                   licence: "Apache-2.0 (Alibaba Qwen) · huggingface.co/unsloth"),
        LocalModel(source: .huggingFace(repo: "unsloth/Qwen3.5-4B-GGUF",
                                        file: "Qwen3.5-4B-Q4_K_M.gguf"),
                   file: "Qwen3.5-4B-Q4_K_M.gguf",
                   label: String(localized: "Qwen3.5 4B"), bytes: 2741 * 1_048_576, recommended: false,
                   note: String(localized: "Best quality of the Qwen sizes, but roughly twice the time per sentence — likely too slow to keep up."),
                   licence: "Apache-2.0 (Alibaba Qwen) · huggingface.co/unsloth"),
        // Gemma: repeatedly benchmarked as the strongest small translator, and
        // LLM.swift's template resolver recognises the family from the GGUF's
        // own metadata, so the chat framing is right without any code of ours.
        LocalModel(source: .huggingFace(repo: "unsloth/gemma-3-1b-it-GGUF",
                                        file: "gemma-3-1b-it-Q4_K_M.gguf"),
                   file: "gemma-3-1b-it-Q4_K_M.gguf",
                   label: String(localized: "Gemma 3 1B"), bytes: 806_058_272, recommended: false,
                   note: String(localized: "Google's small model — noticeably better at translation per parameter than same-size Qwen, and fast. Worth trying if 2B feels slow."),
                   licence: "Gemma Terms of Use (Google) · huggingface.co/unsloth"),
        LocalModel(source: .huggingFace(repo: "unsloth/gemma-3-4b-it-GGUF",
                                        file: "gemma-3-4b-it-Q4_K_M.gguf"),
                   file: "gemma-3-4b-it-Q4_K_M.gguf",
                   label: String(localized: "Gemma 3 4B"), bytes: 2_489_894_016, recommended: false,
                   note: String(localized: "The quality pick among the LLM options. About the speed of Qwen 4B; the prompt heuristics here were tuned on Qwen, so behaviour may differ slightly."),
                   licence: "Gemma Terms of Use (Google) · huggingface.co/unsloth"),
    ]

    // MARK: - Custom models

    private static let customKey = "customLLMModels"

    /// Models the user added, persisted as JSON — same idiom as CaptionStyle.
    static var custom: [LocalModel] {
        get {
            guard let d = UserDefaults.standard.data(forKey: customKey),
                  let m = try? JSONDecoder().decode([LocalModel].self, from: d) else { return [] }
            return m
        }
        set {
            if let d = try? JSONEncoder().encode(newValue) {
                UserDefaults.standard.set(d, forKey: customKey)
            }
        }
    }

    static var all: [LocalModel] { builtIn + custom }

    /// Register a model at a direct URL. The size comes from a HEAD request so
    /// completeness can be judged later; a server that sends no Content-Length
    /// yields nil, which downstream treats as unknown rather than zero.
    static func addCustom(url: URL) async throws -> LocalModel {
        var name = safeFilename(url.lastPathComponent)
        if !name.lowercased().hasSuffix(".gguf") { name += ".gguf" }
        name = uniqueFilename(name)

        var req = URLRequest(url: url)
        req.httpMethod = "HEAD"
        let (_, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw TranslationEngineError.notAvailable(
                String(localized: "That URL did not answer with a downloadable file (HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0))."))
        }
        // A 200 of type text/html is a model PAGE, not a model — the most
        // likely paste. Refusing it here, at add time, beats installing the
        // page as a .gguf that fails minutes later inside llama.cpp.
        if let type = http.value(forHTTPHeaderField: "Content-Type"),
           type.lowercased().contains("text/html") {
            throw TranslationEngineError.notAvailable(
                String(localized: "That URL answers with a web page, not a model file. Use the direct download link."))
        }
        let length = http.expectedContentLength > 0 ? http.expectedContentLength : nil

        let m = LocalModel(source: .url(url.absoluteString), file: name,
                           label: name.replacingOccurrences(of: ".gguf", with: ""),
                           bytes: length, recommended: false,
                           note: String(localized: "Added by URL. The translation prompt was tuned on Qwen; another family may behave differently."),
                           licence: String(localized: "Your own model — check its terms at the source"))
        custom = custom + [m]
        return m
    }

    /// Import a `.gguf` already on disk — which is what covers Ollama, whose
    /// blobs are GGUF but which publishes no download URLs. Copies via a
    /// staging name so an interrupted copy never leaves a plausible-looking
    /// complete file.
    static func addCustom(importing fileURL: URL) throws -> LocalModel {
        let size = (try? FileManager.default.attributesOfItem(
            atPath: fileURL.path)[.size] as? Int64) ?? 0
        guard size > 0 else {
            throw TranslationEngineError.notAvailable(String(localized: "That file is empty or unreadable."))
        }
        var name = safeFilename(fileURL.lastPathComponent)
        // Ollama blobs are named sha256-…; give them a usable extension.
        if !name.lowercased().hasSuffix(".gguf") { name += ".gguf" }
        name = uniqueFilename(name)

        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let dest = directory.appendingPathComponent(name)
        let staging = dest.appendingPathExtension("part")
        try? FileManager.default.removeItem(at: staging)
        try FileManager.default.copyItem(at: fileURL, to: staging)
        try FileManager.default.moveItem(at: staging, to: dest)

        let m = LocalModel(source: .importedFile, file: name,
                           label: name.replacingOccurrences(of: ".gguf", with: ""),
                           bytes: size, recommended: false,
                           note: String(localized: "Imported from \(fileURL.lastPathComponent). The translation prompt was tuned on Qwen; another family may behave differently."),
                           licence: String(localized: "Your own model — check its terms at the source"))
        custom = custom + [m]
        return m
    }

    /// Forget a custom model and delete its file. Built-ins cannot be removed
    /// from the list, only their downloads deleted.
    static func removeCustom(_ m: LocalModel) {
        custom.removeAll { $0.file == m.file }
        try? FileManager.default.removeItem(at: m.localURL)
        if UserDefaults.standard.string(forKey: "qwenModelFile") == m.file {
            UserDefaults.standard.removeObject(forKey: "qwenModelFile")
        }
    }

    /// Reduce anything that arrives as a "filename" to ONE path component.
    ///
    /// `URL.lastPathComponent` percent-DECODES, so a pasted custom-model URL
    /// ending in `a%2F..%2F..%2Fevil.gguf` yields `a/../../evil.gguf` — a name
    /// carrying separators and parent references. Joined onto the models
    /// directory that resolves outside it, and the downloader then creates
    /// directories and replaces files at that path in full trust. The user is
    /// the one pasting the URL, but "the link I was given wrote outside the
    /// app's folder" is not a thing this app gets to allow.
    static func safeFilename(_ raw: String) -> String {
        // Separators (both kinds — a colon is a path separator to the Finder)
        // and NUL become underscores; the result is then re-reduced to its
        // last component so no traversal survives, and a name that was only
        // dots is refused outright.
        var name = raw
        for bad in ["/", "\\", ":", "\0"] {
            name = name.replacingOccurrences(of: bad, with: "_")
        }
        name = (name as NSString).lastPathComponent
        if name.isEmpty || name.allSatisfy({ $0 == "." }) || name.hasPrefix(".") {
            name = "custom-model.gguf"
        }
        // Keep well under the 255-byte HFS+/APFS component limit while
        // leaving room for the ".part"/".etag" suffixes staging adds.
        if name.utf8.count > 200 {
            name = String(name.prefix(120)) + ".gguf"
        }
        return name
    }

    private static func uniqueFilename(_ name: String) -> String {
        var candidate = name
        var n = 2
        while all.contains(where: { $0.file == candidate }) {
            candidate = name.replacingOccurrences(of: ".gguf", with: "-\(n).gguf")
            n += 1
        }
        return candidate
    }

    // MARK: - Selection and paths

    /// The GGUF the user picked, or nothing.
    ///
    /// This used to force-unwrap the recommended built-in whenever nothing was
    /// stored, so a machine that had downloaded no GGUF at all still showed
    /// Qwen3.5 2B with its radio filled and its advertised size beside it —
    /// indistinguishable from an installed model, and a 1.25 GB surprise on the
    /// first Start. Nothing is chosen on the user's behalf now.
    ///
    /// An explicit choice is still honoured before its bytes arrive: the sheet
    /// is where you both choose and download, so un-choosing a model the moment
    /// it is picked would make the list impossible to use. What is gone is the
    /// invented choice.
    static var selected: LocalModel? {
        get {
            // The key keeps its historical name; renaming it would silently
            // reset every existing user's choice.
            guard let f = UserDefaults.standard.string(forKey: "qwenModelFile"),
                  !f.isEmpty else { return nil }
            // A stored file that is no longer in the catalogue reads as nothing
            // rather than as a substitute — a silent swap to a different model
            // is worse than an empty selection the user can see and fix.
            return all.first { $0.file == f }
        }
        set {
            if let newValue { UserDefaults.standard.set(newValue.file, forKey: "qwenModelFile") }
            else { UserDefaults.standard.removeObject(forKey: "qwenModelFile") }
        }
    }

    /// What to suggest when nothing is chosen. A suggestion, never a selection.
    static var suggested: LocalModel? { builtIn.first { $0.recommended } }

    static var directory: URL {
        ModelRegistry.root.appendingPathComponent("qwen", isDirectory: true)
    }

    var localURL: URL { Self.directory.appendingPathComponent(file) }

    /// Present and, when the expected size is known, close to it. Unknown-size
    /// models rely on the downloader's staging: the destination file only ever
    /// exists once a transfer completed, so presence alone is meaningful.
    var isDownloaded: Bool {
        guard let n = try? FileManager.default.attributesOfItem(atPath: localURL.path)[.size] as? Int
        else { return false }
        guard let expected = bytes else { return n > 0 }
        return Double(n) >= Double(expected) * 0.98
    }

    func isCleanupCompatible() -> Bool {
        isDownloaded && file.lowercased().hasSuffix(".gguf") &&
            [file, label].joined(separator: " ").lowercased().range(of: "qwen|gemma", options: .regularExpression) != nil
    }

    /// Where a download comes from. Nil for an imported file — it is already
    /// here, and "download" is meaningless for it.
    var downloadURL: URL? {
        switch source {
        case .huggingFace(let repo, let file):
            return URL(string: "https://huggingface.co/\(repo)/resolve/main/\(file)?download=true")
        case .url(let s):
            return URL(string: s)
        case .importedFile:
            return nil
        }
    }
}
