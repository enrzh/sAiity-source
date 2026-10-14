import Foundation
import NaturalLanguage

/// Compiled regular expressions, keyed by pattern.
///
/// `NSRegularExpression` is immutable and documented as safe to use from
/// multiple threads, so the only thing to protect is the map itself. Cleanup
/// runs off the main actor and `validate` is called from more than one task, so
/// the lock is not optional.
final class RegexCache: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String: NSRegularExpression?] = [:]

    func expression(for pattern: String) -> NSRegularExpression? {
        lock.lock()
        defer { lock.unlock() }
        if let cached = storage[pattern] { return cached }
        // A pattern that fails to compile is cached as a miss too, so a bad
        // literal costs one attempt rather than one per call.
        let compiled = try? NSRegularExpression(pattern: pattern)
        storage[pattern] = compiled
        return compiled
    }
}

enum DictationCleanupValidator {
    /// Compiled regular expressions, kept.
    ///
    /// `NSRegularExpression(pattern:)` parses and code-generates, which costs far
    /// more than running the match on a dictation-sized string. A single
    /// `deterministicCleanup` used to build twenty-odd of them from scratch —
    /// the spoken-formatting and filler tables alone account for most of that —
    /// and `normalizeWhitespace` added eight more through Foundation's regex
    /// options. Every pattern here is a compile-time literal, so the set of
    /// keys is small and fixed and the hit rate after the first call is total.
    ///
    /// This is the whole difference between a dictation-sized string taking
    /// single-digit milliseconds and taking microseconds.
    private static let compiled = RegexCache()
    private static let recognizers = LanguageRecognizerPool()
    private static let verbatimPattern =
        #"(?<![\p{L}\p{N}])'(?:\\.|[^'\\]|'(?=\p{L}))*'(?![\p{L}\p{N}])|"(?:\\.|[^"\\])*"|"#
        + #"“[^”]*”|‘(?:[^’]|’(?=\p{L}))*’|«[^»]*»|「[^」]*」|『[^』]*』|(`+)[\s\S]*?\1"#

    private static func expression(_ pattern: String) -> NSRegularExpression? {
        compiled.expression(for: pattern)
    }

    static func needsModelCleanup(_ value: String, sourceLanguage: String? = nil) -> Bool {
        deterministicOutcome(value, sourceLanguage: sourceLanguage).needsModel
    }

    /// The deterministic pass and whether a semantic repair still remains.
    ///
    /// Keep the baseline and model/validation decisions together so callers
    /// share one deterministic pass and the same fallback.
    static func deterministicOutcome(_ value: String,
                                      sourceLanguage: String? = nil) -> (baseline: String, needsModel: Bool, punctuationOnly: Bool) {
        let baseline = deterministicCleanup(value, sourceLanguage: sourceLanguage)
        guard !baseline.isEmpty else { return (baseline, false, false) }

        // Quoted/code ellipses are literal; spoken punctuation commands already
        // have a deterministic result. Only raw pauses outside literals need context.
        let unquoted = replace(value, pattern: verbatimPattern, with: " ")
        let pause = unquoted.range(of: #"\p{L}[ \t]*(?:\.{3,}|…+)[ \t]*(?=\p{L})"#,
                                   options: .regularExpression) != nil

        // The deterministic pass is language-agnostic. Only send text to the
        // model when a semantic repair remains; a language allow-list made every
        // clean French, Spanish, or long-tail-language sentence pay for LLM
        // inference even when there was nothing left to fix.
        let repairs = #"(?i)\b(i mean|no wait|je veux dire|non attends|quiero decir|no espera|no aspetta|quer dizer|não espera|ik bedoel|nee wacht|mam na myśli|nie czekaj|ich meine|besser gesagt|oder doch)\b|[,;—–]\s*(?:actually|rather|sorry|no|nein|instead|eigentlich|sondern|warte|plutôt|désolé|más bien|perdón|piuttosto|scusa|melhor|desculpa|liever|raczej|przepraszam)\b|(?:いや、?待って|不对|我的意思是|等一下|잠깐만)"#
        let prose = replace(baseline, pattern: verbatimPattern, with: " ")
        let range = NSRange(prose.startIndex..<prose.endIndex, in: prose)
        let repair = expression(repairs)?.firstMatch(in: prose, range: range) != nil
        return (baseline, repair || pause, pause && !repair)
    }

