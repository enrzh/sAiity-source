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
            focusedElement: {
                TextInsertionTarget(role: "AXTextArea",
                                    value: "existing message",
                                    isEditable: true)
            },
            sendPaste: {
                pasteSent = true
                return true
            })

        let result = inserter.insert(" dictated result ")

        #expect(result.outcome == .insertedAndCopied)
        #expect(pasteSent)
        // The separator is part of the pasted payload, not a second keystroke.
        #expect(board.value == " dictated result")
    }

    @Test("a separator is never posted as its own synthetic Space")
    func separatorIsNotPostedAsAKeystroke() {
        // There is no `sendSpace` hook any more: the old design posted a real
        // Space key event before pasting, which a Terminal or a slide deck
        // would interpret on its own, and which stayed in the document when the
        // paste failed.
        let board = FakePasteboard()
        let inserter = TextInserter(
            pasteboard: board,
            accessibilityTrusted: { true },
            focusedElement: {
                TextInsertionTarget(role: "AXTextArea",
                                    value: "existing message",
                                    isEditable: true)
            },
            sendPaste: { true })

        #expect(inserter.insert("next").outcome == .insertedAndCopied)
        #expect(board.value == " next")
    }

    @Test("a secure text field receives dictation on the clipboard but never a paste")
    func secureTextFieldIsNeverPastedInto() {
        let board = FakePasteboard()
        var pasteSent = false
        // A password field reports AXTextField as its role and
        // AXSecureTextField as its subrole, and is fully "editable".
        let inserter = TextInserter(
            pasteboard: board,
            accessibilityTrusted: { true },
            focusedElement: {
                TextInsertionTarget(role: "AXTextField",
                                    value: "",
                                    isEditable: true,
                                    subrole: "AXSecureTextField")
            },
            sendPaste: {
                pasteSent = true
                return true
            })

        let result = inserter.insert("hunter2")

        #expect(result.outcome == .copied)
        #expect(!pasteSent)
        #expect(board.value == "hunter2")
    }

    @Test("an element whose role is itself AXSecureTextField is refused too")
    func secureRoleIsRefusedWithoutASubrole() {
        let board = FakePasteboard()
        var pasteSent = false
        let inserter = TextInserter(
            pasteboard: board,
            accessibilityTrusted: { true },
            focusedElement: {
                TextInsertionTarget(role: "AXSecureTextField", value: nil, isEditable: true)
            },
            sendPaste: {
                pasteSent = true
                return true
            })

        #expect(inserter.insert("hunter2").outcome == .copied)
        #expect(!pasteSent)
    }

    @Test("an editable focused element with an unexpected role still receives dictation")
    func editableFocusedElementIsNotRejectedByRoleAllowlist() {
        let board = FakePasteboard()
        var pasteSent = false
        let inserter = TextInserter(
            pasteboard: board,
            accessibilityTrusted: { true },
            focusedElement: {
                TextInsertionTarget(role: "AXGroup",
                                    value: "existing message",
                                    isEditable: true)
            },
            sendPaste: {
                pasteSent = true
                return true
            })

        let result = inserter.insert("next line")

        #expect(result.outcome == .insertedAndCopied)
        #expect(pasteSent)
        #expect(board.value == " next line")
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
