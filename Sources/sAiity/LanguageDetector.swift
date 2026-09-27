import Foundation
import NaturalLanguage

/// Detects which language is actually being spoken, from the transcript text.
///
/// Why text and not audio: the Speech framework exposes **no** public
/// language-identification API. `SpeechTranscriber` takes exactly one locale and
/// no Result type carries a language. (Apple has built `Speech.LanguageDetector`
/// — it is present in the binary as SPI — but no `.swiftinterface` declares it,
/// so it cannot be imported. Worth re-checking each OS release.)
///
/// Why not `.transcriptionConfidence`: measured, and it does not work. Across 26
/// utterances and 6 voices per language, German-into-German scored 0.718–0.996
/// and English-into-German scored 0.474–0.889 — overlapping ranges. Confidence
/// tracks *audio and speaker quality*, not language: a crisp English speaker
/// outscores a mumbling German one. The usable threshold window was ~0.09 wide
/// on clean synthetic speech and would close entirely on a real microphone.
///
/// `NLLanguageRecognizer` over the emitted text was 26/26 correct with p ≥ 0.98.
/// The gates below come from where it *does* fail, measured:
///
///   - Short utterances are unreliable: "Ja." → Finnish p=0.59, "Okay." → English
///     p=0.39, "Update." → Romanian p=0.26. Hence `minCharacters`.
///   - Numbers and proper nouns are language-neutral noise: "23. April 2026." →
///     Dutch, "Enrico Zhang." → Portuguese, "RE20262933." → Czech.
///   - English loanwords are *not* a problem, which was the expected failure and
///     turned out not to be one: "Der Product Owner will ein Feedback Loop mit
///     dem Stakeholder." → German p=1.000. German function words dominate.
///   - On accumulated text it is rock solid: p=1.000 from ~50 characters on.
///
/// So: run it over the *accumulated* transcript, never a single line, and require
/// agreement twice before acting.
struct LanguageDetector {
    /// Below this much accumulated text, detection is noise.
    var minCharacters = 60
    /// Dominant-language probability required to count as a reading.
    var minProbability = 0.90
    /// Consecutive agreeing readings before the result is reported. Stops the
    /// bubble flip-flopping mid-meeting.
    var stability = 2

    private var lines: [String] = []
    private var candidate: String?
    private var agreements = 0
    private(set) var detected: String?

    /// Feed one committed line. Returns a language code only at the moment it
    /// *changes*, so the caller can act on transitions rather than poll.
    mutating func add(_ line: String) -> String? {
        lines.append(line)
        if lines.count > 8 { lines.removeFirst(lines.count - 8) }

        // Window by RECENT LINES, not by a character budget. A character window
        // does not age anything out until it overflows, so the opening language
        // of a session keeps outvoting the current one — measured: three English
        // sentences after one German one still read as German, because the
        // German was never evicted. Taking the newest lines that reach
        // `minCharacters` lets a real switch win within two or three lines while
        // still refusing to judge on a fragment.
        var window: [String] = []
        var count = 0
        for l in lines.reversed() {
            window.append(l)
            count += l.count
            if count >= minCharacters { break }
        }
        guard count >= minCharacters else { return nil }
        let text = window.reversed().joined(separator: " ")

        guard let hypothesis = LanguageRecognizerPool.shared.classify(text) else { return nil }
        guard hypothesis.probability >= minProbability else { return nil }

        let code = hypothesis.language.rawValue
        if code == candidate {
            agreements += 1
        } else {
            candidate = code
            agreements = 1
        }
        guard agreements >= stability, code != detected else { return nil }
        detected = code
        return code
    }

    mutating func reset() {
        lines.removeAll()
        candidate = nil
        agreements = 0
        detected = nil
    }

    /// Detect one sufficiently complete caption without using the session's
    /// accumulated dominant language. Live captions can switch languages
    /// between sentences, so the session result is only a fallback for short
    /// or ambiguous lines.
    static func languageCode(in text: String,
                             minimumCharacters: Int = 18,
                             minimumProbability: Double = 0.80) -> String? {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.count >= minimumCharacters else { return nil }
        guard let hypothesis = LanguageRecognizerPool.shared.classify(value),
              hypothesis.probability >= minimumProbability else { return nil }
        return hypothesis.language.rawValue
    }

    /// The installed transcriber locale that best matches a detected language,
    /// or nil when no model for it is on disk. Detection can only ever choose
    /// among installed models.
    static func installedLocale(for languageCode: String,
                                among installed: [String]) -> String? {
        // Exact language match, preferring the plain region-matched form.
        let matches = installed.filter { $0.split(separator: "-").first.map(String.init) == languageCode }
        guard !matches.isEmpty else { return nil }
        // Prefer the user's region if present, else the shortest identifier.
        let region = Locale.current.region?.identifier
        if let r = region, let exact = matches.first(where: { $0.hasSuffix("-\(r)") }) { return exact }
        return matches.sorted { $0.count < $1.count }.first
    }
}
