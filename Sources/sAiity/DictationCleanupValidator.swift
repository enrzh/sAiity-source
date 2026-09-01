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

    /// A cleanup model must stay in the language that was spoken. Use the
    /// transcript's language classification first; ASR metadata is only a
    /// fallback for short, noisy, or long-tail-language input. Do not use the
    /// translation validator's finite allow-list here: cleanup is expected to
    /// preserve languages outside NaturalLanguage's supported set too.
    private static func languageWasPreserved(input: String,
                                             output: String,
                                             sourceLanguage: String?) -> Bool {
        // ASR language metadata can be stale after a model has been reused for
        // several sessions. The transcript itself is the safer comparison;
        // metadata is intentionally not authoritative here.
        let inputCode = detectedLanguage(in: input).flatMap(baseLanguage)
        let outputCode = detectedLanguage(in: output).flatMap(baseLanguage)
        if let inputCode, let outputCode {
            return inputCode == outputCode
        }

        // Very short or noisy transcripts may not be classified. In that case
        // use the ASR hint, but only after trying the transcript comparison.
        // This also covers a long-tail language that NaturalLanguage cannot
        // identify while it can still identify an English translation.
        if let expected = baseLanguage(sourceLanguage), let outputCode {
            return expected == outputCode
        }

        // A script mismatch is useful evidence even when neither language is
        // in NaturalLanguage's catalogue. It is deliberately one-way: shared
        // scripts (for example English and Swahili) do not prove equivalence,
        // so an unknown result remains allowed when no stronger evidence exists.
        if let inputScript = scriptFamily(in: input),
           let outputScript = scriptFamily(in: output) {
            return inputScript == outputScript
        }
        return true
    }

    private enum ScriptFamily {
        case latin, cyrillic, arabic, hebrew, devanagari, bengali, gurmukhi
        case gujarati, tamil, telugu, kannada, malayalam, thai, lao, khmer
        case myanmar, hangul, han, japaneseKana, ethiopic, georgian, armenian
        case greek
    }

    private static func scriptFamily(in text: String) -> ScriptFamily? {
        for scalar in text.unicodeScalars {
            let value = scalar.value
            switch value {
            case 0x0041...0x024F, 0x1E00...0x1EFF: return .latin
            case 0x0370...0x03FF, 0x1F00...0x1FFF: return .greek
            case 0x0400...0x052F: return .cyrillic
            case 0x0530...0x058F: return .armenian
            case 0x10A0...0x10FF, 0x2D00...0x2D2F: return .georgian
            case 0x0590...0x05FF: return .hebrew
            case 0x0600...0x06FF, 0x0750...0x077F, 0x08A0...0x08FF: return .arabic
            case 0x0900...0x097F: return .devanagari
            case 0x0980...0x09FF: return .bengali
            case 0x0A00...0x0A7F: return .gurmukhi
            case 0x0A80...0x0AFF: return .gujarati
            case 0x0B80...0x0BFF: return .tamil
            case 0x0C00...0x0C7F: return .telugu
            case 0x0C80...0x0CFF: return .kannada
            case 0x0D00...0x0D7F: return .malayalam
            case 0x0E00...0x0E7F: return .thai
            case 0x0E80...0x0EFF: return .lao
            case 0x1000...0x109F, 0xAA60...0xAA7F: return .myanmar
            case 0x1200...0x137F, 0x1380...0x139F: return .ethiopic
            case 0x1780...0x17FF: return .khmer
            case 0x1100...0x11FF, 0xAC00...0xD7AF: return .hangul
            case 0x3040...0x309F, 0x30A0...0x30FF, 0x31F0...0x31FF: return .japaneseKana
            case 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF: return .han
            default: continue
            }
        }
        return nil
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