    /// Applies the speech repairs that should never depend on a small local
    /// model following an instruction. Keep this deliberately conservative:
    /// semantic rewrites still belong to the cleanup model.
    static func deterministicCleanup(_ value: String, sourceLanguage: String? = nil) -> String {
        var text = normalizeWhitespace(value)
        let language = baseLanguage(LanguageDetector.sourceLanguage(in: text, hint: sourceLanguage))
        guard let language, ["en", "de", "fr", "es", "it", "pt", "nl", "ru", "ja", "zh", "ko", "ar"].contains(language) else { return text }
        text = applySpokenFormatting(text, language: language)
        text = normalizeWhitespace(text)
        text = removeFillers(text, language: language)

        if let politeness = ["en": "please", "de": "bitte"][language] {
            // Politeness stutters are repairable; emphatic repetitions carry meaning.
            while true {
                let cleaned = replace(text, pattern: "(?i)\\b(" + politeness + ")\\s+\\1\\b", with: "$1")
                guard cleaned != text else { break }
                text = cleaned
            }
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

        text = normalizeWhitespace(text)
        text = replace(text, pattern: #"[ \t]+([,.;!?])"#, with: "$1")
        text = replace(text, pattern: #"([,;:])\s*([,.])"#, with: "$1")
        text = replace(text,
                       pattern: #"(?i),\s+(?=(?:today|tomorrow|yesterday|now|tonight)\b)"#,
                       with: " ")
        // A lone trailing backslash is emitted by some recognizer/transport
        // paths, not spoken text. Leave real escaped pairs untouched.
        text = replace(text, pattern: #"(?<!\\)\\$"#, with: "")
        if let first = text.first, first.isLowercase {
            text.replaceSubrange(text.startIndex...text.startIndex, with: String(first).uppercased())
        }
        return capitalizeBulletItems(normalizeWhitespace(text))
    }

    /// Turns explicit spoken layout commands into real document structure. The
    /// model receives this already-formatted baseline and can improve it without
    /// having to infer every command from a single noisy pass.
    private static func applySpokenFormatting(_ value: String, language: String?) -> String {
        guard let language, ["en", "de", "fr", "es", "it", "pt"].contains(language) else { return value }
        var text = value
        let lineBreaks: [(String, String)]
        switch language {
        case "de":
            lineBreaks = [
                (#"(?i)(?<![\p{L}\p{N}])(?:neuer Absatz|absatzumbruch)(?![\p{L}\p{N}])[,;:]?[ \t]*"#, "\n\n"),
                (#"(?i)(?<![\p{L}\p{N}])(?:neue Zeile|zeilenumbruch)(?![\p{L}\p{N}])[,;:]?[ \t]*"#, "\n"),
                (#"(?i)(?<![\p{L}\p{N}])(?:Aufzählungspunkt|Aufzählung)(?![\p{L}\p{N}])[,;:]?[ \t]*"#, "\n• "),
            ]
        case "fr":
            lineBreaks = [
                (#"(?i)(?<![\p{L}\p{N}])(?:nouveau paragraphe|saut de paragraphe)(?![\p{L}\p{N}])[,;:]?[ \t]*"#, "\n\n"),
                (#"(?i)(?<![\p{L}\p{N}])(?:nouvelle ligne|saut de ligne)(?![\p{L}\p{N}])[,;:]?[ \t]*"#, "\n"),
                (#"(?i)(?<![\p{L}\p{N}])(?:puce|point de liste)(?![\p{L}\p{N}])[,;:]?[ \t]*"#, "\n• "),
            ]
        case "es":
            lineBreaks = [
                (#"(?i)(?<![\p{L}\p{N}])(?:nuevo párrafo|salto de párrafo)(?![\p{L}\p{N}])[,;:]?[ \t]*"#, "\n\n"),
                (#"(?i)(?<![\p{L}\p{N}])(?:nueva línea|salto de línea)(?![\p{L}\p{N}])[,;:]?[ \t]*"#, "\n"),
                (#"(?i)(?<![\p{L}\p{N}])(?:viñeta|punto de lista)(?![\p{L}\p{N}])[,;:]?[ \t]*"#, "\n• "),
            ]
        case "it":
            lineBreaks = [
                (#"(?i)(?<![\p{L}\p{N}])(?:nuovo paragrafo|interruzione di paragrafo)(?![\p{L}\p{N}])[,;:]?[ \t]*"#, "\n\n"),
                (#"(?i)(?<![\p{L}\p{N}])(?:nuova riga|interruzione di riga)(?![\p{L}\p{N}])[,;:]?[ \t]*"#, "\n"),
                (#"(?i)(?<![\p{L}\p{N}])(?:punto elenco|elenco puntato)(?![\p{L}\p{N}])[,;:]?[ \t]*"#, "\n• "),
            ]
        case "pt":
            lineBreaks = [
                (#"(?i)(?<![\p{L}\p{N}])(?:novo parágrafo|quebra de parágrafo)(?![\p{L}\p{N}])[,;:]?[ \t]*"#, "\n\n"),
                (#"(?i)(?<![\p{L}\p{N}])(?:nova linha|quebra de linha)(?![\p{L}\p{N}])[,;:]?[ \t]*"#, "\n"),
                (#"(?i)(?<![\p{L}\p{N}])(?:marcador|ponto de lista)(?![\p{L}\p{N}])[,;:]?[ \t]*"#, "\n• "),
            ]
        default:
            lineBreaks = [
                (#"(?i)(?<![\p{L}\p{N}])(?:new paragraph|paragraph break)(?![\p{L}\p{N}])[,;:]?[ \t]*"#, "\n\n"),
                (#"(?i)(?<![\p{L}\p{N}])(?:new line|newline|line break)(?![\p{L}\p{N}])[,;:]?[ \t]*"#, "\n"),
                (#"(?i)(?<![\p{L}\p{N}])(?:bullet point|bullet|list item)(?![\p{L}\p{N}])[,;:]?[ \t]*"#, "\n• "),
            ]
        }
        for (pattern, replacement) in lineBreaks {
            text = replaceFormatting(text, pattern: pattern, with: replacement)
        }

        let punctuation: [(String, String)]
        switch language {
        case "de":
            punctuation = [
                (#"(?i)(?<![\p{L}\p{N}])Fragezeichen(?![\p{L}\p{N}])"#, "?"),
                (#"(?i)(?<![\p{L}\p{N}])Ausrufezeichen(?![\p{L}\p{N}])"#, "!"),
                (#"(?i)(?<![\p{L}\p{N}])Punkt(?![\p{L}\p{N}])"#, "."),
                (#"(?i)(?<![\p{L}\p{N}])Semikolon(?![\p{L}\p{N}])"#, ";"),
                (#"(?i)(?<![\p{L}\p{N}])Doppelpunkt(?![\p{L}\p{N}])"#, ":"),
                (#"(?i)(?<![\p{L}\p{N}])Komma(?![\p{L}\p{N}])"#, ","),
            ]
        case "fr":
            punctuation = [
                (#"(?i)(?<![\p{L}\p{N}])point d'interrogation(?![\p{L}\p{N}])"#, "?"),
                (#"(?i)(?<![\p{L}\p{N}])point d'exclamation(?![\p{L}\p{N}])"#, "!"),
                (#"(?i)(?<![\p{L}\p{N}])(?:point final|point)(?![\p{L}\p{N}])"#, "."),
                (#"(?i)(?<![\p{L}\p{N}])point-virgule(?![\p{L}\p{N}])"#, ";"),
                (#"(?i)(?<![\p{L}\p{N}])deux-points(?![\p{L}\p{N}])"#, ":"),
                (#"(?i)(?<![\p{L}\p{N}])virgule(?![\p{L}\p{N}])"#, ","),
            ]
        case "es":
            punctuation = [
                (#"(?i)(?<![\p{L}\p{N}])signo de interrogación(?![\p{L}\p{N}])"#, "?"),
                (#"(?i)(?<![\p{L}\p{N}])signo de exclamación(?![\p{L}\p{N}])"#, "!"),
                (#"(?i)(?<![\p{L}\p{N}])dos puntos(?![\p{L}\p{N}])"#, ":"),
                (#"(?i)(?<![\p{L}\p{N}])punto y coma(?![\p{L}\p{N}])"#, ";"),
                (#"(?i)(?<![\p{L}\p{N}])punto(?![\p{L}\p{N}])"#, "."),
                (#"(?i)(?<![\p{L}\p{N}])coma(?![\p{L}\p{N}])"#, ","),
            ]
        case "it":
            punctuation = [
                (#"(?i)(?<![\p{L}\p{N}])punto interrogativo(?![\p{L}\p{N}])"#, "?"),
                (#"(?i)(?<![\p{L}\p{N}])punto esclamativo(?![\p{L}\p{N}])"#, "!"),
                (#"(?i)(?<![\p{L}\p{N}])due punti(?![\p{L}\p{N}])"#, ":"),
                (#"(?i)(?<![\p{L}\p{N}])punto e virgola(?![\p{L}\p{N}])"#, ";"),
                (#"(?i)(?<![\p{L}\p{N}])punto(?![\p{L}\p{N}])"#, "."),
                (#"(?i)(?<![\p{L}\p{N}])virgola(?![\p{L}\p{N}])"#, ","),
            ]
        case "pt":
            punctuation = [
                (#"(?i)(?<![\p{L}\p{N}])ponto de interrogação(?![\p{L}\p{N}])"#, "?"),
                (#"(?i)(?<![\p{L}\p{N}])ponto de exclamação(?![\p{L}\p{N}])"#, "!"),
                (#"(?i)(?<![\p{L}\p{N}])dois pontos(?![\p{L}\p{N}])"#, ":"),
                (#"(?i)(?<![\p{L}\p{N}])ponto e vírgula(?![\p{L}\p{N}])"#, ";"),
                (#"(?i)(?<![\p{L}\p{N}])ponto(?![\p{L}\p{N}])"#, "."),
                (#"(?i)(?<![\p{L}\p{N}])vírgula(?![\p{L}\p{N}])"#, ","),
            ]
        default:
            punctuation = [
                (#"(?i)(?<![\p{L}\p{N}])question mark(?![\p{L}\p{N}])"#, "?"),
                (#"(?i)(?<![\p{L}\p{N}])exclamation (?:mark|point)(?![\p{L}\p{N}])"#, "!"),
                (#"(?i)(?<![\p{L}\p{N}])(?:full stop|period)(?![\p{L}\p{N}])"#, "."),
                (#"(?i)(?<![\p{L}\p{N}])semicolon(?![\p{L}\p{N}])"#, ";"),
                (#"(?i)(?<![\p{L}\p{N}])colon(?![\p{L}\p{N}])"#, ":"),
                (#"(?i)(?<![\p{L}\p{N}])comma(?![\p{L}\p{N}])"#, ","),
                (#"(?i)(?<![\p{L}\p{N}])ellipsis(?![\p{L}\p{N}])"#, "…"),
                (#"(?i)(?<![\p{L}\p{N}])(?:em dash|long dash)(?![\p{L}\p{N}])"#, "—"),
                (#"(?i)(?<![\p{L}\p{N}])(?:open quote|begin quote)(?![\p{L}\p{N}])"#, "“"),
                (#"(?i)(?<![\p{L}\p{N}])(?:close quote|end quote)(?![\p{L}\p{N}])"#, "”"),
            ]
        }
        for (pattern, replacement) in punctuation {
            text = replaceFormatting(text, pattern: pattern, with: replacement)
        }
        return text
    }

    /// A named word or a noun phrase is not a spoken formatting command.
    private static func replaceFormatting(_ value: String, pattern: String, with replacement: String) -> String {
        guard let regex = expression(pattern) else { return value }
        let range = NSRange(value.startIndex..<value.endIndex, in: value)
        let result = NSMutableString(string: value)
        let determiners: Set<String> = ["a", "an", "the", "this", "that", "my", "your", "word", "term", "symbol",
            "ein", "eine", "einen", "einem", "einer", "der", "die", "das", "wort", "zeichen",
            "un", "une", "le", "la", "el", "una", "il", "um", "uma", "o"]
        for match in regex.matches(in: value, range: range).reversed() {
            guard let span = Range(match.range, in: value) else { continue }
            let before = value[..<span.lowerBound]
            let after = value[span.upperBound...]
            let previous = before.split(whereSeparator: { $0.isWhitespace || $0.isPunctuation }).suffix(2)
            let next = after.split(whereSeparator: { $0.isWhitespace || $0.isPunctuation }).first?.lowercased()
            let literal = previous.contains { determiners.contains($0.lowercased()) }
                || ["of", "von", "de", "train", "lasted", "is", "was", "ist"].contains(next ?? "")
                || before.filter { $0 == "\"" }.count % 2 == 1
            guard !literal else { continue }
            result.replaceCharacters(in: match.range, with: replacement)
        }
        return result as String
    }

    private static func removeFillers(_ value: String, language: String?) -> String {
        guard let language, ["en", "de", "fr", "es", "it", "pt", "nl", "ru", "ja", "zh", "ko", "ar"].contains(language) else { return value }
        let fillers: [String]
        switch language {
        case "de": fillers = ["ähm+", "äh", "öhm+", "hm+"]
        case "fr": fillers = ["euh+", "hum+"]
        case "es": fillers = ["eh+", "em+"]
        case "it": fillers = ["ehm+", "eh+"]
        case "pt": fillers = ["hum+"]
        case "nl": fillers = ["uh+", "eh+", "uhm+", "hmm+"]
        case "ru": fillers = ["э+", "эм+", "ммм+"]
        case "ja": fillers = ["えーと", "ええと"]
        case "zh": fillers = ["呃+", "嗯+"]
        case "ko": fillers = ["어+", "음+"]
        case "ar": fillers = ["اممم+"]
        case "en": fillers = ["um+", "uh+", "erm+", "er", "hmm+", "mmm+"]
        default: fillers = ["uh+", "erm+", "hmm+", "mmm+"]
        }
        let fillerPattern = #"(?i)(?<![\p{L}\p{N}])(?:"#
            + fillers.joined(separator: "|")
            + #")(?![\p{L}\p{N}])(?:[ \t]*(?:[,;:，、；：]|\.{2,}|…+))?[ \t]*"#
        var text = replace(value, pattern: fillerPattern, with: "")

        // German "um" is normally meaningful ("um acht Uhr"). Remove it as
        // hesitation only at a sentence boundary with hesitation punctuation,
        // which covers "Um... Ja" without damaging real German phrasing.
        if language == "de" || language == "en" {
            text = replace(text,
                           pattern: #"(?i)^\s*um+\s*(?:\.{2,}|…+|[,;:，、；：])\s*"#,
                           with: "")
            text = replace(text,
                           pattern: #"(?i)(?<=[.!?。！？])\s*um+\s*(?:\.{2,}|…+|[,;:，、；：])\s*"#,
                           with: " ")
        }

        // These words can carry meaning, so only remove them when the speaker
        // marked them as discourse fillers with punctuation.
        let punctuated: [String]
        switch language {
        case "de": punctuated = ["also", "na ja", "sozusagen"]
        case "fr": punctuated = ["enfin", "voilà"]
        case "es": punctuated = ["like", "pues", "este", "o sea"]
        case "it": punctuated = ["cioè", "diciamo"]
        case "pt": punctuated = ["tipo", "assim", "quer dizer"]
        case "nl": punctuated = ["nou", "zeg maar"]
        case "ru": punctuated = ["ну", "то есть", "короче"]
        case "ja": punctuated = ["あの", "その"]
        case "zh": punctuated = ["那个", "就是说"]
        case "ko": punctuated = ["그러니까", "저기"]
        case "ar": punctuated = ["يعني", "حسنا"]
        case "en": punctuated = ["like", "well", "you know"]
        default: punctuated = []
        }
        let punctuatedPattern = #"(?i)(?<![\p{L}\p{N}])(?:"#
            + punctuated.joined(separator: "|")
            + #")(?![\p{L}\p{N}])[ \t]*(?:[,;:，、；：]|\.{2,}|…+)[ \t]*"#
        if !punctuated.isEmpty { text = replace(text, pattern: punctuatedPattern, with: "") }
        if language == "en" {
            text = replace(text,
                           pattern: #"(?i)^\s*(?:you know|basically|well)[ \t]*[,;:][ \t]*"#,
                           with: "")
        }
        return text
    }

    private static func capitalizeBulletItems(_ value: String) -> String {
        value
            .components(separatedBy: "\n")
            .map { line in
                guard line.hasPrefix("• ") else { return line }
                let start = line.index(line.startIndex, offsetBy: 2)
                guard start < line.endIndex else { return line }
                let first = line[start]
                guard first.isLowercase else { return line }
                return String(line[..<start]) + String(first).uppercased() + line[line.index(after: start)...]
            }
            .joined(separator: "\n")
    }

    private static func normalizeWhitespace(_ value: String) -> String {
        let normalized = value
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let lines = normalized.split(separator: "\n", omittingEmptySubsequences: false)
            .map { line in
                // Cached rather than `replacingOccurrences(options: .regularExpression)`,
                // which compiles internally on every call — twice per line, four
                // times per cleanup.
                replace(String(line), pattern: #"[\t ]+"#, with: " ")
                    .trimmingCharacters(in: .whitespaces)
            }
        return replace(lines.joined(separator: "\n"), pattern: #"\n{3,}"#, with: "\n\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func validate(_ value: String,
                         preserving input: String? = nil,
                         sourceLanguage: String? = nil,
                         languageMetadata: DictationLanguageMetadata? = nil,
                         allowParagraphs: Bool = false) -> String? {
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
        let prefixes = [
            "Here is", "Here's", "Cleaned transcript:", "Cleaned text:",
            "The cleaned transcript is:", "I cannot help", "I can't help",
            "I'm sorry, I", "I’m sorry, I", "As an AI",
        ]
        guard !prefixes.contains(where: { text.lowercased().hasPrefix($0.lowercased()) }) else { return nil }
        let paragraphs = text.components(separatedBy: "\n\n").filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        guard allowParagraphs || paragraphs.count <= 1 || isStructuredList(text) else { return nil }
        if let input {
            if input.contains("...") || input.contains("…") {
                let outcome = deterministicOutcome(input, sourceLanguage: sourceLanguage)
                if outcome.punctuationOnly {
                    guard words(in: outcome.baseline).map({ $0.lowercased() }) == words(in: text).map({ $0.lowercased() }),
                          let literals = expression(verbatimPattern) else { return nil }
                    let literalBytes: (String) -> [Data] = { value in
                        let range = NSRange(value.startIndex..<value.endIndex, in: value)
                        return literals.matches(in: value, range: range).compactMap { match in
                            Range(match.range, in: value).map { Data(value[$0].utf8) }
                        }
                    }
                    guard literalBytes(input) == literalBytes(text) else { return nil }
                }
            }
            let language = LanguageDetector.sourceLanguage(in: input, hint: sourceLanguage)
            guard TranslationOutputValidator.preservesNumericFacts(input, in: text,
                sourceLanguage: language, outputLanguage: language) else { return nil }
            let outputMeaning = meaningTokens(in: text)
            guard meaningTokens(in: input).allSatisfy({ outputMeaning[$0.key, default: 0] >= $0.value }) else { return nil }
            let inputWords = words(in: input)
            let outputWords = words(in: text)
            if inputWords.count >= 8, outputWords.count < max(3, inputWords.count / 4) { return nil }
            if inputWords.count >= 4, outputWords.count > inputWords.count * 2 { return nil }
            guard protectedTokens(in: input).allSatisfy({ text.range(of: $0, options: .caseInsensitive) != nil }) else {
                return nil
            }
            guard DictationVocabulary.termsPresent(in: input).allSatisfy({ text.range(of: $0) != nil }) else {
                return nil
            }
            guard languageWasPreserved(input: input,
                                       output: text,
                                       sourceLanguage: sourceLanguage,
                                       languageMetadata: languageMetadata) else {
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
                                             sourceLanguage: String?,
                                             languageMetadata: DictationLanguageMetadata? = nil) -> Bool {
        if let languageMetadata, languageMetadata.containsMultipleLanguages {
            return mixedLanguageWasPreserved(input: input,
                                             output: output,
                                             metadata: languageMetadata)
        }
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

    private static func mixedLanguageWasPreserved(input: String,
                                                  output: String,
                                                  metadata: DictationLanguageMetadata) -> Bool {
        let outputTokens = words(in: output).reduce(into: [String: Int]()) {
            $0[String($1).folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil), default: 0] += 1
        }
        // One surviving word cannot account for a whole spoken span. This is
        // a conservative omission guard; it does not certify a paraphrase's meaning.
        for region in metadata.regionTexts {
            let tokens = words(in: region).filter { $0.count >= 2 }
            guard !tokens.isEmpty else { continue }
            var available = outputTokens
            var retained = 0
            for token in tokens {
                let key = String(token).folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
                if available[key, default: 0] > 0 {
                    available[key, default: 0] -= 1
                    retained += 1
                }
            }
            guard retained >= (tokens.count * 3 + 4) / 5 else { return false }
        }

        // Script changes are stronger evidence than a text classifier. Require
        // every meaningful source script to remain represented in the result.
        let inputScripts = metadata.regionTexts.reduce(into: Set<ScriptFamily>()) {
            $0.formUnion(scriptFamilies(in: $1))
        }
        let outputScripts = scriptFamilies(in: output)
        guard inputScripts.isEmpty || inputScripts.isSubset(of: outputScripts) else {
            return false
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

    private static func scriptFamilies(in text: String) -> Set<ScriptFamily> {
        var result = Set<ScriptFamily>()
        for scalar in text.unicodeScalars {
            let value = scalar.value
            switch value {
            case 0x0041...0x024F, 0x1E00...0x1EFF: result.insert(.latin)
            case 0x0370...0x03FF, 0x1F00...0x1FFF: result.insert(.greek)
            case 0x0400...0x052F: result.insert(.cyrillic)
            case 0x0530...0x058F: result.insert(.armenian)
            case 0x10A0...0x10FF, 0x2D00...0x2D2F: result.insert(.georgian)
            case 0x0590...0x05FF: result.insert(.hebrew)
            case 0x0600...0x06FF, 0x0750...0x077F, 0x08A0...0x08FF: result.insert(.arabic)
            case 0x0900...0x097F: result.insert(.devanagari)
            case 0x0980...0x09FF: result.insert(.bengali)
            case 0x0A00...0x0A7F: result.insert(.gurmukhi)
            case 0x0A80...0x0AFF: result.insert(.gujarati)
            case 0x0B80...0x0BFF: result.insert(.tamil)
            case 0x0C00...0x0C7F: result.insert(.telugu)
            case 0x0C80...0x0CFF: result.insert(.kannada)
            case 0x0D00...0x0D7F: result.insert(.malayalam)
            case 0x0E00...0x0E7F: result.insert(.thai)
            case 0x0E80...0x0EFF: result.insert(.lao)
            case 0x1000...0x109F, 0xAA60...0xAA7F: result.insert(.myanmar)
            case 0x1200...0x137F, 0x1380...0x139F: result.insert(.ethiopic)
            case 0x1780...0x17FF: result.insert(.khmer)
            case 0x1100...0x11FF, 0xAC00...0xD7AF: result.insert(.hangul)
            case 0x3040...0x309F, 0x30A0...0x30FF, 0x31F0...0x31FF: result.insert(.japaneseKana)
            case 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF: result.insert(.han)
            default: continue
            }
        }
        return result
    }

    private static func detectedLanguage(in text: String) -> String? {
        recognizers.dominantLanguage(text)?.rawValue
    }

    private static func baseLanguage(_ value: String?) -> String? {
        guard let value else { return nil }
        return value.replacingOccurrences(of: "_", with: "-")
            .split(separator: "-")
            .first?
            .lowercased()
    }

    private static func replace(_ value: String, pattern: String, with template: String) -> String {
        guard let regex = expression(pattern) else { return value }
        let range = NSRange(value.startIndex..<value.endIndex, in: value)
        return regex.stringByReplacingMatches(in: value, range: range, withTemplate: template)
    }

    private static func words(in text: String) -> [Substring] {
        text.split { $0.isWhitespace || $0.isPunctuation }
    }

    private static func isStructuredList(_ text: String) -> Bool {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: true)
        guard lines.count >= 2 else { return false }
        guard let regex = expression(#"^\s*(?:[•*+-]|\d+[.)])\s+\S+"#) else { return false }
        return lines.allSatisfy { line in
            let value = String(line)
            return regex.firstMatch(in: value,
                                    range: NSRange(value.startIndex..<value.endIndex,
                                                   in: value)) != nil
        }
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
        let pattern = #"(?i)(?:https?://[^\s]+|www\.[^\s]+|[a-z0-9._%+\-]+@[a-z0-9.\-]+\.[a-z]{2,})"#
        guard let regex = expression(pattern) else { return [] }
        let range = NSRange(input.startIndex..<input.endIndex, in: input)
        var tokens: [String] = regex.matches(in: input, range: range).compactMap { match -> String? in
            guard let tokenRange = Range(match.range, in: input) else { return nil }
            return input[tokenRange].trimmingCharacters(in: .punctuationCharacters)
        }.filter { !$0.isEmpty }
        tokens.append(contentsOf: DictationVocabulary.termsPresent(in: input))
        var seen = Set<String>()
        return tokens.filter { seen.insert($0.lowercased()).inserted }
    }

    private static func meaningTokens(in text: String) -> [String: Int] {
        let pattern = #"(?i)\b(?:not|never|no|nein|nicht|kein(?:e|en|em|er|es)?|don't|can't|won't|isn't|wasn't|shouldn't|couldn't|maybe|perhaps|possibly|might|vielleicht|eventuell|wahrscheinlich|nunca|jamais|pas|quizá|forse)\b|(?:不|没|ない|않|못)"#
        guard let regex = expression(pattern) else { return [:] }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        let tokens: [String] = regex.matches(in: text, range: range).compactMap { match in
            guard let span = Range(match.range, in: text) else { return nil }
            let token = text[span].lowercased()
            // An isolated correction marker can disappear; an assertion cannot.
            if ["no", "nein"].contains(token),
               text[..<span.lowerBound].trimmingCharacters(in: .whitespaces).last == ",",
               text[span.upperBound...].trimmingCharacters(in: .whitespaces).first == "," {
                return nil
            }
            return token
        }
        return tokens.reduce(into: [:]) { $0[$1, default: 0] += 1 }
    }
}
