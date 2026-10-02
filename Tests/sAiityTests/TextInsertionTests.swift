import Foundation
import ApplicationServices
import Testing

@testable import sAiity

@MainActor
@Suite struct TextInsertionTests {
    final class FakePasteboard: DictationPasteboard {
        var value: String?
        var succeeds = true

        init(value: String? = nil) { self.value = value }

        func setString(_ value: String) -> Bool {
            guard succeeds else { return false }
            self.value = value
            return true
        }
    }

    @Test("changing apps during processing copies the result without sending a paste")
    func focusChangePreventsPaste() {
        let board = FakePasteboard()
        var focus = DictationFocusToken(processIdentifier: 1, bundleIdentifier: "test.original",
                                       field: AXUIElementCreateApplication(1))
        var pastes = 0
        let inserter = TextInserter(pasteboard: board, accessibilityTrusted: { true },
            focusedElement: { .init(role: "AXTextArea", value: "", isEditable: true) },
            sendPaste: { pastes += 1; return true }, currentFocus: { focus })
        let captured = inserter.captureFocus()
        #expect(inserter.insert("first", expecting: captured).outcome == .insertedAndCopied)
        focus = .init(processIdentifier: 2, bundleIdentifier: "test.other")
        #expect(inserter.insert("keep this", expecting: captured).outcome == .copied)
        #expect(board.value == "keep this")
        #expect(pastes == 1)
        #expect(inserter.insert("unknown focus", expecting: nil).outcome == .copied)
        #expect(pastes == 1)
    }

    @Test("changing fields within the same app copies without pasting")
    func fieldChangePreventsPaste() {
        let board = FakePasteboard()
        var focus = DictationFocusToken(processIdentifier: 42, bundleIdentifier: "test.editor",
                                       field: AXUIElementCreateApplication(1))
        var pastes = 0
        let inserter = TextInserter(pasteboard: board, accessibilityTrusted: { true },
            focusedElement: { .init(role: "AXTextArea", value: "", isEditable: true) },
            sendPaste: { pastes += 1; return true }, currentFocus: { focus })
        let captured = inserter.captureFocus()
        focus.field = AXUIElementCreateApplication(2) // Opaque stand-ins for two field handles.
        #expect(inserter.insert("different document", expecting: captured).outcome == .copied)
        #expect(pastes == 0)
        #expect(board.value == "different document")
        focus.field = nil
        #expect(inserter.insert("unavailable field", expecting: captured).outcome == .copied)
        #expect(pastes == 0)
    }

    @Test("focus is rechecked after a successful clipboard write")
    func lateFieldChangePreventsPaste() {
        let board = FakePasteboard()
        let original = DictationFocusToken(processIdentifier: 42, bundleIdentifier: "test.editor",
                                          field: AXUIElementCreateApplication(1))
        var reads = 0
        var pastes = 0
        let inserter = TextInserter(pasteboard: board, accessibilityTrusted: { true },
            focusedElement: { .init(role: "AXTextArea", value: "", isEditable: true) },
            sendPaste: { pastes += 1; return true }, currentFocus: {
                reads += 1
                return reads == 1 ? original : .init(processIdentifier: 42, bundleIdentifier: "test.editor", field: AXUIElementCreateApplication(2))
            })
        #expect(inserter.insert("keep the result", expecting: original).outcome == .copied)
        #expect(pastes == 0)
    }

    @Test("clipboard failure never sends Paste or claims a copy; retry copies only")
    func copyFailureAndRetry() {
        let board = FakePasteboard(value: "previous clipboard")
        board.succeeds = false
        var pastes = 0
        let inserter = TextInserter(pasteboard: board, accessibilityTrusted: { true },
            focusedElement: { .init(role: "AXTextArea", value: "", isEditable: true) },
            sendPaste: { pastes += 1; return true })
        #expect(inserter.insert("new result").outcome == .copyFailed)
        #expect(inserter.insert("new result", expecting: nil).outcome == .copyFailed)
        #expect(pastes == 0)
        #expect(board.value == "previous clipboard")
        board.succeeds = true
        #expect(inserter.copy("new result").outcome == .copied)
        #expect(board.value == "new result")
        #expect(pastes == 0)
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
