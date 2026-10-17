import Testing
@testable import SaiityLLM

// MAIN owns RED/GREEN and native qualification. This draft is outside the test
// target and uses synthetic byte pieces only; no model or vocabulary is loaded.
@Suite struct Gemma4ChannelTests {
    @Test("a well-formed thought channel is suppressed and final UTF-8 stays exact")
    func suppressesThoughtAndPreservesAnswer() {
        let raw = "<|channel>thought\nprivate synthetic reasoning\n<channel|>"
            + "\n  cafe\u{301} 字幕 مرحبا 👩🏽‍💻\n"
        let pieces = Array(raw.utf8).map { [$0] }
        #expect(LLMCore.filteredGemma4Answer(from: pieces)
            == "\n  cafe\u{301} 字幕 مرحبا 👩🏽‍💻\n")
    }

    @Test("plain final answers survive arbitrary byte-piece boundaries",
          arguments: ["cafe\u{301}", "字幕", "مرحبا", "👩🏽‍💻", "  A < B and <tag> text\n", "<\u{301}x"])
    func preservesPlainUTF8(answer: String) {
        #expect(LLMCore.filteredGemma4Answer(from: Array(answer.utf8).map { [$0] }) == answer)
    }

    @Test("marker pieces may split at every byte boundary")
    func everyMarkerSplit() {
        let raw = Array("<|channel>thought\nreasoning<channel|>Answer".utf8)
        for boundary in 0...raw.count {
            let pieces = [Array(raw.prefix(boundary)), Array(raw.dropFirst(boundary))]
            #expect(LLMCore.filteredGemma4Answer(from: pieces) == "Answer")
        }
    }

    @Test("multiple well-formed thought sections cannot leak reasoning")
    func suppressesEveryThoughtSection() {
        let raw = "A<|channel>thought\nfirst<channel|>B"
            + "<|channel>thought\nsecond<channel|>C"
        #expect(LLMCore.filteredGemma4Answer(from: [Array(raw.utf8)]) == "ABC")
    }

    @Test("unknown and malformed channel framing rejects the whole answer",
          arguments: [
            "<|channel>analysis\ntext<channel|>Answer",
            "<|channel>final\nAnswer<channel|>",
            "<|channel>thought\r\nreasoning<channel|>Answer",
            "<|channel>thought reasoning<channel|>Answer",
            "<|channel>thought\nunclosed reasoning",
            "<channel|>Answer",
            "Answer<channel|>",
            "Answer<|channel>thought\nunclosed reasoning",
            "<|channel>thought\nouter<|channel>thought\ninner<channel|><channel|>Answer",
            "<|channel>thought\nreasoning<|unknown>payload<channel|>Answer",
            "Answer<|unknown>payload",
            "Answer<|turn>user\nunexpected turn",
            "Answer<|tool_response>",
            "Answer<|",
            "Answer<|channel",
            "Answer<channel|",
            "Answer<",
            "<|channel>thought\nreasoning<channel|>",
            "<|channel>thought\nreasoning<channel|> \n",
            "", " \n"
          ])
    func rejectsMalformedOrUnknownFraming(raw: String) {
        // A visible prefix must not escape before a malformed suffix is found.
        #expect(LLMCore.filteredGemma4Answer(from: Array(raw.utf8).map { [$0] }) == nil)
    }

    @Test("incomplete or invalid final UTF-8 is rejected without replacement characters")
    func rejectsInvalidUTF8() {
        #expect(LLMCore.filteredGemma4Answer(from: [[0xF0, 0x9F], [0x91]]) == nil)
        #expect(LLMCore.filteredGemma4Answer(from: [Array("Answer".utf8), [0xFF]]) == nil)
        #expect(LLMCore.filteredGemma4Answer(from: [
            Array("<|channel>thought\n".utf8), [0xFF], Array("<channel|>Answer".utf8)
        ]) == nil)
    }
}
