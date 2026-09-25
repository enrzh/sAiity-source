import Foundation

/// Small, local vocabulary protection for names, products, and technical terms
/// that speech cleanup models commonly rewrite. This is prompt/validation
/// protection, not a claim that the ASR model supports neural hotwords.
enum DictationVocabulary {
    private static let key = "dictationVocabulary"
    private static let maxTerms = 50
    private static let maxLength = 64

    static var terms: [String] {
        get {
            guard let values = UserDefaults.standard.array(forKey: key) as? [String] else {
                return []
            }
            return normalize(values)
        }
        set { UserDefaults.standard.set(normalize(newValue), forKey: key) }
    }

    static var serialized: String {
        get { terms.joined(separator: ", ") }
        set { terms = parse(newValue) }
    }

    static func termsPresent(in text: String) -> [String] {
        terms.filter {
            text.range(of: $0, options: [.caseInsensitive, .diacriticInsensitive]) != nil
        }
    }

    static var promptInstruction: String {
        guard !terms.isEmpty else { return "" }
        return "Protected vocabulary: " + terms.joined(separator: ", ") + ". Preserve the exact spelling and casing of these terms whenever they appear."
    }

    /// Correct casing/spelling for an exact term after ASR has recognised it.
    /// This is deliberately conservative: it never invents a term or changes
    /// words that are not already present in the transcript.
    static func preservingSpelling(in text: String) -> String {
        var result = text
        for term in terms {
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

    private static func normalize(_ values: [String]) -> [String] {
        var result: [String] = []
        var seen = Set<String>()
        for raw in values {
            let term = raw
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
                .trimmingCharacters(in: .punctuationCharacters)
            guard !term.isEmpty,
                  term.count <= maxLength,
                  !term.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { continue }
            let identity = term.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            guard seen.insert(identity).inserted else { continue }
            result.append(term)
            if result.count == maxTerms { break }
        }
        return result
    }
}
