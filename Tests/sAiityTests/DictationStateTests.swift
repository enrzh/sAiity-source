import Testing

@testable import sAiity

@Suite struct DictationStateTests {
    @Test("a press starts one session and duplicate presses are ignored")
    func duplicatePressesDoNotRestart() {
        var state = DictationSessionState()
        let firstPress = state.begin()
        let secondPress = state.begin()
        #expect(firstPress)
        #expect(!secondPress)
        #expect(state.isActive)
    }

    @Test("release ends an active session and an extra release is ignored")
    func releaseIsIdempotent() {
        var state = DictationSessionState()
        _ = state.begin()
        let firstRelease = state.release()
        let secondRelease = state.release()
        #expect(firstRelease)
        #expect(!secondRelease)
        #expect(!state.isActive)
    }

    @Test("final chunks join with one space and empty chunks are ignored")
    func finalTextIsClean() {
        var text = DictationTextAssembler()
        text.append("  Hello")
        text.append("world  ")
        text.append("   ")
        text.append("from sAiity.")
        #expect(text.finalText == "Hello world from sAiity.")
    }

    @Test("cancellation discards partial text")
    func cancellationClearsText() {
        var text = DictationTextAssembler()
        text.append("discard me")
        text.reset()
        #expect(text.finalText.isEmpty)
    }
}
