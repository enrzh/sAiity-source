import AudioCommon
import Foundation
import SpeechVAD
import Testing

@testable import sAiity

@Suite struct QwenASREngineTests {
    @Test("Qwen silence storage stays bounded and preserves the next speech onset")
    func silenceAndOnset() {
        var buffer = QwenSpeechBuffer()
        let silence = [Float](repeating: 0, count: 16_000)
        for _ in 0..<3_600 {
            #expect(buffer.append(silence, events: []).isEmpty)
            #expect(buffer.retainedSampleCount <= QwenSpeechBuffer.silenceHistorySamples)
        }
        let speech = [Float](repeating: 0.5, count: 16_000)
        let slices = buffer.append(speech, events: [
            .speechStarted(time: 3_600),
            .speechEnded(segment: .init(startTime: 3_600, endTime: 3_600.8))
        ])
        #expect(slices.count == 1)
        #expect(slices[0].filter { $0 == 0.5 }.count == speech.count)
        #expect(buffer.retainedSampleCount <= QwenSpeechBuffer.silenceHistorySamples)
    }

    @Test("Qwen forced cuts and final flush conserve continuous speech")
    func forcedCuts() {
        var buffer = QwenSpeechBuffer()
        let speech = (0..<352_000).map(Float.init)
        var slices = buffer.append(speech, events: [.speechStarted(time: 0)])
        #expect(slices.allSatisfy { $0.count <= 160_000 })
        slices += buffer.append([], events: [], flush: true)
        #expect(slices.flatMap { $0 }.elementsEqual(speech))
        #expect(buffer.append([], events: [], flush: true).isEmpty)
    }

    @Test("Qwen joins disjoint scripts without deduplicating intended repetition")
    func joins() {
        #expect(QwenASREngine.extending("你好", with: "世界") == "你好世界")
        #expect(QwenASREngine.extending("Hallo", with: "world") == "Hallo world")
        #expect(QwenASREngine.extending("Very good.", with: "Very good.") == "Very good. Very good.")
    }

    @Test("Qwen caps closed speech and handles multiple events on one sample clock")
    func closedSlices() {
        var buffer = QwenSpeechBuffer()
        let speech = (0..<352_000).map(Float.init)
        let slices = buffer.append(speech, events: [
            .speechStarted(time: 0),
            .speechEnded(segment: .init(startTime: 0, endTime: 21.8))
        ])
        #expect(slices.allSatisfy { $0.count <= 160_000 })
        #expect(slices.flatMap { $0 }.elementsEqual(speech))
        buffer = QwenSpeechBuffer()
        let repeated = buffer.append(Array(repeating: 0.5, count: 32_000), events: [
            .speechStarted(time: 0), .speechEnded(segment: .init(startTime: 0, endTime: 0.8)),
            .speechStarted(time: 1), .speechEnded(segment: .init(startTime: 1, endTime: 1.8))
        ])
        #expect(repeated.count == 2)
        #expect(repeated.flatMap { $0 }.count == 32_000)
        #expect(buffer.append([], events: [], flush: true).isEmpty)
    }

    @Test("Qwen rejects a missing Metal resource before loading or downloading weights")
    func missingResource() async {
        let engine = QwenASREngine(size: .small, resourceRoot: nil)
        await #expect(throws: TranslationEngineError.self) {
            try await engine.load { _ in }
        }
    }
}
