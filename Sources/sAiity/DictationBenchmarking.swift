import Foundation

struct DictationBenchmarkFixture: Codable, Equatable, Sendable {
    let audio: String
    let expectedText: String?
    let expectedLanguages: [String]?
    let maxWER: Double?
}

struct DictationBenchmarkManifest: Codable, Equatable, Sendable {
    let fixtures: [DictationBenchmarkFixture]

    enum Error: Swift.Error, Equatable {
        case duplicateAudio(String)
        case invalidWER(String)
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
    static func wordErrorRate(reference: String, hypothesis: String) -> Double {
        let referenceTokens = tokens(reference)
        let hypothesisTokens = tokens(hypothesis)
        guard !referenceTokens.isEmpty else { return hypothesisTokens.isEmpty ? 0 : 1 }
        return Double(editDistance(referenceTokens, hypothesisTokens)) / Double(referenceTokens.count)
    }

    /// Compares normalized region language sequences without treating a
    /// regional BCP-47 tag or repeated adjacent regions as a new language.
    static func preservesLanguageSequence(expected: [String], actual: [String]) -> Bool {
        let expected = compactLanguages(expected)
        let actual = compactLanguages(actual)
        guard !expected.isEmpty else { return actual.isEmpty }
        var index = 0
        for language in actual where index < expected.count {
            if language == expected[index] { index += 1 }
        }
        return index == expected.count
    }

    private static func compactLanguages(_ languages: [String]) -> [String] {
        var result: [String] = []
        for language in languages {
            let base = language.replacingOccurrences(of: "_", with: "-")
                .split(separator: "-").first?.lowercased() ?? ""
            guard !base.isEmpty, base != "auto" else { continue }
            if result.last != base { result.append(base) }
        }
        return result
    }

    private static func tokens(_ text: String) -> [String] {
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

    private static func editDistance(_ lhs: [String], _ rhs: [String]) -> Int {
        var previous = Array(0...rhs.count)
        for (row, left) in lhs.enumerated() {
            var current = [row + 1]
            current.reserveCapacity(rhs.count + 1)
            for (column, right) in rhs.enumerated() {
                let substitution = previous[column] + (left == right ? 0 : 1)
                let insertion = current[column] + 1
                let deletion = previous[column + 1] + 1
                current.append(min(substitution, insertion, deletion))
            }
            previous = current
        }
        return previous[rhs.count]
    }
}
