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
        text = text.replacingOccurrences(of: "[ \\t]+", with: " ",
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
        guard ratio >= 0.05, ratio < 5.0 else {
            return reject(String(format: "length ratio %.2f", ratio))
        }
        let echo = text.compare(input, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
        if echo && !permitsEcho(input, target: target) && !TranslationProcedure.isAlreadyInTarget(input, target: target) {
            return reject("echoed input", retryable: true)
        }

        guard numbers(in: input).isSubset(of: numbers(in: text)) else {
            return reject("changed numeric content")
        }

        let wanted = target.split(separator: "-").first.map(String.init) ?? target
        if !echo, text.count >= 24, recognizableLanguages.contains(wanted),
           let reading = LanguageRecognizerPool.shared.classify(text), reading.probability >= 0.95 {
                let language = reading.language.rawValue
                let received = language.split(separator: "-").first.map(String.init) ?? language
                guard received == wanted else {
                    return reject("got \(received), want \(wanted)", retryable: true)
                }
        }
        return .ok(text)
    }

    private static let expressions = RegexCache()

    private static func permitsEcho(_ input: String, target: String) -> Bool {
        let value = input.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
        if value.lowercased() == "ok" { return true }
        if value.lowercased() == "no", ["en", "es", "it"].contains(TranslationLanguage.baseCode(target)) { return true }
        if DictationVocabulary.termsPresent(in: input).contains(value) { return true }
        if value.first?.isUppercase == true, !value.contains(where: { $0.isWhitespace }) {
            let tagger = NLTagger(tagSchemes: [.nameType])
            tagger.string = value
            if tagger.tag(at: value.startIndex, unit: .word, scheme: .nameType).0 == .personalName { return true }
        }
        let pattern = #"^(?:[A-Z0-9_./+\-]+|[A-Za-z]*[a-z][A-Z][A-Za-z]*|https?://\S+|[^\s]+@[^\s]+)$"#
        guard let regex = expressions.expression(for: pattern) else { return false }
        return regex.firstMatch(in: value, range: NSRange(value.startIndex..<value.endIndex, in: value)) != nil
    }

    private static func numbers(in value: String) -> Set<String> {
        guard let regex = expressions.expression(for: #"[+\-]?\p{Nd}+(?:[.,]\p{Nd}+)*"#) else { return [] }
        let range = NSRange(value.startIndex..<value.endIndex, in: value)
        return Set(regex.matches(in: value, range: range).compactMap { match in
            guard let span = Range(match.range, in: value) else { return nil }
            return value[span].map { character in
                character.wholeNumberValue.map(String.init) ?? (character == "+" || character == "-" ? String(character) : "")
            }.joined()
        })
    }
}
