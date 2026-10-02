import Foundation
import NaturalLanguage

/// Joins recogniser revisions and sentence clauses without inventing spacing
/// for scripts that do not use it. The input is intentionally bounded by the
/// live caption window, so a simple longest-overlap scan is predictable and
/// easier to audit than a fuzzy matcher.
enum CaptionTextMerger {
    /// Adjacent, disjoint speech must keep intentional repetition.
    static func concatenate(_ left: String, _ right: String) -> String {
        let lhs = normalize(left)
        let rhs = normalize(right)
        guard let last = lhs.last else { return rhs }
        guard let first = rhs.first else { return lhs }
        return lhs + separator(after: last, before: first) + rhs
    }
    static func join(_ parts: [String]) -> String {
        var result = ""
        result.reserveCapacity(parts.reduce(0) { $0 + $1.utf8.count })
        for part in parts {
            result = join(result, part)
        }
        return result
    }

    static func join(_ left: String, _ right: String) -> String {
        let lhs = normalize(left)
        let rhs = normalize(right)
        guard !lhs.isEmpty else { return rhs }
        guard !rhs.isEmpty else { return lhs }

        // Substring comparison keeps the overlap scan on the native String
        // representation. The old Character-array version allocated two full
        // caption arrays and another pair for every candidate length, which is
        // wasteful in the hot partial-caption path.
        let maxOverlap = min(64, min(lhs.count, rhs.count))
        var overlap = 0
        if maxOverlap >= 2 {
            for length in stride(from: maxOverlap, through: 2, by: -1)
                where lhs.suffix(length) == rhs.prefix(length) {
                overlap = length
                break
            }
        }

        let suffix = rhs.dropFirst(overlap)
        guard !suffix.isEmpty else { return lhs }
        guard let last = lhs.last, let first = suffix.first else {
            return lhs + String(suffix)
        }
        return lhs + separator(after: last, before: first) + String(suffix)
    }

    private static func normalize(_ value: String) -> String {
        value.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    static func separator(after left: Character, before right: Character) -> String {
        if left.isWhitespace || right.isWhitespace { return "" }
        if ".,!?;:%)]}，。！？、；：…".contains(right) { return "" }
        if "([{「『".contains(left) { return "" }
        // CJK/Thai text is written without spaces between words. A language
        // switch still needs a readable boundary: Chinese + Chinese stays
        // tight, while Chinese + Latin gets one space.
        if isSpaceless(left) && isSpaceless(right) { return "" }
        return " "
    }

    private static func isSpaceless(_ character: Character) -> Bool {
        guard let scalar = character.unicodeScalars.first else { return false }
        switch scalar.value {
        case 0x3000...0x30FF, 0x3400...0x4DBF, 0x4E00...0x9FFF,
             0x0E00...0x0E7F, 0xFF00...0xFFEF:
            return true
        default:
            return false
        }
    }
}

/// Audio engines do not expose reliable mid-sentence language timestamps for
/// captions. This conservative text pass only splits when two sufficiently
/// long spans have strong, different NaturalLanguage readings or clearly
/// different scripts. An uncertain span stays in the original text instead of
/// being translated with the session's dominant language.
struct CaptionLanguageSpan: Equatable, Sendable {
    let text: String
    let language: String?
}

enum CaptionLanguageSpanDetector {
    private enum Script: Hashable {
        case latin, cyrillic, arabic, devanagari, hangul, han, kana
    }

    private struct Reading {
        let language: String
        let probability: Double
    }

    /// Language detection is on the translation hot path: the target-language
    /// check and the translation call can ask about the same sentence in one
    /// turn. NSCache keeps that second NaturalLanguage pass free without
    /// retaining an unbounded meeting's worth of text.
    private final class ReadingCacheEntry: NSObject {
        let language: String?
        let probability: Double

        init(_ reading: Reading?) {
            language = reading?.language
            probability = reading?.probability ?? 0
        }

        var reading: Reading? {
            guard let language else { return nil }
            return Reading(language: language, probability: probability)
        }
    }

    private static let readingCache: NSCache<NSString, ReadingCacheEntry> = {
        let cache = NSCache<NSString, ReadingCacheEntry>()
        cache.countLimit = 256
        return cache
    }()

    private static let recognizers = LanguageRecognizerPool()

    static func analyze(_ text: String,
                        fallbackLanguage: String? = nil) -> [CaptionLanguageSpan] {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return [] }

