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
    static func sanitize(_ raw: String, input: String, target: String, source: String? = nil) -> Verdict {
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

        // Model-native Chinese targets may name only the base language. ICU
        // converts the requested writing system without promising regional wording.
        let targetParts = target.replacingOccurrences(of: "_", with: "-").lowercased().split(separator: "-")
        if TranslationLanguage.baseCode(target) == "zh",
           targetParts.contains("hans") || targetParts.contains("hant") {
            let transform = StringTransform(rawValue: targetParts.contains("hant") ? "Hans-Hant" : "Hant-Hans")
            guard let converted = text.applyingTransform(transform, reverse: false) else {
                return reject("output script conversion unavailable")
            }
            text = converted
        }

        guard !text.isEmpty, text != "..." else {
            return reject("empty")
        }
        let ratio = Double(text.count) / Double(max(input.count, 1))
        guard ratio >= 0.05, ratio < 5.0 else {
            return reject(String(format: "length ratio %.2f", ratio))
        }
        let echo = text.compare(input, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
        if echo && !permitsEcho(input, target: target, original: input) && !TranslationProcedure.isAlreadyInTarget(input, target: target) {
            return reject("echoed input", retryable: true)
        }

        let sourceLocale = LanguageDetector.sourceLanguage(in: input, hint: source)
            ?? (input.contains(where: \.isLetter) ? nil : source)
        guard preservesNumericFacts(input, in: text,
                                    sourceLanguage: source == "auto" ? "auto" : sourceLocale,
                                    outputLanguage: target) else {
            return reject("changed numeric content")
        }

        if hasUntranslatedSpan(in: text, target: target, original: input) {
            return reject("untranslated span", retryable: true)
        }

        let wanted = TranslationLanguage.baseCode(target)
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

    private static func hasUntranslatedSpan(in text: String, target: String, original: String) -> Bool {
        let wanted = TranslationLanguage.baseCode(target)
        guard recognizableLanguages.contains(wanted) else { return false }
        for span in CaptionLanguageSpanDetector.analyze(text) {
            let value = span.text.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
            let reading = LanguageRecognizerPool.shared.classify(value)
            let language = span.language ?? ((reading?.probability ?? 0) >= 0.95 ? reading?.language.rawValue : nil)
            guard value.unicodeScalars.filter({ CharacterSet.letters.contains($0) }).count >= 2,
                  !permitsEcho(value, target: target, original: original) else { continue }
            if let language, !TranslationLanguage.isSame(language, as: wanted) { return true }
            if value == text.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters)),
               value.count < 24,
               value.range(of: #"^[\p{script=Latin}\p{M}\s\p{P}]+$"#, options: .regularExpression) != nil {
                let hypotheses = LanguageRecognizerPool.shared.hypotheses(in: value)
                let support = hypotheses.reduce(0.0) { total, entry in
                    total + (TranslationLanguage.isSame(entry.key.rawValue, as: wanted) ? entry.value : 0)
                }
                // Weak source identity is not proof of a usable target. Keep
                // a short unsupported result recoverable rather than label it translated.
                if support < 0.05, (hypotheses.values.max() ?? 0) >= 0.6 { return true }
            }
        }
        return false
    }

    private static func permitsEcho(_ input: String, target: String, original: String) -> Bool {
        let value = input.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
        guard !value.isEmpty else { return false }
        if value.lowercased() == "ok" { return true }
        if value.lowercased() == "no", ["en", "es", "it"].contains(TranslationLanguage.baseCode(target)) { return true }
        if DictationVocabulary.termsPresent(in: input).contains(value) { return true }
        let identifierCharacters = expressions.expression(for: #"^[\p{script=Latin}\p{M}\p{N}_]+$"#)
        func continuesIdentifier(_ character: Character?) -> Bool {
            guard let character, let identifierCharacters else { return false }
            let text = String(character)
            return identifierCharacters.firstMatch(in: text, range: NSRange(text.startIndex..<text.endIndex, in: text)) != nil
        }
        var preserved = false
        var start = original.startIndex
        while let range = original.range(of: value, options: [.caseInsensitive, .widthInsensitive],
                                         range: start..<original.endIndex) {
            let before = range.lowerBound == original.startIndex ? nil : original[original.index(before: range.lowerBound)]
            let after = range.upperBound == original.endIndex ? nil : original[range.upperBound]
            if !continuesIdentifier(before), !continuesIdentifier(after) { preserved = true; break }
            start = range.upperBound
        }
        if value.first?.isUppercase == true, value != value.uppercased() || preserved {
            let tagger = NLTagger(tagSchemes: [.nameType])
            tagger.string = value
            var named = false
            var onlyNames = true
            tagger.enumerateTags(in: value.startIndex..<value.endIndex, unit: .word, scheme: .nameType,
                                 options: [.omitWhitespace, .omitPunctuation, .joinNames]) { tag, _ in
                if let tag, [NLTag.personalName, .placeName, .organizationName].contains(tag) { named = true }
                else { onlyNames = false }
                return true
            }
            if named && onlyNames { return true }
        }
        let pattern = #"^(?:[A-Z]{1,3}|(?=[A-Z0-9_./+\-]*[0-9_./+\-])[A-Z0-9_./+\-]+|[A-Za-z]*[a-z][A-Z][A-Za-z]*|https?://\S+|[^\s]+@[^\s]+)$"#
        guard let regex = expressions.expression(for: pattern) else { return false }
        return preserved && regex.firstMatch(in: value, range: NSRange(value.startIndex..<value.endIndex, in: value)) != nil
    }

    static func preservesNumericFacts(_ input: String, in output: String,
                                     sourceLanguage: String? = nil, outputLanguage: String? = nil) -> Bool {
        // A value multiset cannot protect the order of an ISO date's components.
        func dates(_ text: String) -> [String] {
            guard let regex = expressions.expression(for: #"\b\p{Nd}{4}-\p{Nd}{2}-\p{Nd}{2}\b"#) else { return [] }
            return regex.matches(in: text, range: NSRange(text.startIndex..<text.endIndex, in: text)).compactMap { match in
                guard let range = Range(match.range, in: text) else { return nil }
                return text[range].map { $0.wholeNumberValue.map(String.init) ?? String($0) }.joined()
            }.sorted()
        }
        guard dates(input) == dates(output) else { return false }
        let source = numericFacts(in: input, language: sourceLanguage == "auto" ? nil
            : sourceLanguage ?? LanguageDetector.sourceLanguage(in: input))
        let result = numericFacts(in: output, language: outputLanguage ?? LanguageDetector.sourceLanguage(in: output))
        guard source.count == result.count else { return false }
        var owners: [Int: Int] = [:]
        func assign(_ index: Int, visited: inout Set<Int>) -> Bool {
            for candidate in result.indices where !visited.contains(candidate)
                && !source[index].isDisjoint(with: result[candidate]) {
                visited.insert(candidate)
                if let previous = owners[candidate], !assign(previous, visited: &visited) { continue }
                owners[candidate] = index
                return true
            }
            return false
        }
        return source.indices.allSatisfy { index in
            var visited = Set<Int>()
            return assign(index, visited: &visited)
        }
    }

    private static func numericFacts(in value: String, language: String?) -> [Set<String>] {
        guard let regex = expressions.expression(for: #"(?<![\p{L}\p{N}])[+\-−]?\p{Nd}+(?:[.,٫٬'’\u00a0\u202f]\p{Nd}+)*"#) else { return [] }
        let locale = language.map { Locale(identifier: $0) }
        let range = NSRange(value.startIndex..<value.endIndex, in: value)
        return regex.matches(in: value, range: range).compactMap { match in
            guard let span = Range(match.range, in: value) else { return nil }
            let before = value[..<span.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
            let after = value[span.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
            let prefix = String(before.suffix(3))
            let suffix = String(after.prefix(3))
            let symbol = [before.last, after.first].compactMap { $0 }.first {
                $0.unicodeScalars.contains { $0.properties.generalCategory == .currencySymbol }
            }.map(String.init)
            let currency = symbol ?? (currencyCodes.contains(prefix) ? prefix
                : currencyCodes.contains(suffix) ? suffix : nil)
            let raw = value[span].map { character -> String in
                if let digit = character.wholeNumberValue { return String(digit) }
                if character == "٫" { return "D" }
                if character == "٬" { return "G" }
                if character == "−" { return "-" }
                return String(character)
            }.joined()
            let negative = raw.hasPrefix("-")
            let unsigned = raw.trimmingCharacters(in: CharacterSet(charactersIn: "+-"))
                .replacingOccurrences(of: #"[G'’\u00a0\u202f]"#, with: "", options: .regularExpression)
            func canonical(_ integer: String, _ fraction: String = "") -> String {
                let whole = String(integer.drop(while: { $0 == "0" }))
                let decimal = String(fraction.reversed().drop(while: { $0 == "0" }).reversed())
                let number = (whole.isEmpty ? "0" : whole) + (decimal.isEmpty ? "" : "." + decimal)
                let signed = negative && number != "0" ? "-" + number : number
                return signed + (currency.map { "|" + $0 } ?? "")
            }
            if let separator = unsigned.lastIndex(of: "D") {
                return [canonical(unsigned[..<separator].filter(\.isNumber), String(unsigned[unsigned.index(after: separator)...]))]
            }
            if unsigned.contains("."), unsigned.contains(","),
               let separator = unsigned.lastIndex(where: { $0 == "." || $0 == "," }) {
                return [canonical(unsigned[..<separator].filter(\.isNumber), String(unsigned[unsigned.index(after: separator)...]))]
            }
            let parts = unsigned.split(whereSeparator: { $0 == "." || $0 == "," }).map(String.init)
            guard parts.count > 1 else { return [canonical(unsigned)] }
            if parts.count > 2, parts.dropFirst().allSatisfy({ $0.count == 3 }) {
                return [canonical(parts.joined())]
            }
            var values: Set<String> = [canonical(parts.dropLast().joined(), parts.last ?? "")]
            if parts.count == 2, parts[0].count <= 3, parts[0] != "0", parts[1].count == 3 {
                let separator = unsigned.first(where: { $0 == "." || $0 == "," }).map(String.init)
                if separator == locale?.groupingSeparator { return [canonical(parts.joined())] }
                // One three-digit separator stays ambiguous only without matching locale evidence.
                if separator != locale?.decimalSeparator { values.insert(canonical(parts.joined())) }
            }
            return values
        }
    }

    private static let currencyCodes = Set(Locale.commonISOCurrencyCodes)
}
