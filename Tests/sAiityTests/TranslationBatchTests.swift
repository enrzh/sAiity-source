import Foundation
import Testing

@testable import sAiity

@Suite struct TranslationBatchTests {
    @Test("MADLAD retries a rejected language once and stops after the second verdict")
    func pql4BoundedRetry() throws {
        var temperatures: [Float] = []
        let recovered = try MADLADTranslator.validatedTranslation("Guten Morgen", target: "en") { temperature in
            temperatures.append(temperature)
            return temperatures.count == 1 ? "Guten Morgen" : "Good morning"
        }
        #expect(recovered == "Good morning")
        #expect(temperatures.count == 2)
        #expect(temperatures.first == 0)
        #expect(temperatures.last! > 0 && temperatures.last! <= 0.2)
        var rejectedCalls = 0
        #expect(try MADLADTranslator.validatedTranslation("Guten Morgen", target: "en") { _ in
            rejectedCalls += 1
            return "Guten Morgen"
        } == nil)
        #expect(rejectedCalls == 2)
        var emptyCalls = 0
        #expect(try MADLADTranslator.validatedTranslation("Guten Morgen", target: "en") { _ in
            emptyCalls += 1
            return ""
        } == nil)
        #expect(emptyCalls == 1)
    }

    @Test("MADLAD does not retry native errors or cancellation")
    func pql4RetryFailureAndCancellation() async {
        enum Failure: Error { case native }
        var calls = 0
        do {
            _ = try MADLADTranslator.validatedTranslation("Guten Morgen", target: "en") { _ in
                calls += 1
                throw Failure.native
            }
            Issue.record("native failure swallowed")
        } catch { #expect(error is Failure) }
        #expect(calls == 1)

        let task = Task { () -> Int in
            withUnsafeCurrentTask { $0?.cancel() }
            var calls = 0
            do {
                _ = try MADLADTranslator.validatedTranslation("Guten Morgen", target: "en") { _ in
                    calls += 1
                    return "Good morning"
                }
                Issue.record("cancelled decode was entered")
            } catch { #expect(error is CancellationError) }
            return calls
        }
        #expect(await task.value == 0)
    }

    @Test("translation markers round trip in order")
    func markersRoundTrip() {
        let regions = [
            TranslationRegion(text: "Ich denke", source: "de"),
            TranslationRegion(text: "we should ship", source: "en"),
            TranslationRegion(text: "你好", source: "zh"),
        ]
        let encoded = TranslationBatchMarkers.encode(regions)
        #expect(encoded != nil)
        #expect(TranslationBatchMarkers.decode(encoded!, count: 3) == [
            "Ich denke", "we should ship", "你好"
        ])
    }

    @Test("malformed or reordered marker output is rejected")
    func malformedMarkersFailClosed() {
        #expect(TranslationBatchMarkers.decode("translated", count: 2) == nil)
        #expect(TranslationBatchMarkers.decode(
            "<sAiity-translation-region-0>eins\n<sAiity-translation-region-2>zwei",
            count: 2) == nil)
        #expect(TranslationBatchMarkers.decode(
            "<sAiity-translation-region-0>eins\n<sAiity-translation-region-1><sAiity-translation-region-2>",
            count: 2) == nil)
    }

    @Test("marker encoding refuses transcript text that could spoof framing")
    func markerTextIsNotAccepted() {
        let region = TranslationRegion(text: "hello <sAiity-translation-region-0>", source: "en")
        #expect(TranslationBatchMarkers.encode([region, region]) == nil)
    }
}