        var spans: [CaptionLanguageSpan] = []
        spans.reserveCapacity(4)
        var current = ""
        current.reserveCapacity(value.count)
        var currentScript: Script?

        func flush() {
            guard !current.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                current.removeAll(keepingCapacity: true)
                currentScript = nil
                return
            }
            spans.append(contentsOf: splitScriptRun(current,
                                                    script: currentScript,
                                                    fallbackLanguage: fallbackLanguage))
            current.removeAll(keepingCapacity: true)
            currentScript = nil
        }

        for character in value {
            let next = script(for: character)
            if let next, let currentScript, next != currentScript {
                flush()
            }
            if currentScript == nil, let next { currentScript = next }
            current.append(character)
        }
        flush()

        return coalesce(spans)
    }

    static func isMixed(_ spans: [CaptionLanguageSpan]) -> Bool {
        let languages = Set(spans.compactMap { language in
            language.language.map(TranslationLanguage.baseCode)
        }.filter { !$0.isEmpty && $0 != "auto" })
        if languages.count > 1 { return true }
        let scripts = Set(spans.compactMap { script(for: $0.text) })
        return scripts.count > 1
    }

    private static func splitScriptRun(_ text: String,
                                       script: Script?,
                                       fallbackLanguage: String?) -> [CaptionLanguageSpan] {
        guard script == .latin else {
            return [CaptionLanguageSpan(text: text,
                                        language: language(for: script, text: text))]
        }

        let words = text.split(whereSeparator: { $0.isWhitespace })
        guard words.count >= 4 else {
            return [CaptionLanguageSpan(text: text,
                                        language: reading(of: text)?.language ?? fallbackLanguage)]
        }

        let pieces = splitLatin(words)
        if pieces.count > 1 {
            return pieces.map { part in
                CaptionLanguageSpan(text: part.text,
                                    language: part.language)
            }
        }
        return [CaptionLanguageSpan(text: text,
                                    language: reading(of: text)?.language ?? fallbackLanguage)]
    }

    /// Candidates a run may have before the scan is allowed to subsample.
    /// Chosen so every realistic caption clause is still scanned exhaustively:
    /// a 27-word run has 24 candidates, and spoken sentences in this app's
    /// languages are well under that.
    private static let exhaustiveCandidateLimit = 24
    /// Positions between coarse samples on a longer run. Two, which is the
    /// widest stride measured to leave the boundary decision unchanged; see the
    /// note at the scan itself.
    private static let scanStride = 2

    private static func splitLatin(_ words: [Substring]) -> [(text: String, language: String?)] {
        guard words.count >= 4 else {
            let text = words.map(String.init).joined(separator: " ")
            return [(text, reading(of: text)?.language)]
        }

        // Character offsets, so a candidate can be length-checked before either
        // side is built. The loop below runs once per word, and building both
        // halves for every one of them was most of this function's cost — the
        // strings it produced were thrown away by the very next line whenever
        // the 8-character minimum was not met, which is the common case.
        var offsets = [Int](repeating: 0, count: words.count + 1)
        for (index, word) in words.enumerated() {
            offsets[index + 1] = offsets[index] + word.count + 1  // +1 for the joining space
        }
        func characters(in range: Range<Int>) -> Int {
            offsets[range.upperBound] - offsets[range.lowerBound] - 1
        }

        var candidates: [(index: Int, score: Double, left: Reading, right: Reading)] = []
        /// A settled answer, so a coarse pass can stop without looking further.
        var settled = false
        func consider(_ index: Int) {
            guard !settled else { return }
            // Neither half may be shorter than 8 characters, so a split that
            // cannot satisfy that is never worth building — or recognising.
            guard characters(in: 0..<index) >= 8, characters(in: index..<words.count) >= 8 else { return }
            let leftText = words[..<index].map(String.init).joined(separator: " ")
            let rightText = words[index...].map(String.init).joined(separator: " ")
            guard let left = reading(of: leftText),
                  let right = reading(of: rightText),
                  TranslationLanguage.baseCode(left.language)
                    != TranslationLanguage.baseCode(right.language) else { return }
            // The product of confidence favours two coherent spans and avoids
            // splitting on a single ambiguous loanword.
            let score = left.probability * right.probability
            candidates.append((index, score, left, right))
            // A near-certain boundary cannot be improved on by scanning the rest
            // of a long sentence. Below this we keep looking, because that is
            // where the genuinely ambiguous cases live.
            if score >= 0.95 { settled = true }
        }

        // Coarse-to-fine. This is quadratic by construction: every candidate
        // classifies two fresh strings, so a run of n words costs about 2(n-3)
        // recognizer passes, and on a long run that is nearly all of the
        // caption pipeline's language work. The common case is a run with no
        // boundary in it at all, and there the exhaustive scan classifies every
        // position in order to conclude nothing.
        //
        // So a long run is scanned on a coarse grid first, and only if that
        // found something is the neighbourhood of the best coarse hit refined.
        // A run that is one language finds nothing coarsely and stops, which is
        // the case worth optimising.
        //
        // The stride is 2 because that is where the refinement stops being
        // needed to reproduce the exhaustive answer, and that was measured
        // rather than assumed: sweeping a code-switch through all 39 positions of
        // a 39-word run, stride 2 reproduces the exhaustive result on every one,
        // while stride 3 moves 3 of them and stride 4 moves 2 — a boundary one
        // word off, and in one case the English word "about" stranded at the
        // head of the German span. Stride 4 is roughly 4x faster on a long run
        // against stride 2's 1.55x, so it is a one-constant change if the
        // speed is ever worth more than the boundary being exact.
        let first = 2
        let end = words.count - 1
        // Runs this size or shorter are scanned exhaustively, unchanged. Spoken
        // sentences in this app's languages are comfortably under it, so typical
        // captions take the exhaustive path and are not affected at all.
        let stride = (end - first) > Self.exhaustiveCandidateLimit ? Self.scanStride : 1
        if stride == 1 {
            for index in first..<end { consider(index) }
        } else {
            var index = first
            while index < end {
                consider(index)
                if settled { break }
                index += stride
            }
            // The last position is not necessarily on the coarse grid, and a
            // boundary sitting at the very end of a run is exactly the kind of
            // thing a stride would step over.
            if !settled { consider(end - 1) }
            if !settled,
               let coarse = candidates.max(by: { $0.score < $1.score }) {
                let low = max(first, coarse.index - stride)
                let high = min(end, coarse.index + stride + 1)
                for refine in low..<high { consider(refine) }
            }
        }

        guard let best = candidates.max(by: { $0.score < $1.score }),
              best.score >= 0.58 else {
            let whole = words.map(String.init).joined(separator: " ")
            return [(whole, reading(of: whole)?.language)]
        }

        let leftWords = Array(words[..<best.index])
        let rightWords = Array(words[best.index...])
        var result: [(text: String, language: String?)] = []
        result.append(contentsOf: splitLatin(leftWords))
        result.append(contentsOf: splitLatin(rightWords))
        return result
    }

    private static func reading(of text: String) -> Reading? {
        let key = text as NSString
        if let cached = readingCache.object(forKey: key) {
            return cached.reading
        }

        let result: Reading?
        let letters = text.unicodeScalars.filter { CharacterSet.letters.contains($0) }
        if letters.count < 6 {
            result = lexicalReading(of: text)
        } else {
            // Pooled. This is the per-candidate-split cost on the caption path,
            // and the reading cache does not help it: `splitLatin` builds a
            // distinct string pair for every boundary it considers, so nothing
            // repeats within a clause.
            if let hypothesis = recognizers.classify(text) {
                result = hypothesis.probability >= 0.72
                    ? Reading(language: hypothesis.language.rawValue,
                              probability: hypothesis.probability)
                    : lexicalReading(of: text)
            } else {
                result = lexicalReading(of: text)
            }
        }
        readingCache.setObject(ReadingCacheEntry(result), forKey: key)
        return result
    }

    private static func lexicalReading(of text: String) -> Reading? {
        let words = text.lowercased()
            .split(whereSeparator: { !$0.isLetter })
            .map(String.init)
        guard !words.isEmpty else { return nil }
        let markers: [String: Set<String>] = [
            "de": ["ich", "und", "der", "die", "das", "den", "dem", "ein", "eine", "einen", "einem", "bitte", "noch", "nochmal", "öffnen", "rechnung", "denke", "ist", "arbeite", "am", "mir", "heute", "nicht", "mit", "für", "auf", "zu"],
            "en": ["i", "we", "the", "and", "you", "can", "should", "this", "that", "today", "please", "check", "send", "with", "is"]
        ]
        var scored: [(language: String, score: Int)] = []
        for (language, vocabulary) in markers {
            scored.append((language, words.reduce(0) { $0 + (vocabulary.contains($1) ? 1 : 0) }))
        }
        guard let best = scored.max(by: { $0.score < $1.score }),
              best.score >= 2,
              scored.filter({ $0.language != best.language }).allSatisfy({ best.score > $0.score }) else {
            return nil
        }
        return Reading(language: best.language, probability: 0.80)
    }

    private static func coalesce(_ spans: [CaptionLanguageSpan]) -> [CaptionLanguageSpan] {
        spans.reduce(into: []) { result, span in
            guard !span.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            if let last = result.last,
               TranslationLanguage.isSame(last.language, as: span.language ?? "") {
                result[result.count - 1] = CaptionLanguageSpan(
                    text: CaptionTextMerger.join(last.text, span.text),
                    language: last.language)
            } else {
                result.append(span)
            }
        }
    }

    private static func language(for scriptFamily: Script?, text: String) -> String? {
        switch scriptFamily {
        case .han:
            return text.contains(where: { script(for: $0) == .kana }) ? "ja" : "zh"
        case .kana: return "ja"
        case .hangul: return "ko"
        case .cyrillic: return "ru"
        case .arabic: return "ar"
        case .devanagari: return "hi"
        case .latin, nil: return reading(of: text)?.language
        }
    }

    private static func script(for text: String) -> Script? {
        text.compactMap(script(for:)).first
    }

    private static func script(for character: Character) -> Script? {
        for scalar in character.unicodeScalars {
            switch scalar.value {
            case 0x0041...0x024F, 0x1E00...0x1EFF: return .latin
            case 0x0400...0x052F: return .cyrillic
            case 0x0600...0x06FF, 0x0750...0x077F, 0x08A0...0x08FF: return .arabic
            case 0x0900...0x097F: return .devanagari
            case 0x1100...0x11FF, 0xAC00...0xD7AF: return .hangul
            case 0x3040...0x30FF, 0x31F0...0x31FF: return .kana
            case 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF: return .han
            default: continue
            }
        }
        return nil
    }
}

