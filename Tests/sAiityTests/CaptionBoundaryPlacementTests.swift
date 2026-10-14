import Foundation
import Testing

@testable import sAiity

/// `splitLatin` scans word boundaries for a code-switch, which is quadratic by
/// construction: every candidate classifies two fresh strings. Long runs are
/// therefore scanned on a coarse grid and the neighbourhood of the best coarse
/// hit refined, which is a subsampling and so could in principle move a
/// boundary.
///
/// These pin the decisions that must not move, checked against the span
/// languages and texts rather than "a boundary was detected", so a coarser scan
/// that still found *a* boundary could not pass while showing the wrong split.
///
/// Scope of the claim: the exhaustive-versus-coarse agreement was established
/// by sweeping a code-switch through all 39 positions of a 39-word run, and these
/// cases are the readable subset of that. They are not a proof for every input,
/// and they would not catch a stride that happened to suit the sentences below.
@Suite("Caption boundary placement")
struct CaptionBoundaryPlacementTests {
    /// The single-language case, at the length where subsampling switches on.
    /// There is no boundary here, so a coarse scan has to conclude that on its
    /// own — which is the whole reason the coarse pass exists.
    @Test("a long single-language run is not split")
    func longSingleLanguageRun() {
        let text = Array(repeating: "the ordinary english sentence has no other language in it ", count: 6)
            .joined(separator: " ")
        let spans = CaptionLanguageSpanDetector.analyze(text, fallbackLanguage: "en")

        #expect(!CaptionLanguageSpanDetector.isMixed(spans))
        #expect(spans.count == 1)
        #expect(spans[0].text == text)
    }

    /// A boundary at the very start. The coarse grid steps by four, so this is
    /// the case a naive stride would miss.
    @Test("a boundary at the start of a long run is found")
    func boundaryAtStart() {
        let spans = CaptionLanguageSpanDetector.analyze(
            "ich denke we should ship this today and then review the schedule with the team again",
            fallbackLanguage: "en")

        #expect(CaptionLanguageSpanDetector.isMixed(spans))
        #expect(spans.first?.language == "de")
        #expect(spans.last?.language == "en")
    }

    /// A boundary at the very end — the other end a stride steps over, and the
    /// one the last-position check exists for.
    @Test("a boundary at the end of a long run is found")
    func boundaryAtEnd() {
        let spans = CaptionLanguageSpanDetector.analyze(
            "we should ship this today and review the schedule with everyone again next week wollen wir das Budget verdoppeln",
            fallbackLanguage: "en")

        #expect(CaptionLanguageSpanDetector.isMixed(spans))
        #expect(spans.last?.language == "de")
        #expect(spans.last?.text.contains("Budget") == true)
    }

    /// Between coarse samples. Both sides long enough that neither is a stub.
    @Test("a boundary between coarse samples is found")
    func boundaryBetweenSamples() {
        let spans = CaptionLanguageSpanDetector.analyze(
            "we should ship this today and review the schedule "
            + "wollten wir das Budget verdoppeln und die Rechnung nochmal prüfen",
            fallbackLanguage: "en")

        #expect(CaptionLanguageSpanDetector.isMixed(spans))
        #expect(spans.last?.language == "de")
    }

    /// Nothing above may split a run whose two halves are the same language,
    /// however long it is and however the words fall.
    @Test("a long same-language run with a loanword is not split")
    func longRunWithLoanword() {
        let spans = CaptionLanguageSpanDetector.analyze(
            "we should ship the roadmap and review the budget and double the schedule "
            + "and confirm the invoice and then we should tell the team about it",
            fallbackLanguage: "en")

        #expect(!CaptionLanguageSpanDetector.isMixed(spans))
    }
}
