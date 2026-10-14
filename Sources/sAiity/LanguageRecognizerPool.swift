import Foundation
import NaturalLanguage

/// `NLLanguageRecognizer` instances, kept for reuse.
///
/// Constructing one is not cheap — it is roughly a third of the cost of a
/// short classify — and classification happens on two hot paths. Dictation
/// cleanup builds three per dictation: once in the deterministic pass to pick
/// the filler and formatting tables, then once per side in the language check.
/// Caption language-span analysis builds one per candidate split boundary, and
/// a clause has dozens of candidates, none of which repeat — so the reading
/// cache does not help and every candidate pays full price. Measured on a
/// 28-word code-switching clause, cold, that is about 20 ms.
///
/// The class is not documented as thread-safe, so a recognizer is checked out
/// for the duration of one classification and handed back, rather than shared.
final class LanguageRecognizerPool: @unchecked Sendable {
    static let shared = LanguageRecognizerPool()

    private let lock = NSLock()
    private var available: [NLLanguageRecognizer] = []
    private var hypothesisCache = BoundedCache<String, [NLLanguage: Double]>(capacity: 256)

    func classify(_ text: String) -> (language: NLLanguage, probability: Double)? {
        withRecognizer(for: text) { recognizer in
            guard let language = recognizer.dominantLanguage else { return nil }
            return (language, recognizer.languageHypotheses(withMaximum: 1)[language] ?? 0)
        }
    }

    /// Script variants share a source language, but remain separate output targets.
    func hypotheses(in text: String) -> [NLLanguage: Double] {
        if let cached = lock.withLock({ hypothesisCache[text] }) { return cached }
        let result = withRecognizer(for: text) { $0.languageHypotheses(withMaximum: 8) }
        // Keep repeated phrase analysis cheap without retaining oversized transcript lines.
        if text.utf8.count <= 16_384 {
            lock.withLock { hypothesisCache[text] = result }
        }
        return result
    }

    private func withRecognizer<T>(for text: String, _ read: (NLLanguageRecognizer) -> T) -> T {
        lock.lock()
        let recognizer = available.popLast() ?? NLLanguageRecognizer()
        lock.unlock()

        // Reset before processing, not just after. `processString("")` is a
        // no-op that leaves the *previous* caller's hypotheses in place, so
        // without this an empty string would be reported in whatever language
        // was classified before it — and callers that use the result to pick
        // behaviour, not just to label output, would act on a stale answer.
        recognizer.reset()
        recognizer.processString(text)
        // Read every hypothesis the caller needs before the recognizer goes
        // back, since the next borrower overwrites them.
        let result = read(recognizer)

        lock.lock()
        // A small cap, so a burst of parallel work does not turn the pool into
        // a leak of recognizers that are never needed again.
        if available.count < 4 { available.append(recognizer) }
        lock.unlock()
        return result
    }

    /// The dominant language, or nil when the text is not classifiable.
    func dominantLanguage(_ text: String) -> NLLanguage? {
        classify(text)?.language
    }

#if SAIITY_TEST_HOOKS
    var availableCountForTests: Int {
        lock.lock()
        defer { lock.unlock() }
        return available.count
    }
#endif
}
