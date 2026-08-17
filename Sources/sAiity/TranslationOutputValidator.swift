import Foundation
import NaturalLanguage

/// The last line of defence before model output reaches a caption.
///
/// A missing translation leaves the source caption intact. An invented answer,
/// an echo, or a response in the wrong language is worse, so every local LLM
/// translator uses the same verdict and retry policy.
enum TranslationOutputValidator {
    /// The languages `NLLanguageRecognizer` can identify reliably enough for a
    /// guard. Outside this set its answer is a guess, so the language check
    /// stands down rather than rejecting good long-tail translations.
    static let recognizableLanguages: Set<String> = [
        "am", "ar", "hy", "bn", "bg", "my", "ca", "cs", "zh", "hr", "da", "nl",
        "en", "fi", "fr", "ka", "de", "el", "gu", "he", "hi", "hu", "is", "id",
        "it", "ja", "kn", "km", "ko", "lo", "lv", "lt", "ml", "mr", "mn", "nb",
        "or", "fa", "pl", "pt", "pa", "ro", "ru", "sr", "si", "sk", "sl", "es",
        "sv", "ta", "te", "th", "bo", "tr", "uk", "ur", "vi",
    ]

    /// `retryable` marks a copied or wrong-language response that a second
    /// generation can plausibly fix. Empty or runaway output is not retried.
    enum Verdict {
        case ok(String)
        case rejected(why: String, retryable: Bool)
    }

    /// Strip common model wrappers, then reject output that is unsafe to show.
    static func sanitize(_ raw: String, input: String, target: String) -> Verdict {
        func reject(_ why: String, retryable: Bool = false) -> Verdict {
            .rejected(why: why, retryable: retryable)
        }

        var text = raw
        text = text.replacingOccurrences(of: "<think>[\\s\\S]*?</think>", with: "",
                                         options: .regularExpression)
        text = text.replacingOccurrences(of: "<think>[\\s\\S]*", with: "",
                                         options: .regularExpression)
        text = text.replacingOccurrences(of: "</?USER-INPUT>", with: "",
                                         options: .regularExpression)
        text = text.replacingOccurrences(of: "</?text>", with: "",
                                         options: .regularExpression)
        text = text.replacingOccurrences(
            of: "^\\s*(Translation|Übersetzung|Output)\\s*[:：]\\s*",
            with: "", options: [.regularExpression, .caseInsensitive])
        text = text.replacingOccurrences(of: "\\s*\\n+\\s*", with: " ",
                                         options: .regularExpression)
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.count > 2,
           (text.hasPrefix("\"") && text.hasSuffix("\""))
            || (text.hasPrefix("„") && text.hasSuffix("“")) {
            text = String(text.dropFirst().dropLast())
                .trimmingCharacters(in: .whitespaces)
        }

        guard !text.isEmpty, text != "..." else {
            return reject("empty")
        }
        let ratio = Double(text.count) / Double(max(input.count, 1))
        guard ratio > 0.15, ratio < 4.0 else {
            return reject(String(format: "length ratio %.2f", ratio))
        }
        if text.compare(input, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame {
            return reject("echoed input", retryable: true)
        }

        let wanted = target.split(separator: "-").first.map(String.init) ?? target
        if text.count >= 12, recognizableLanguages.contains(wanted) {
            let recognizer = NLLanguageRecognizer()
            recognizer.processString(text)
            if let language = recognizer.dominantLanguage?.rawValue {
                let received = language.split(separator: "-").first.map(String.init) ?? language
                guard received == wanted else {
                    return reject("got \(received), want \(wanted)", retryable: true)
                }
            }
        }
        return .ok(text)
    }
}
