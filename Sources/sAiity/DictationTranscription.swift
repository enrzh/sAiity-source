import Foundation

/// A region of the captured mono PCM buffer.
///
/// `coveredRange` partitions the source without gaps. `audioRange` is what is
/// sent to the recogniser and may include a small overlap only at a forced hard
/// cut, where a word might otherwise be split in half.
struct DictationSpeechRegion: Equatable, Sendable {
    let audioRange: Range<Int>
    let coveredRange: Range<Int>
    let isForced: Bool

    init(audioRange: Range<Int>, coveredRange: Range<Int>, isForced: Bool = false) {
        self.audioRange = audioRange
        self.coveredRange = coveredRange
        self.isForced = isForced
    }
}

/// Deterministic voice-region splitter for press-to-talk audio.
///
/// It deliberately does not try to infer words or languages. It finds long
/// quiet runs, uses their middle as a natural boundary, and falls back to a
/// bounded hard cut when a speaker never pauses. All source samples belong to
/// exactly one `coveredRange`.
struct SpeechRegionSegmenter: Sendable {
    struct Configuration: Equatable, Sendable {
        var silenceThreshold: Float = 0.012
        var silenceDuration: Duration = .milliseconds(350)
        var boundaryContext: Duration = .milliseconds(200)
        var minimumSpeechDuration: Duration = .milliseconds(700)
        var maximumRegionDuration: Duration = .seconds(10)
        var forcedCutOverlap: Duration = .milliseconds(160)
    }

    static let `default` = Self()
    let configuration: Configuration

    init(configuration: Configuration = .init()) {
        self.configuration = configuration
    }

    func segment(_ samples: [Float], sampleRate: Double) -> [DictationSpeechRegion] {
        guard !samples.isEmpty, sampleRate > 0 else { return [] }

        let silenceSamples = max(1, durationSamples(configuration.silenceDuration, sampleRate: sampleRate))
        let contextSamples = max(0, durationSamples(configuration.boundaryContext, sampleRate: sampleRate))
        let minimumSamples = max(1, durationSamples(configuration.minimumSpeechDuration, sampleRate: sampleRate))
        let maximumSamples = max(minimumSamples, durationSamples(configuration.maximumRegionDuration, sampleRate: sampleRate))
        let overlapSamples = max(0, durationSamples(configuration.forcedCutOverlap, sampleRate: sampleRate))
        let boundaries = silenceBoundaries(in: samples,
                                           minimumLength: silenceSamples,
                                           context: contextSamples)

        var result: [DictationSpeechRegion] = []
        var start = 0
        while start < samples.count {
            let maximumEnd = min(samples.count, start + maximumSamples)
            let naturalEnd = boundaries.first { boundary in
                boundary > start + minimumSamples
                    && boundary <= maximumEnd
                    && samples.count - boundary >= minimumSamples
            }

            if let naturalEnd {
                result.append(DictationSpeechRegion(audioRange: start..<naturalEnd,
                                                     coveredRange: start..<naturalEnd))
                start = naturalEnd
                continue
            }

            if maximumEnd == samples.count {
                appendFinalRegion(start: start,
                                  end: samples.count,
                                  minimumSamples: minimumSamples,
                                  maximumSamples: maximumSamples,
                                  to: &result)
                break
            }

            // A hard cut gets a small look-ahead. The next region still owns the
            // samples from `maximumEnd` onward, so no input is lost.
            let audioEnd = min(samples.count, maximumEnd + overlapSamples)
            result.append(DictationSpeechRegion(audioRange: start..<audioEnd,
                                                coveredRange: start..<maximumEnd,
                                                isForced: true))
            start = maximumEnd
        }
        return result
    }

    private func appendFinalRegion(start: Int,
                                   end: Int,
                                   minimumSamples: Int,
                                   maximumSamples: Int,
                                   to regions: inout [DictationSpeechRegion]) {
        guard end > start else { return }
        let length = end - start
        // Avoid sending a useless tail to a model after a natural boundary. It
        // remains covered by the previous region instead.
        if length < minimumSamples,
           var previous = regions.last,
           previous.coveredRange.count + length <= maximumSamples {
            previous = DictationSpeechRegion(audioRange: previous.audioRange.lowerBound..<end,
                                             coveredRange: previous.coveredRange.lowerBound..<end,
                                             isForced: previous.isForced)
            regions[regions.count - 1] = previous
        } else {
            regions.append(DictationSpeechRegion(audioRange: start..<end,
                                                 coveredRange: start..<end))
        }
    }

