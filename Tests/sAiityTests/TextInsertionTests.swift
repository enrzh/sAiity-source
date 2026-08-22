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
        var spaceSent = false
        var pasteSent = false
        let inserter = TextInserter(
            pasteboard: board,
            accessibilityTrusted: { true },
            focusedElement: {
                TextInsertionTarget(role: "AXTextArea",
                                    value: "existing message",
                                    isEditable: true)
            },
            sendSpace: {
                spaceSent = true
                return true
            },
            sendPaste: {
                pasteSent = true
                return true
            })

        let result = inserter.insert(" dictated result ")

        #expect(result.outcome == .insertedAndCopied)
        #expect(spaceSent)
        #expect(pasteSent)
        #expect(board.value == "dictated result")
    }

    @Test("an editable focused element with an unexpected role still receives dictation")
    func editableFocusedElementIsNotRejectedByRoleAllowlist() {
        let board = FakePasteboard()
        var spaceSent = false
        var pasteSent = false
        let inserter = TextInserter(
            pasteboard: board,
            accessibilityTrusted: { true },
            focusedElement: {
                TextInsertionTarget(role: "AXGroup",
                                    value: "existing message",
                                    isEditable: true)
            },
            sendSpace: {
                spaceSent = true
                return true
            },
            sendPaste: {
                pasteSent = true
                return true
            })

        let result = inserter.insert("next line")

        #expect(result.outcome == .insertedAndCopied)
        #expect(spaceSent)
        #expect(pasteSent)
        #expect(board.value == "next line")
    }

    @Test("an empty editable field receives dictation without a leading space")
    func emptyEditableFieldDoesNotReceiveLeadingSpace() {
        let board = FakePasteboard()
        let inserter = TextInserter(
            pasteboard: board,
            accessibilityTrusted: { true },
            focusedElement: {
                TextInsertionTarget(role: "AXTextArea",
                                    value: nil,
                                    isEditable: true)
            },
            sendPaste: { true })

        let result = inserter.insert("first line")

        #expect(result.outcome == .insertedAndCopied)
        #expect(board.value == "first line")
    }

    @Test("empty dictation does not become a separator on the clipboard")
    func emptyDictationStaysEmpty() {
        let board = FakePasteboard(value: "previous clipboard")
        var pasteSent = false
        let inserter = TextInserter(
            pasteboard: board,
            accessibilityTrusted: { true },
            focusedElement: {
                TextInsertionTarget(role: "AXTextArea",
                                    value: "existing message",
                                    isEditable: true)
            },
            sendPaste: {
                pasteSent = true
                return true
            })

        let result = inserter.insert(" \n")

        #expect(result.outcome == .copied)
        #expect(!pasteSent)
        #expect(board.value == "")
    }

    @Test("without a focused editable field, dictated text is copied without a paste")
    func noFocusedEditableFieldFallsBackToCopy() {
        let board = FakePasteboard()
        var pasteSent = false
        let inserter = TextInserter(
            pasteboard: board,
            accessibilityTrusted: { true },
            focusedElement: { nil },
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
            focusedElement: {
                TextInsertionTarget(role: "AXTextField", value: "existing", isEditable: true)
            },
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