/// Timing fallback for streaming engines that expose no word timestamps.
/// It uses the processed audio clock and only estimates the start of a cue;
/// it never claims sub-word precision the recogniser did not provide.
enum CaptionTiming {
    static func range(for text: String,
                      audioEnd: Double,
                      previousEnd: Double) -> (start: Double, end: Double) {
        let end = max(0, audioEnd.isFinite ? audioEnd : previousEnd)
        let spokenFor = min(Double(text.count) / 14.0 + 0.4, 12.0)
        let start = min(max(previousEnd, end - spokenFor), end)
        return (start, end)
    }
}

/// Pure endpoint evidence used by the cumulative recogniser reconciler.
enum CaptionEndpointPolicy {
    enum Decision: Equatable {
        case wait
        case finalize
    }

    static func decide(text: String,
                       age: TimeInterval,
                       repeatedPartials: Int,
                       hasSentenceTerminator: Bool,
                       maximumAge: TimeInterval,
                       minimumCharacters: Int,
                       maximumCharacters: Int,
                       stableAge: TimeInterval = 0.8) -> Decision {
        let count = text.count
        guard count > 0 else { return .wait }
        if hasSentenceTerminator { return .finalize }
        guard count >= minimumCharacters else { return .wait }
        if count >= maximumCharacters || age >= maximumAge { return .finalize }
        if repeatedPartials >= 3, age >= stableAge { return .finalize }
        return .wait
    }
}

