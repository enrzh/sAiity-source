import Foundation
import Testing

@testable import sAiity

@Suite("Caption processing")
struct CaptionProcessingTests {
    @Test("Latin clauses receive one boundary space")
    func latinSpacing() {
        #expect(CaptionTextMerger.join(["Hallo", "world"]) == "Hallo world")
    }

    @Test("CJK clauses do not receive an invented space")
    func cjkSpacing() {
        #expect(CaptionTextMerger.join(["你好", "世界"]) == "你好世界")
    }

    @Test("Mixed script boundaries stay readable without duplicating punctuation")
    func mixedScriptJoining() {
        #expect(CaptionTextMerger.join(["Hallo", "world", "你好", "世界"]) == "Hallo world你好世界")
        #expect(CaptionTextMerger.join(["hello world", "world again"]) == "hello world again")
    }

    @Test("Cumulative punctuation becomes final and leaves a volatile tail")
    func cumulativePunctuation() {
        let start = Date(timeIntervalSince1970: 100)
        var reconciler = CaptionTranscriptReconciler(now: start)

        let first = reconciler.update(cumulativeText: "Ich denke we should", now: start)
        #expect(first.finalText == nil)
        #expect(first.volatileText == "Ich denke we should")

        let second = reconciler.update(cumulativeText: "Ich denke we should ship.",
                                       now: start.addingTimeInterval(1))
        #expect(second.finalText == "Ich denke we should ship.")
        #expect(second.volatileText == nil)
    }

    @Test("A shorter cumulative callback cannot replay a committed prefix")
    func staleShorterCallbackIsIgnored() {
        let start = Date(timeIntervalSince1970: 100)
        var reconciler = CaptionTranscriptReconciler(now: start)
        _ = reconciler.update(cumulativeText: "This sentence is complete.", now: start)

        let stale = reconciler.update(cumulativeText: "This sentence", now: start.addingTimeInterval(1))
        #expect(stale == .none)
        #expect(reconciler.committedText == "This sentence is complete.")
    }

    @Test("The volatile tail can be corrected without changing settled text")
    func volatileCorrection() {
        let start = Date(timeIntervalSince1970: 100)
        var reconciler = CaptionTranscriptReconciler(now: start)
        _ = reconciler.update(cumulativeText: "Please open the calender", now: start)

        let corrected = reconciler.update(cumulativeText: "Please open the calendar", now: start.addingTimeInterval(0.2))
        #expect(corrected.finalText == nil)
        #expect(corrected.volatileText == "Please open the calendar")
    }

    @Test("Repeated stable partials can finalize an unpunctuated clause")
    func stablePartialsFinalize() {
        let start = Date(timeIntervalSince1970: 100)
        var reconciler = CaptionTranscriptReconciler(now: start)
        let text = "This is a long unpunctuated caption clause"
        _ = reconciler.update(cumulativeText: text, now: start)
        _ = reconciler.update(cumulativeText: text, now: start.addingTimeInterval(0.5))
        let result = reconciler.update(cumulativeText: text, now: start.addingTimeInterval(1))
        #expect(result.finalText != nil)
        #expect(result.finalText?.hasPrefix("This is") == true)
    }

    @Test("Speech activity uses onset hysteresis, pre-roll, and a single gap")
    func activityBoundariesAndConservation() {
        var configuration = SpeechActivityDetector.Configuration()
        configuration.minimumSpeechMs = 100
        configuration.preRollMs = 200
        configuration.postRollMs = 300
        configuration.holdMs = 300
        var detector = SpeechActivityDetector(configuration: configuration)
        var events: [SpeechActivityEvent] = []
        let rate: Float = 1_000

        for _ in 0..<5 { if let event = detector.process(rms: 0.001, frames: 100, sampleRate: rate) { events.append(event) } }
        for _ in 0..<2 { if let event = detector.process(rms: 0.05, frames: 100, sampleRate: rate) { events.append(event) } }
        for _ in 0..<4 { if let event = detector.process(rms: 0.001, frames: 100, sampleRate: rate) { events.append(event) } }

        #expect(detector.observedSampleCount == 1_100)
        #expect(events.count == 2)
        guard events.count == 2 else { return }
        if case .speechStarted(let range) = events[0] {
            #expect(range.lowerBound < 500, "pre-roll should include audio before onset")
        } else {
            Issue.record("expected speech onset")
        }
        if case .gap = events[1] {
            // expected
        } else {
            Issue.record("expected one speech gap")
        }
    }

    @Test("Endpoint policy combines punctuation, age, and stable partials")
    func endpointEvidence() {
        #expect(CaptionEndpointPolicy.decide(text: "Hallo.", age: 0,
                                             repeatedPartials: 1,
                                             hasSentenceTerminator: true,
                                             maximumAge: 3.5,
                                             minimumCharacters: 28,
                                             maximumCharacters: 110) == .finalize)
        #expect(CaptionEndpointPolicy.decide(text: "short", age: 10,
                                             repeatedPartials: 4,
                                             hasSentenceTerminator: false,
                                             maximumAge: 3.5,
                                             minimumCharacters: 28,
                                             maximumCharacters: 110) == .wait)
        #expect(CaptionEndpointPolicy.decide(text: "This is a sufficiently long stable caption",
                                             age: 1,
                                             repeatedPartials: 3,
                                             hasSentenceTerminator: false,
                                             maximumAge: 3.5,
                                             minimumCharacters: 28,
                                             maximumCharacters: 110) == .finalize)
    }
}
