import Foundation
import NaturalLanguage

struct DictationBenchmarkFixture: Codable, Equatable, Sendable {
    struct TranslationReference: Codable, Equatable, Sendable {
        let text: String
        let reviewed: Bool
        var alternatives: [String]? = nil
        var scoring: [String: String]? = nil
    }
    let audio: String
    let expectedText: String?
    let expectedLanguages: [String]?
    let maxWER: Double?
    var expectedTranslations: [String: TranslationReference]? = nil
    var scoring: [String: String]? = nil
    var durationSeconds: Double? = nil
    var condition: String? = nil
}

struct DictationBenchmarkManifest: Codable, Equatable, Sendable {
    let fixtures: [DictationBenchmarkFixture]

    enum Error: Swift.Error, Equatable {
        case duplicateAudio(String)
        case invalidWER(String)
        case invalidProductEvidence
    }

    static func load(from directory: URL,
                     fileManager: FileManager = .default) throws -> [String: DictationBenchmarkFixture] {
        let url = directory.appendingPathComponent("manifest.json")
        guard fileManager.fileExists(atPath: url.path) else { return [:] }
        let data = try Data(contentsOf: url)
        let manifest = try JSONDecoder().decode(Self.self, from: data)
        var result: [String: DictationBenchmarkFixture] = [:]
        for fixture in manifest.fixtures {
            guard result[fixture.audio] == nil else { throw Error.duplicateAudio(fixture.audio) }
            if let maxWER = fixture.maxWER, !maxWER.isFinite || !(0...1).contains(maxWER) {
                throw Error.invalidWER(fixture.audio)
            }
            result[fixture.audio] = fixture
        }
        return result
    }
}

enum DictationBenchmarkScorer {
    static func productFields(runID: String, warmState: String, phraseSeconds: Double,
                              delivery: TextInsertionResult, phaseSeconds: [String: Double]) throws -> [String: Any] {
        let phases: Set<String> = ["capture", "modelLoad", "nativeQueue", "recognition", "cleanup", "translation", "delivery", "drain"]
        guard UUID(uuidString: runID) != nil, ["warm", "cold-start", "post-eviction"].contains(warmState),
              phraseSeconds.isFinite, phraseSeconds > 0,
              let endpoint = delivery.deliveryEndpoint, let hash = delivery.payloadSHA256,
              hash.count == 64, hash.allSatisfy({ "0123456789abcdef".contains($0) }),
              Set(phaseSeconds.keys) == phases,
              phaseSeconds.values.allSatisfy({ $0.isFinite && $0 >= 0 }) else {
            throw DictationBenchmarkManifest.Error.invalidProductEvidence
        }
        return ["runID": runID, "warmState": warmState, "phraseSeconds": phraseSeconds,
                "deliveryEndpoint": endpoint, "outputSHA256": hash, "phaseSeconds": phaseSeconds]
    }
    struct Errors: Equatable, Sendable {
        var substitutions = 0
        var deletions = 0
        var insertions = 0
        var total: Int { substitutions + deletions + insertions }
    }

    static func wordErrors(reference: String, hypothesis: String, language: String? = nil) -> Errors {
        alignment(tokens(reference, language: language), tokens(hypothesis, language: language))
    }

    static func characterErrorRate(reference: String, hypothesis: String) -> Double {
        let left = reference.precomposedStringWithCanonicalMapping.lowercased().filter { $0.isLetter || $0.isNumber }.map(String.init)
        let right = hypothesis.precomposedStringWithCanonicalMapping.lowercased().filter { $0.isLetter || $0.isNumber }.map(String.init)
        guard !left.isEmpty else { return right.isEmpty ? 0 : 1 }
        return Double(alignment(left, right).total) / Double(left.count)
    }

    static func wordErrorRate(reference: String, hypothesis: String, language: String? = nil) -> Double {
        let referenceTokens = tokens(reference, language: language)
        let hypothesisTokens = tokens(hypothesis, language: language)
        guard !referenceTokens.isEmpty else { return hypothesisTokens.isEmpty ? 0 : 1 }
        return Double(alignment(referenceTokens, hypothesisTokens).total) / Double(referenceTokens.count)
    }

    /// Compares normalized region language sequences without treating a
    /// regional BCP-47 tag or repeated adjacent regions as a new language.
    static func preservesLanguageSequence(expected: [String], actual: [String]) -> Bool {
        let expected = compactLanguages(expected)
        let actual = compactLanguages(actual)
        guard !expected.contains(where: { ["", "auto", "und", "unknown"].contains($0) }),
              !actual.contains(where: { ["", "auto", "und", "unknown"].contains($0) }) else { return false }
        return expected == actual
    }

    private static func compactLanguages(_ languages: [String]) -> [String] {
        var result: [String] = []
        for language in languages {
            let base = language.replacingOccurrences(of: "_", with: "-")
                .split(separator: "-").first?.lowercased() ?? ""
            if result.last != base { result.append(base) }
        }
        return result
    }

    private static func tokens(_ text: String, language: String? = nil) -> [String] {
        let text = text.precomposedStringWithCanonicalMapping
        if let language {
            let tokenizer = NLTokenizer(unit: .word)
            tokenizer.setLanguage(NLLanguage(rawValue: language))
            tokenizer.string = text
            return tokenizer.tokens(for: text.startIndex..<text.endIndex).compactMap { range in
                let word = String(text[range]).lowercased()
                return word.contains(where: { $0.isLetter || $0.isNumber }) ? word : nil
            }
        }
        var result: [String] = []
        var word = ""
        func flush() {
            guard !word.isEmpty else { return }
            result.append(word.lowercased())
            word.removeAll(keepingCapacity: true)
        }

        for scalar in text.unicodeScalars {
            if isCJK(scalar) {
                flush()
                result.append(String(scalar))
            } else if CharacterSet.alphanumerics.contains(scalar) {
                word.unicodeScalars.append(scalar)
            } else {
                flush()
            }
        }
        flush()
        return result
    }

    private static func isCJK(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x1100...0x11FF, 0x2E80...0x2FFF, 0x3040...0x30FF,
             0x3400...0x4DBF, 0x4E00...0x9FFF, 0xAC00...0xD7AF,
             0xF900...0xFAFF:
            return true
        default:
            return false
        }
    }

    private static func alignment(_ lhs: [String], _ rhs: [String]) -> Errors {
        var previous = (0...rhs.count).map { Errors(insertions: $0) }
        for (row, left) in lhs.enumerated() {
            var current = [Errors(deletions: row + 1)]
            current.reserveCapacity(rhs.count + 1)
            for (column, right) in rhs.enumerated() {
                var substitution = previous[column]
                if left != right { substitution.substitutions += 1 }
                var insertion = current[column]
                insertion.insertions += 1
                var deletion = previous[column + 1]
                deletion.deletions += 1
                current.append([substitution, insertion, deletion].min { $0.total < $1.total }!)
            }
            previous = current
        }
        return previous[rhs.count]
    }
}