/// Reconciles a cumulative ASR callback into an immutable prefix plus a
/// revisable volatile tail. A shorter or incompatible callback is ignored as a
/// stale engine revision instead of resetting the complete committed prefix.
struct CaptionTranscriptReconciler {
    struct Configuration: Sendable {
        var maximumVolatileAge: TimeInterval = 3.5
        var minimumRollingCharacters = 28
        var maximumVolatileCharacters = 110
        var volatileTailCharacters = 12
    }

    struct Output: Equatable, Sendable {
        let finalText: String?
        let volatileText: String?

        static let none = Output(finalText: nil, volatileText: nil)
    }

    var configuration: Configuration
    private(set) var committedText = ""
    private(set) var lastSeenText = ""

    private var lastCommitAt: Date
    private var repeatedPartials = 0

    init(configuration: Configuration = Configuration(), now: Date = Date()) {
        self.configuration = configuration
        self.lastCommitAt = now
    }

    mutating func reset(now: Date = Date()) {
        committedText = ""
        lastSeenText = ""
        lastCommitAt = now
        repeatedPartials = 0
    }

    mutating func update(cumulativeText: String, now: Date = Date()) -> Output {
        let text = cumulativeText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return .none }
        guard accepts(text) else { return .none }

        if text == lastSeenText {
            repeatedPartials += 1
        } else {
            repeatedPartials = 1
        }
        lastSeenText = text

