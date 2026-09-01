import Foundation
import NaturalLanguage

enum DictationCleanupValidator {
    /// Applies the speech repairs that should never depend on a small local
    /// model following an instruction. Keep this deliberately conservative:
    /// semantic rewrites still belong to the cleanup model.
    static func deterministicCleanup(_ value: String) -> String {
        var text = value
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        text = replace(text,
                       pattern: #"(?i)(?<![\p{L}\p{N}])(?:um+|uh+|erm?|you know)(?![\p{L}\p{N}])[,;:]?\s*"#,
                       with: "")

        // ASR commonly repeats a word while the speaker is deciding what to
        // say. Repeat until stable so "please please please" is handled too.
        while true {
            let cleaned = replace(text,
                                  pattern: #"(?i)\b([[:alnum:]][[:alnum:]'’-]*)\s+\1\b"#,
                                  with: "$1")
            guard cleaned != text else { break }
            text = cleaned
        }

        // A proper-name correction is safe to resolve without a model. The
        // capitalization guard avoids deleting ordinary phrases such as
        // "the report, actually the revised report".
        text = replace(text,
                       pattern: #"\b([A-Z][A-Za-z'’-]*)\s*,\s*(?:actually|I mean|rather)\s+([A-Z][A-Za-z'’-]*)"#,
                       with: "$2")

        // Remove a spoken naming check while retaining the chosen name and
        // the sentence before it: "MrBeast? Yes, MrBeast is the name."
        text = replace(text,
                       pattern: #"(?i)\?\s+yes,\s+[^?!.]+\s+is\s+the\s+name\.?"#,
                       with: ".")

        text = replace(text, pattern: #"\s+([,.;!?])"#, with: "$1")
        text = replace(text, pattern: #"([,;:])\s*([,.])"#, with: "$1")
        text = replace(text,
                       pattern: #"(?i),\s+(?=(?:today|tomorrow|yesterday|now|tonight)\b)"#,
                       with: " ")
        if let first = text.first, first.isLowercase {
            text.replaceSubrange(text.startIndex...text.startIndex, with: String(first).uppercased())
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func validate(_ value: String,
                         preserving input: String? = nil,
                         sourceLanguage: String? = nil) -> String? {
        var text = value.trimmingCharacters(in: .whitespacesAndNewlines.union(.controlCharacters))
        guard !text.isEmpty, !text.contains("```") else { return nil }
        if let input, !isWrappedInQuotes(input), isWrappedInQuotes(text) {
            text = String(text.dropFirst().dropLast())
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        // LLM.swift uses these as its output when generation produced no text.
        // They are a transport sentinel, never a valid dictation result.
        let compact = text.replacingOccurrences(of: " ", with: "")
        guard compact != "...", compact != "…" else { return nil }
        let prefixes = ["Here is", "Here's", "Cleaned transcript:", "Cleaned text:", "The cleaned transcript is:"]
        guard !prefixes.contains(where: { text.lowercased().hasPrefix($0.lowercased()) }) else { return nil }
        let paragraphs = text.components(separatedBy: "\n\n").filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        guard paragraphs.count <= 1 else { return nil }
        if let input {
            let inputWords = words(in: input)
            let outputWords = words(in: text)
            if inputWords.count >= 8, outputWords.count < max(3, inputWords.count / 4) { return nil }
            if inputWords.count >= 4, outputWords.count > inputWords.count * 2 { return nil }
            guard protectedTokens(in: input).allSatisfy({ text.range(of: $0, options: .caseInsensitive) != nil }) else {
                return nil
            }
            guard languageWasPreserved(input: input, output: text, sourceLanguage: sourceLanguage) else {
                return nil
            }
        }
        return text
    }

    /// A cleanup model must stay in the language that was spoken. Match the
    /// existing translation guard's minimum length and known-language limits:
    /// short or long-tail/mixed-language utterances remain governed by the
    /// existing conservative token checks.
    private static func languageWasPreserved(input: String,
                                             output: String,
                                             sourceLanguage: String?) -> Bool {
        guard input.count >= 12,
              output.count >= 12,
              let expected = baseLanguage(sourceLanguage),
              TranslationOutputValidator.recognizableLanguages.contains(expected),
              let inputLanguage = detectedLanguage(in: input),
              baseLanguage(inputLanguage) == expected,
              let outputLanguage = detectedLanguage(in: output),
              let received = baseLanguage(outputLanguage),
              TranslationOutputValidator.recognizableLanguages.contains(received) else {
            return true
        }
        return received == expected
    }

    private static func detectedLanguage(in text: String) -> String? {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        return recognizer.dominantLanguage?.rawValue
    }

    private static func baseLanguage(_ value: String?) -> String? {
        guard let value else { return nil }
        return value.replacingOccurrences(of: "_", with: "-")
            .split(separator: "-")
            .first?
            .lowercased()
    }

    private static func replace(_ value: String, pattern: String, with template: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return value }
        let range = NSRange(value.startIndex..<value.endIndex, in: value)
        return regex.stringByReplacingMatches(in: value, range: range, withTemplate: template)
    }

    private static func words(in text: String) -> [Substring] {
        text.split { $0.isWhitespace || $0.isPunctuation }
    }

    private static func isWrappedInQuotes(_ text: String) -> Bool {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.count >= 2 else { return false }
        return (value.hasPrefix("\"") && value.hasSuffix("\""))
            || (value.hasPrefix("“") && value.hasSuffix("”"))
            || (value.hasPrefix("'") && value.hasSuffix("'"))
    }

    /// Numbers and URL/email tokens are cheap, high-value invariants. Names and
    /// ordinary capitalisation are intentionally not protected because sentence
    /// starts would make those rules reject normal punctuation cleanup.
    private static func protectedTokens(in input: String) -> [String] {
        let pattern = #"(?i)(?:https?://[^\s]+|www\.[^\s]+|[a-z0-9._%+\-]+@[a-z0-9.\-]+\.[a-z]{2,}|\d+)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(input.startIndex..<input.endIndex, in: input)
        return regex.matches(in: input, range: range).compactMap { match in
            guard let tokenRange = Range(match.range, in: input) else { return nil }
            return input[tokenRange].trimmingCharacters(in: .punctuationCharacters)
        }.filter { !$0.isEmpty }
    }
}
