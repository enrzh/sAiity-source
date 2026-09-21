import Foundation

/// Joins recogniser revisions and sentence clauses without inventing spacing
/// for scripts that do not use it. The input is intentionally bounded by the
/// live caption window, so a simple longest-overlap scan is predictable and
/// easier to audit than a fuzzy matcher.
enum CaptionTextMerger {
    static func join(_ parts: [String]) -> String {
        parts.reduce(into: "") { result, part in
            result = join(result, part)
        }
    }

    static func join(_ left: String, _ right: String) -> String {
        let lhs = normalize(left)
        let rhs = normalize(right)
        guard !lhs.isEmpty else { return rhs }
        guard !rhs.isEmpty else { return lhs }

        let leftChars = Array(lhs)
        let rightChars = Array(rhs)
        let maxOverlap = min(64, min(leftChars.count, rightChars.count))
        var overlap = 0
        if maxOverlap >= 2 {
            for length in stride(from: maxOverlap, through: 2, by: -1)
                where Array(leftChars.suffix(length)) == Array(rightChars.prefix(length)) {
                overlap = length
                break
            }
        }

        let suffix = String(rightChars.dropFirst(overlap))
        guard !suffix.isEmpty else { return lhs }
        guard let last = leftChars.last, let first = suffix.first else {
            return lhs + suffix
        }
        return lhs + separator(after: last, before: first) + suffix
    }

    private static func normalize(_ value: String) -> String {
        value.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    private static func separator(after left: Character, before right: Character) -> String {
        if left.isWhitespace || right.isWhitespace { return "" }
        if ".,!?;:%)]}，。！？、；：…".contains(right) { return "" }
        if "([{「『".contains(left) { return "" }
        // CJK/Thai text is written without Latin word spaces. Keeping the
        // boundary tight also avoids turning two recogniser revisions into
        // artificial Chinese/Japanese tokens.
        if isSpaceless(left) || isSpaceless(right) { return "" }
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
