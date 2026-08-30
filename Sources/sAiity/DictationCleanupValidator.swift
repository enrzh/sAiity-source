import Foundation

enum DictationCleanupValidator {
    static func validate(_ value: String) -> String? {
        let text = value.trimmingCharacters(in: .whitespacesAndNewlines.union(.controlCharacters))
        guard !text.isEmpty, !text.contains("```") else { return nil }
        let prefixes = ["Here is", "Here's", "Cleaned transcript:", "Cleaned text:", "The cleaned transcript is:"]
        guard !prefixes.contains(where: { text.lowercased().hasPrefix($0.lowercased()) }) else { return nil }
        let paragraphs = text.components(separatedBy: "\n\n").filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        guard paragraphs.count <= 1 else { return nil }
        return text
    }
}
