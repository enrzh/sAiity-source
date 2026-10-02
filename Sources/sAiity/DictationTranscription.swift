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

        // A press that captured only silence should never enter a recognizer.
        // Besides wasting a full decode, silent audio is where Whisper is most
        // likely to emit transport markers or hallucinated words.
        guard samples.contains(where: { abs($0) > configuration.silenceThreshold }) else {
            return []
        }

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
    let overlapsPreviousAudio: Bool

    init(text: String, language: String?, overlapsPreviousAudio: Bool = false) {
        self.text = text
        self.language = language
        self.overlapsPreviousAudio = overlapsPreviousAudio
    }
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
        let maximum = dominantCode.map { counts[$0, default: 0] } ?? 0
        dominantLanguage = counts.values.filter { $0 == maximum }.count == 1
            ? dominantCode.flatMap { firstCode[$0] } : nil

        let languageMix = counts.count > 1
        var scripts = regions.reduce(into: Set<ScriptFamily>()) { $0.formUnion(Self.scriptFamilies(in: $1.text)) }
        if scripts.contains(.kana) { scripts.remove(.han) }
        let scriptMix = scripts.count > 1
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

    private static func scriptFamilies(in text: String) -> Set<ScriptFamily> {
        var result = Set<ScriptFamily>()
        for scalar in text.unicodeScalars {
            switch scalar.value {
            case 0x0041...0x024F, 0x1E00...0x1EFF: result.insert(.latin)
            case 0x0400...0x052F: result.insert(.cyrillic)
            case 0x0600...0x06FF, 0x0750...0x077F, 0x08A0...0x08FF: result.insert(.arabic)
            case 0x0900...0x097F: result.insert(.devanagari)
            case 0x1100...0x11FF, 0xAC00...0xD7AF: result.insert(.hangul)
            case 0x3040...0x30FF: result.insert(.kana)
            case 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF: result.insert(.han)
            default: continue
            }
        }
        if result.contains(.kana) { result.remove(.han) }
        return result
    }
}

/// Refines obvious script switches inside one recognizer region. Audio models
/// do not expose reliable mid-region language tags, but script transitions are
/// unambiguous and cost no second decode. Same-script switches require confident
/// text evidence; short filler/name windows never override an audio language tag.
private enum DictationCodeSwitching {
    private enum Script: Hashable {
        case latin, cyrillic, arabic, devanagari, hangul, han, kana
    }

    static func split(_ region: DictationRegionTranscript) -> [DictationRegionTranscript] {
        let scripts = Set(region.text.compactMap(script(for:)))
        if scripts == [.latin] {
            let detected = CaptionLanguageSpanDetector.analyze(region.text,
                fallbackLanguage: region.language ?? "und")
            let languages = Set(detected.compactMap { $0.language }.filter { $0 != "und" })
            // Tiny filler/name windows are frequently classified as unrelated
            // Latin languages. Require evidence before contradicting audio tags.
            let supported = detected.allSatisfy { span in
                if let original = region.language, let language = span.language,
                   TranslationLanguage.isSame(original, as: language) { return true }
                guard span.text.split(whereSeparator: { $0.isWhitespace }).count >= 3,
                      let reading = LanguageRecognizerPool.shared.classify(span.text),
                      reading.probability >= 0.85 else { return false }
                return TranslationLanguage.isSame(reading.language.rawValue, as: span.language ?? "und")
            }
            if detected.count > 1, languages.count > 1, supported {
                return detected.map { .init(text: $0.text, language: $0.language == "und" ? nil : $0.language) }
            }
        }
        let characters = Array(region.text)
        guard characters.count > 1 else { return [region] }
        var parts: [(String, Script)] = []
        var current = ""
        var currentScript: Script?

        func flush() {
            guard let script = currentScript,
                  !current.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                current.removeAll(keepingCapacity: true)
                currentScript = nil
                return
            }
            parts.append((current, script))
            current.removeAll(keepingCapacity: true)
            currentScript = nil
        }

        for character in characters {
            let nextScript = script(for: character)
            let japaneseBoundary = (nextScript == .han && currentScript == .kana)
                || (nextScript == .kana && currentScript == .han)
            if let nextScript, let currentScript, nextScript != currentScript, !japaneseBoundary {
                flush()
            }
            if currentScript == nil, let nextScript {
                currentScript = nextScript
            }
            current.append(character)
        }
        flush()
        guard !parts.isEmpty else { return [region] }
        if parts.count == 1, region.language == nil || ["auto", "und"].contains(region.language ?? "") {
            return [region]
        }

