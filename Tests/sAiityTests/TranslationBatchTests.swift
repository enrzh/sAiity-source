import Foundation
import Testing

@testable import sAiity

@Suite struct TranslationBatchTests {
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
