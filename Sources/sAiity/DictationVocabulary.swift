import Foundation

/// Small, local vocabulary protection for names, products, and technical terms
/// that speech cleanup models commonly rewrite. This is prompt/validation
/// protection, not a claim that the ASR model supports neural hotwords.
enum DictationVocabulary {
    struct Correction: Codable, Equatable, Identifiable, Sendable {
        let heard: String
        let replacement: String
        var id: String { heard.folding(options: [.caseInsensitive], locale: Locale(identifier: "en_US_POSIX")) }
    }

    private static let key = "dictationVocabulary"
    private static let correctionsKey = "dictationCorrections"
    private static let maxTerms = 50
    private static let maxLength = 64
    static let changed = Notification.Name("saiityVocabularyChanged")
    // ponytail: serialize the bounded 50+50 dictionary; snapshot reads if contention is measured.
    // The bounded dictionary is shared by settings, captions and dictation.
    // Reentrant because compound reads reuse the same cached accessors. Never
    // notify while holding it: observers may hop to another thread and read.
    private static let cacheLock = NSRecursiveLock()
    private static var cachedCorrections: [Correction]?
    private static var cachedProtectedTerms: [String]?
    private static var correctionPattern: NSRegularExpression?
    private static var orderedCorrections: [Correction] = []

    /// The normalized terms, kept so a caption chunk does not re-read
    /// UserDefaults and re-run a regex plus a `folding` per term — up to 50
    /// terms, several times a second while captions are live. The vocabulary
    /// only changes through the settings UI, and every writer goes through the
    /// setter below, which refreshes the cache.
    private static var cachedTerms: [String]?

    static var terms: [String] {
        get {
            cacheLock.lock()
            defer { cacheLock.unlock() }
            if let cachedTerms { return cachedTerms }
            guard let values = UserDefaults.standard.array(forKey: key) as? [String] else {
                return []
            }
            let normalized = normalize(values)
            cachedTerms = normalized
            return normalized
        }
        set {
            let normalized = normalize(newValue)
            cacheLock.withLock {
                cachedTerms = normalized
                cachedProtectedTerms = nil
                UserDefaults.standard.set(normalized, forKey: key)
            }
            NotificationCenter.default.post(name: changed, object: nil)
        }
    }

    static var corrections: [Correction] {
        get {
            cacheLock.lock()
            defer { cacheLock.unlock() }
            if let cachedCorrections { return cachedCorrections }
            let saved = UserDefaults.standard.data(forKey: correctionsKey)
                .flatMap { try? JSONDecoder().decode([Correction].self, from: $0) } ?? []
            cacheCorrections(normalizeCorrections(saved))
            return cachedCorrections ?? []
        }
        set {
            let values = normalizeCorrections(newValue)
            guard let data = try? JSONEncoder().encode(values) else { return }
            cacheLock.withLock {
                cacheCorrections(values)
                UserDefaults.standard.set(data, forKey: correctionsKey)
            }
            NotificationCenter.default.post(name: changed, object: nil)
        }
    }

    private static var protectedTerms: [String] {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        let names = terms
        let replacements = corrections
        if let cachedProtectedTerms { return cachedProtectedTerms }
        let values = normalize(names + replacements.map(\.replacement), limit: maxTerms * 2)
        cachedProtectedTerms = values
        return values
    }

    static func validEntry(_ text: String) -> Bool {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return !value.isEmpty && value.count <= maxLength
            && !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
    }

    private static func normalizeCorrections(_ values: [Correction]) -> [Correction] {
        var seen = Set<String>()
        return Array(values.compactMap { value -> Correction? in
            guard validEntry(value.heard), validEntry(value.replacement) else { return nil }
            let item = Correction(heard: value.heard.trimmingCharacters(in: .whitespacesAndNewlines),
                                  replacement: value.replacement.trimmingCharacters(in: .whitespacesAndNewlines))
            guard item.heard != item.replacement, seen.insert(item.id).inserted else { return nil }
            return item
        }.prefix(maxTerms))
    }

    private static func cacheCorrections(_ values: [Correction]) {
        cachedCorrections = values
        cachedProtectedTerms = nil
        orderedCorrections = values.enumerated().sorted {
            $0.element.heard.count == $1.element.heard.count
                ? $0.offset < $1.offset : $0.element.heard.count > $1.element.heard.count
        }.map(\.element)
        let word = #"[\p{L}\p{N}\p{M}_]"#
        let patterns = orderedCorrections.map {
            "((?<!" + word + ")" + NSRegularExpression.escapedPattern(for: $0.heard) + "(?!" + word + "))"
        }
        correctionPattern = patterns.isEmpty ? nil
            : try? NSRegularExpression(pattern: patterns.joined(separator: "|"), options: [.caseInsensitive])
    }

    /// One pass over the original text: replacements cannot trigger another
    /// correction, and longer phrases win over their shorter prefixes.
    static func applyingCorrections(in text: String) -> String {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        _ = corrections
        guard let correctionPattern else { return text }
        let result = NSMutableString(string: text)
        for match in correctionPattern.matches(in: text, range: NSRange(text.startIndex..., in: text)).reversed() {
            if let index = orderedCorrections.indices.first(where: { match.range(at: $0 + 1).location != NSNotFound }) {
                result.replaceCharacters(in: match.range, with: orderedCorrections[index].replacement)
            }
        }
        return result as String
    }

    static func applying(to input: DictationTranscriptionResult) -> DictationTranscriptionResult {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        let regions = input.regions.map {
            DictationRegionTranscript(text: preservingSpelling(in: $0.text), language: $0.language)
        }
        return regions == input.regions ? input : .init(regions: regions)
    }

    static var serialized: String {
        get { terms.joined(separator: ", ") }
        set { terms = parse(newValue) }
    }

    static func termsPresent(in text: String) -> [String] {
        protectedTerms.filter {
            text.range(of: $0, options: [.caseInsensitive, .diacriticInsensitive]) != nil
        }
    }

    static var promptInstruction: String {
        let values = protectedTerms
        guard !values.isEmpty else { return "" }
        return "Protected vocabulary: " + values.joined(separator: ", ") + ". Preserve the exact spelling and casing of these terms whenever they appear."
    }

    /// Apply approved corrections, then protect configured spelling/casing.
    static func preservingSpelling(in text: String) -> String {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        var result = applyingCorrections(in: text)
        for term in protectedTerms {
            var searchStart = result.startIndex
            while searchStart < result.endIndex,
                  let range = result.range(of: term,
                                           options: [.caseInsensitive, .diacriticInsensitive],
                                           range: searchStart..<result.endIndex) {
                result.replaceSubrange(range, with: term)
                searchStart = result.index(range.lowerBound,
                                           offsetBy: term.count,
                                           limitedBy: result.endIndex) ?? result.endIndex
            }
        }
        return result
    }

    private static func parse(_ value: String) -> [String] {
        value.components(separatedBy: CharacterSet(charactersIn: ",\n;"))
    }

    private static func normalize(_ values: [String], limit: Int = maxTerms) -> [String] {
        var result: [String] = []
        var seen = Set<String>()
        for raw in values {
            let term = raw
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            guard !term.isEmpty,
                  term.count <= maxLength,
                  !term.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { continue }
            let identity = term.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            guard seen.insert(identity).inserted else { continue }
            result.append(term)
            if result.count == limit { break }
        }
        return result
    }
}