    private func silenceBoundaries(in samples: [Float],
                                   minimumLength: Int,
                                   context: Int) -> [Int] {
        var runs: [Range<Int>] = []
        var runStart: Int?
        for index in samples.indices {
            if abs(samples[index]) <= configuration.silenceThreshold {
                if runStart == nil { runStart = index }
            } else {
                if let runStart {
                    if index - runStart >= minimumLength { runs.append(runStart..<index) }
                }
                runStart = nil
            }
        }
        if let runStart, samples.count - runStart >= minimumLength {
            runs.append(runStart..<samples.count)
        }

        return runs.compactMap { run in
            guard run.lowerBound > 0, run.upperBound < samples.count else { return nil }
            let middle = run.lowerBound + run.count / 2
            let lower = run.lowerBound + min(context, run.count / 2)
            let upper = run.upperBound - min(context, run.count / 2)
            return min(max(middle, lower), upper)
        }
    }

    private func durationSamples(_ duration: Duration, sampleRate: Double) -> Int {
        let components = duration.components
        let seconds = Double(components.seconds)
            + Double(components.attoseconds) / 1_000_000_000_000_000_000
        return Int((seconds * sampleRate).rounded())
    }

}

struct DictationRegionTranscript: Equatable, Sendable {
    let text: String
    let language: String?
}

/// Language information kept internal to the dictation pipeline.
struct DictationLanguageMetadata: Equatable, Sendable {
    let regionLanguages: [String?]
    let regionTexts: [String]
    let dominantLanguage: String?
    let containsMultipleLanguages: Bool

    init(regions: [DictationRegionTranscript]) {
        regionLanguages = regions.map(\.language)
        regionTexts = regions.map(\.text)

        var counts: [String: Int] = [:]
        var firstCode: [String: String] = [:]
        var codeOrder: [String] = []
        for language in regionLanguages.compactMap({ $0 }) {
            let code = Self.baseLanguage(language)
            guard !code.isEmpty, code != "auto" else { continue }
            if !counts.keys.contains(code) { codeOrder.append(code) }
            counts[code, default: 0] += 1
            firstCode[code] = firstCode[code] ?? language
        }
        let dominantCode = codeOrder.reduce(nil as String?) { best, code in
            guard let best else { return code }
            return counts[code, default: 0] > counts[best, default: 0] ? code : best
        }
        dominantLanguage = dominantCode.flatMap { firstCode[$0] }

        let languageMix = counts.count > 1
        let scriptMix = Set(regions.compactMap { Self.scriptFamily(in: $0.text) }).count > 1
        containsMultipleLanguages = languageMix || scriptMix
    }

    init(language: String?, text: String) {
        self.init(regions: [DictationRegionTranscript(text: text, language: language)])
    }

    private static func baseLanguage(_ language: String) -> String {
        language.replacingOccurrences(of: "_", with: "-")
            .split(separator: "-")
            .first?
            .lowercased() ?? ""
    }

    private enum ScriptFamily: Hashable {
        case latin, cyrillic, arabic, devanagari, hangul, han, kana, other
    }

    private static func scriptFamily(in text: String) -> ScriptFamily? {
        for scalar in text.unicodeScalars {
            switch scalar.value {
            case 0x0041...0x024F, 0x1E00...0x1EFF: return .latin
            case 0x0400...0x052F: return .cyrillic
            case 0x0600...0x06FF, 0x0750...0x077F, 0x08A0...0x08FF: return .arabic
            case 0x0900...0x097F: return .devanagari
            case 0x1100...0x11FF, 0xAC00...0xD7AF: return .hangul
            case 0x3040...0x30FF: return .kana
            case 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF: return .han
            default: continue
            }
        }
        return nil
    }
}