        let pending = text.hasPrefix(committedText)
            ? String(text.dropFirst(committedText.count))
            : (committedText.isEmpty ? text : "")
        guard !pending.isEmpty else { return .none }

        let sentenceRange = pending.range(of: "(?:[.!?](?:\\s|$))|[。！？…]",
                                          options: [.regularExpression, .backwards])
        let age = now.timeIntervalSince(lastCommitAt)
        let decision = CaptionEndpointPolicy.decide(
            text: pending,
            age: age,
            repeatedPartials: repeatedPartials,
            hasSentenceTerminator: sentenceRange != nil,
            maximumAge: configuration.maximumVolatileAge,
            minimumCharacters: configuration.minimumRollingCharacters,
            maximumCharacters: configuration.maximumVolatileCharacters)

        let finalRaw: String
        if let sentenceRange {
            finalRaw = String(pending[..<sentenceRange.upperBound])
        } else if decision == .finalize,
                  let cut = Self.rollingCommitPoint(pending,
                                                    since: lastCommitAt,
                                                    now: now,
                                                    configuration: configuration,
                                                    force: true) {
            finalRaw = String(pending[..<cut])
        } else {
            return Output(finalText: nil,
                          volatileText: pending.trimmingCharacters(in: .whitespacesAndNewlines))
        }

        committedText += finalRaw
        lastCommitAt = now
        repeatedPartials = 0
        let finalText = finalRaw.trimmingCharacters(in: .whitespacesAndNewlines)
        let tail = String(pending.dropFirst(finalRaw.count))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return Output(finalText: finalText.isEmpty ? nil : finalText,
                      volatileText: tail.isEmpty ? nil : tail)
    }

    mutating func flush(cumulativeText: String? = nil) -> Output {
        if let cumulativeText {
            let text = cumulativeText.trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty, accepts(text) {
                lastSeenText = text
            }
        }
        guard !lastSeenText.isEmpty else { return .none }
        guard lastSeenText.hasPrefix(committedText) else { return .none }
        let rest = String(lastSeenText.dropFirst(committedText.count))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        committedText = lastSeenText
        repeatedPartials = 0
        lastCommitAt = Date()
        return rest.isEmpty ? .none : Output(finalText: rest, volatileText: nil)
    }

    static func rollingCommitPoint(_ text: String,
                                   since: Date,
                                   now: Date = Date(),
                                   configuration: Configuration = Configuration(),
                                   force: Bool = false) -> String.Index? {
        guard text.count >= configuration.minimumRollingCharacters else { return nil }
        let overdue = now.timeIntervalSince(since) >= configuration.maximumVolatileAge
        guard force || overdue || text.count >= configuration.maximumVolatileCharacters else { return nil }

        let keep = min(configuration.volatileTailCharacters,
                       max(1, text.count / 4))
        let keepBack = text.index(text.endIndex, offsetBy: -keep)
        let head = text[..<keepBack]
        guard !head.isEmpty else { return nil }
        if let boundary = head.lastIndex(where: { "、，,;；:：…".contains($0) }) {
            return text.index(after: boundary)
        }
        if let space = head.lastIndex(of: " ") {
            return text.index(after: space)
        }
        // CJK, Japanese and Thai do not require a Latin word boundary.
        if head.contains(where: { isSpaceless($0) }) {
            return keepBack
        }
        return nil
    }

    private func accepts(_ text: String) -> Bool {
        guard !committedText.isEmpty else { return true }
        if text.hasPrefix(committedText) { return true }
        // A shorter callback is a stale/reset revision. Refuse it rather than
        // replaying the already-emitted prefix and duplicating captions.
        if lastSeenText.hasPrefix(text) || committedText.hasPrefix(text) { return false }
        // The engine may revise the most recent volatile words, but it may not
        // rewrite a settled prefix. A non-prefix callback is therefore ignored
        // until the engine emits a compatible cumulative revision again.
        return false
    }

    private static func isSpaceless(_ character: Character) -> Bool {
        guard let scalar = character.unicodeScalars.first else { return false }
        switch scalar.value {
        case 0x3000...0x30FF, 0x3400...0x4DBF, 0x4E00...0x9FFF,
             0x0E00...0x0E7F, 0xFF00...0xFFEF:
            return true
        default:
            return false
        }
    }
}
