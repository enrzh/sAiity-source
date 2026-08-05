import Foundation

/// The Qwen builds worth offering, with real sizes read from HuggingFace.
///
/// All Apache-2.0, so any of them can ship. The 0.8B is listed because it is
/// genuinely fast, but it is marked unsuitable for translation on purpose: a
/// sub-billion instruct model produces translations bad enough to be worse than
/// no translation, and offering it without saying so would be a trap.
struct QwenModel: Identifiable, Sendable, Equatable {
    /// The repo, NOT the identity — Q4 and Q5 of the same size share it.
    let repo: String
    /// The GGUF filename, which IS unique. Used as `id`: keying Identifiable on
    /// the repo made SwiftUI treat the two 2B variants as one row and render it
    /// twice, both showing as selected.
    let file: String
    var id: String { file }
    let label: String
    let bytes: Int64
    let recommended: Bool
    let note: String

    var sizeText: String { ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file) }

    static let all: [QwenModel] = [
        QwenModel(repo: "unsloth/Qwen3.5-0.8B-GGUF", file: "Qwen3.5-0.8B-Q4_K_M.gguf",
                  label: "Qwen3.5 0.8B", bytes: 533 * 1_048_576, recommended: false,
                  note: "Fast, but too small for usable translation — it drops and invents meaning. Listed for completeness."),
        QwenModel(repo: "unsloth/Qwen3.5-2B-GGUF", file: "Qwen3.5-2B-Q4_K_M.gguf",
                  label: "Qwen3.5 2B", bytes: 1281 * 1_048_576, recommended: true,
                  note: "The smallest size whose translation quality holds up. A sensible default if you want an LLM doing this."),
        QwenModel(repo: "unsloth/Qwen3.5-2B-GGUF", file: "Qwen3.5-2B-Q5_K_M.gguf",
                  label: "Qwen3.5 2B (Q5)", bytes: 1435 * 1_048_576, recommended: false,
                  note: "Slightly better quality than Q4 for ~150 MB more."),
        QwenModel(repo: "unsloth/Qwen3.5-4B-GGUF", file: "Qwen3.5-4B-Q4_K_M.gguf",
                  label: "Qwen3.5 4B", bytes: 2741 * 1_048_576, recommended: false,
                  note: "Best quality of these, but roughly twice the time per sentence — likely too slow to keep up."),
    ]

    static var selected: QwenModel {
        get {
            let f = UserDefaults.standard.string(forKey: "qwenModelFile") ?? ""
            return all.first { $0.file == f } ?? all.first { $0.recommended }!
        }
        set { UserDefaults.standard.set(newValue.file, forKey: "qwenModelFile") }
    }

    static var directory: URL {
        ModelRegistry.root.appendingPathComponent("qwen", isDirectory: true)
    }

    var localURL: URL { Self.directory.appendingPathComponent(file) }

    /// Present AND close to its expected size. A truncated GGUF exists happily
    /// and then fails to load, which reads as "the model is broken" rather than
    /// "the download did not finish".
    var isDownloaded: Bool {
        guard let n = try? FileManager.default.attributesOfItem(atPath: localURL.path)[.size] as? Int
        else { return false }
        return Double(n) >= Double(bytes) * 0.98
    }

    /// Direct GGUF download. The HuggingFace resolve endpoint follows redirects
    /// to the CDN, which URLSession handles for us.
    var downloadURL: URL {
        URL(string: "https://huggingface.co/\(repo)/resolve/main/\(file)?download=true")!
    }
}