struct DictationTranscriptionResult: Equatable, Sendable {
    let regions: [DictationRegionTranscript]
    let text: String
    let languageMetadata: DictationLanguageMetadata

    init(regions: [DictationRegionTranscript]) {
        self.regions = regions
        self.text = DictationTranscriptMerger.merge(regions.map(\.text))
        self.languageMetadata = DictationLanguageMetadata(regions: regions)
    }

    init(text: String, language: String?) {
        self.init(regions: [DictationRegionTranscript(text: text, language: language)])
    }
}

/// Joins sequential recogniser results without an LLM.
enum DictationTranscriptMerger {
    static func merge(_ texts: [String]) -> String {
        texts.reduce(into: "") { output, text in
            append(text, to: &output)
        }
    }

    private struct Unit {
        let start: String.Index
        let end: String.Index
        let key: String
    }

    private static func append(_ value: String, to output: inout String) {
        let next = normalizedRecognizerText(value)
        guard !next.isEmpty else { return }
        guard !output.isEmpty else {
            output = next
            return
        }

        let left = units(in: output)
        let right = units(in: next)
        var overlapEnd = next.startIndex
        if !left.isEmpty, !right.isEmpty {
            for count in stride(from: min(left.count, right.count), through: 1, by: -1) {
                let leftStart = left[left.count - count].start
                let leftEnd = left[left.count - 1].end
                let rightEnd = right[count - 1].end
                let leftKey = canonical(output[leftStart..<leftEnd])
                let rightKey = canonical(next[next.startIndex..<rightEnd])
                guard !leftKey.isEmpty, leftKey == rightKey else { continue }
                overlapEnd = rightEnd
                break
            }
        }

        let remainder = next[overlapEnd...].trimmingCharacters(in: .whitespacesAndNewlines)
        guard !remainder.isEmpty else { return }
        if needsSpace(between: output, and: remainder) {
            output += " "
        }
        output += remainder
    }

    /// Whisper can emit this transport marker for a silent span. It is not
    /// spoken text, and replacing it with a space preserves the boundary
    /// between valid text on either side without inventing a new sentence.
    private static func normalizedRecognizerText(_ value: String) -> String {
        var text = value
        text = text.replacingOccurrences(
            of: #"(?i)\[\s*BLANK[ _-]+AUDIO\s*\]"#,
            with: " ", options: .regularExpression)
        text = text.replacingOccurrences(of: #"[ \t]+"#, with: " ", options: .regularExpression)
        text = text.replacingOccurrences(of: #"[ \t]+([,.;!?])"#, with: "$1", options: .regularExpression)
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func units(in text: String) -> [Unit] {
        var result: [Unit] = []
        var index = text.startIndex
        while index < text.endIndex {
            let character = text[index]
            if character.isWhitespace {
                index = text.index(after: index)
                continue
            }
            let start = index
            if character.isLetter || character.isNumber {
                index = text.index(after: index)
                if !isCJK(character) {
                    while index < text.endIndex,
                          text[index].isLetter || text[index].isNumber || text[index] == "'" || text[index] == "-" {
                        index = text.index(after: index)
                    }
                }
            } else {
                index = text.index(after: index)
            }
            result.append(Unit(start: start, end: index, key: canonical(text[start..<index])))
        }
        return result
    }

    private static func canonical<S: StringProtocol>(_ value: S) -> String {
        String(value).filter { !$0.isWhitespace }.lowercased()
    }

    private static func needsSpace(between left: String, and right: String) -> Bool {
        guard let previous = left.last, let next = right.first else { return false }
        guard !previous.isWhitespace, !next.isWhitespace else { return false }
        if next.isPunctuation || previous == "(" || previous == "[" || previous == "{" {
            return false
        }
        if "，。！？、；：".contains(previous) { return false }
        guard previous.isLetter || previous.isNumber,
              next.isLetter || next.isNumber else { return false }
        return !(isCJK(previous) && isCJK(next))
    }

    private static func isCJK(_ character: Character) -> Bool {
        character.unicodeScalars.contains { scalar in
            switch scalar.value {
            case 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF,
                 0x3040...0x30FF, 0xAC00...0xD7AF:
                return true
            default:
                return false
            }
        }
    }
}
