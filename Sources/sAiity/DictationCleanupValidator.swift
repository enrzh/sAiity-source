import Foundation

enum DictationCleanupValidator {
    static func validate(_ value: String) -> String? {
        let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.count <= 20_000 else { return nil }
        let lower = text.lowercased()
        for marker in ["<|system|>", "<|user|>", "<|assistant|>", "assistant:", "user:"] {
            if lower.contains(marker) { return nil }
        }
        return text
    }
}
