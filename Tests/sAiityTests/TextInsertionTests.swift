import Foundation
import Testing

@testable import sAiity

@MainActor
@Suite struct TextInsertionTests {
    final class FakePasteboard: DictationPasteboard {
        var value: String?

        init(value: String? = nil) { self.value = value }

        func setString(_ value: String) -> Bool {
            self.value = value
            return true
        }
    }

    @Test("a focused editable field receives dictation and the clipboard keeps a copy")
    func insertsIntoFocusedEditableFieldAndKeepsCopy() {
        let board = FakePasteboard(value: "previous clipboard")
        var pasteSent = false
        let inserter = TextInserter(
            pasteboard: board,
            accessibilityTrusted: { true },
            focusedRole: { "AXTextArea" },
            sendPaste: {
                pasteSent = true
                return true
            })

        let result = inserter.insert(" dictated result ")

        #expect(result.outcome == .insertedAndCopied)
        #expect(pasteSent)
        #expect(board.value == "dictated result")
    }

    @Test("without a focused editable field, dictated text is copied without a paste")
    func noFocusedEditableFieldFallsBackToCopy() {
        let board = FakePasteboard()
        var pasteSent = false
        let inserter = TextInserter(
            pasteboard: board,
            accessibilityTrusted: { true },
            focusedRole: { nil },
            sendPaste: {
                pasteSent = true
                return true
            })

        let result = inserter.insert("keep this")

        #expect(result.outcome == .copied)
        #expect(!pasteSent)
        #expect(board.value == "keep this")
    }

    @Test("without accessibility permission, dictated text is copied without a paste")
    func withoutAccessibilityFallsBackToCopy() {
        let board = FakePasteboard()
        var pasteSent = false
        let inserter = TextInserter(
            pasteboard: board,
            accessibilityTrusted: { false },
            focusedRole: { "AXTextField" },
            sendPaste: {
                pasteSent = true
                return true
            })

        let result = inserter.insert("keep this")

        #expect(result.outcome == .copied)
        #expect(!pasteSent)
        #expect(board.value == "keep this")
    }
}