        return parts.map { text, scriptFamily in
            DictationRegionTranscript(text: text.trimmingCharacters(in: .whitespacesAndNewlines),
                                      language: language(for: scriptFamily,
                                                         original: region.language,
                                                         text: text))
        }
    }

    private static func language(for scriptFamily: Script,
                                 original: String?,
                                 text: String) -> String? {
        let base = original?.replacingOccurrences(of: "_", with: "-")
            .split(separator: "-").first.map(String.init)?.lowercased()
        switch scriptFamily {
        case .han:
            if base == "ja" || base == "zh" { return original }
        case .kana:
            if base == "ja" { return original }
        case .hangul:
            if base == "ko" { return original }
        case .cyrillic:
            if let base, ["ru", "uk", "bg", "sr", "mk", "be"].contains(base) { return original }
        case .arabic:
            if let base, ["ar", "fa", "ur", "ps"].contains(base) { return original }
        case .devanagari:
            if let base, ["hi", "mr", "ne"].contains(base) { return original }
        case .latin:
            if let base, ["en", "de", "fr", "es", "pt", "it", "nl", "sv", "da", "no", "fi",
                          "pl", "cs", "sk", "ro", "hu", "tr", "vi", "id", "ms", "tl",
                          "hr", "sl", "et", "lv", "lt", "ca", "eu", "gl", "af", "sw"].contains(base) {
                return original
            }
        }
        guard let reading = LanguageRecognizerPool.shared.classify(text), reading.probability >= 0.85 else { return nil }
        return reading.language.rawValue
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

struct DictationTranscriptionResult: Equatable, Sendable {
    let regions: [DictationRegionTranscript]
    let text: String
    let languageMetadata: DictationLanguageMetadata

    /// Translation can batch adjacent regions with the same source language,
    /// while keeping a separate run for every code-switch.
    var translationRuns: [DictationRegionTranscript] {
        var result: [DictationRegionTranscript] = []
        result.reserveCapacity(regions.count)
        for region in regions {
            if let last = result.last,
               let lastLanguage = last.language,
               let language = region.language,
               TranslationLanguage.isSame(lastLanguage, as: language) {
                result[result.count - 1] = .init(
                    text: DictationTranscriptMerger.merge([last.text, region.text]),
                    language: lastLanguage)
            } else {
                result.append(region)
            }
        }
        return result
    }

    init(regions: [DictationRegionTranscript]) {
        var accepted: [DictationRegionTranscript] = []
        var joined = ""
        for region in regions {
            let text = region.overlapsPreviousAudio
                ? DictationTranscriptMerger.removingOverlap(region.text, after: joined) : region.text
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            accepted.append(.init(text: text, language: region.language))
            joined = DictationTranscriptMerger.merge([joined, text])
        }
        let refined = accepted.flatMap(DictationCodeSwitching.split)
        self.regions = refined
        self.text = DictationTranscriptMerger.merge(refined.map(\.text))
        self.languageMetadata = DictationLanguageMetadata(regions: refined)
    }

    init(text: String, language: String?) {
        self.init(regions: [DictationRegionTranscript(text: text, language: language)])
    }
}

/// Joins sequential recogniser results without an LLM.
enum DictationTranscriptMerger {
    static func merge(_ texts: [String], removingAudioOverlap: Bool = false) -> String {
        texts.reduce(into: "") { output, text in
            append(text, to: &output, removingAudioOverlap: removingAudioOverlap)
        }
    }

    private struct Unit {
        let start: String.Index
        let end: String.Index
        let key: String
    }

    static func removingOverlap(_ value: String, after output: String) -> String {
        let next = normalizedRecognizerText(value)
        guard !output.isEmpty else { return next }
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

        return next[overlapEnd...].trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func append(_ value: String, to output: inout String, removingAudioOverlap: Bool) {
        let remainder = removingAudioOverlap ? removingOverlap(value, after: output) : normalizedRecognizerText(value)
        guard !remainder.isEmpty else { return }
        if let last = output.last, let first = remainder.first {
            output += CaptionTextMerger.separator(after: last, before: first)
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
