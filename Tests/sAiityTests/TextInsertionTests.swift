import Foundation
import ApplicationServices
import CryptoKit
import Testing

@testable import sAiity

@Suite struct DeliveryEndpointTests {
    @Test("native delivery describes copy or dispatch and never asserts visible insertion")
    func deliveryEndpoint() {
        #expect(TextInsertionResult(outcome: .copied).deliveryEndpoint == "copied")
        #expect(TextInsertionResult(outcome: .insertedAndCopied).deliveryEndpoint == "paste-dispatched")
        #expect(TextInsertionResult(outcome: .copyFailed).deliveryEndpoint == nil)
    }
}

@MainActor
@Suite struct TextInsertionTests {
    @Test("focus-mismatch copy observes secure targets before admitting recent recovery", arguments: [true, false])
    func dupFocusMismatchExcludesSecureRecent(copySucceeds: Bool) {
        let board = FakePasteboard()
        board.succeeds = copySucceeds
        let captured = DictationFocusToken(processIdentifier: 1, bundleIdentifier: "test.original",
                                          field: AXUIElementCreateApplication(1))
        var snapshots = 0
        let inserter = TextInserter(pasteboard: board, accessibilityTrusted: { true },
            focusedElement: {
                snapshots += 1
                return .init(role: "AXSecureTextField", value: nil, isEditable: true)
            }, sendPaste: { Issue.record("must not paste after focus changed"); return true },
            currentFocus: { .init(processIdentifier: 2, bundleIdentifier: "test.other") })
        let delivery = inserter.insert("synthetic sensitive result", expecting: captured)
        #expect(delivery.outcome == (copySucceeds ? .copied : .copyFailed))
        #expect(delivery.secureTargetObserved)
        #expect(snapshots == 1)
        let entry = RecentDictationResult(id: UUID(), completedAt: Date(),
            result: .init(rawText: "synthetic sensitive result", outputText: "synthetic sensitive result",
                          wasCleaned: false, wasTranslated: false), delivery: delivery)
        #expect(RecentDictationResult.retaining(entry, in: [], enabled: true).isEmpty)
    }

    @Test("explicit copy preserves the exact selected Unicode text and never pastes")
    func dupCopyPreservesExactUnicode() {
        let board = FakePasteboard()
        var pastes = 0
        let inserter = TextInserter(pasteboard: board, accessibilityTrusted: { false },
            focusedElement: { nil }, sendPaste: { pastes += 1; return true })
        let text = "\n  cafe\u{301} 字幕\nمرحبا 👩🏽‍💻\n"
        #expect(inserter.copy(text).outcome == .copied)
        #expect(board.value == text)
        #expect(pastes == 0)
    }

    @Test("delivery observes a secure target even when copying fails")
    func dupDeliveryRecordsSecureObservation() {
        let board = FakePasteboard()
        let inserter = TextInserter(pasteboard: board, accessibilityTrusted: { true },
            focusedElement: { .init(role: "AXTextField", value: "", isEditable: true, subrole: "AXSecureTextField") },
            sendPaste: { Issue.record("must not paste into a secure field"); return true })
        #expect(inserter.insert("private").secureTargetObserved)
        board.succeeds = false
        let failed = inserter.insert("private")
        #expect(failed.outcome == .copyFailed)
        #expect(failed.secureTargetObserved)
    }

    @Test("delivery hash includes the separator even when paste dispatch fails", arguments: [false, true])
    func payloadHashIncludesSeparator(pasteDispatched: Bool) {
        let board = FakePasteboard()
        let inserter = TextInserter(pasteboard: board, accessibilityTrusted: { true },
            focusedElement: { .init(role: "AXTextArea", value: "Hello", isEditable: true) },
            sendPaste: { pasteDispatched })

        let result = inserter.insert(" next ")
        #expect(result.outcome == (pasteDispatched ? .insertedAndCopied : .copied))
        #expect(board.value == " next")
        // Independently computed SHA-256 of the exact UTF-8 bytes for " next".
        #expect(result.payloadSHA256 == "d1052e87b6bba8e970d6890b506f948dadd6fc11405aa142139b92fe424b9dcd")
        #expect(result.payloadSHA256 != "c6c1c9a9c8543f1e4cd980064cf1625eeb61a90703b2464fff039f21682508b3")
    }

    @Test("explicit copy hashes exact Unicode and whitespace without querying a document")
    func copyHashPreservesExactBytes() {
        let board = FakePasteboard()
        let inserter = TextInserter(pasteboard: board,
            accessibilityTrusted: { Issue.record("copy must not query accessibility"); return true },
            focusedElement: { Issue.record("copy must not read document context"); return nil },
            sendPaste: { Issue.record("copy must not dispatch Paste"); return true })
        let payload = "\n cafe\u{301} 字幕 مرحبا 👩🏽‍💻 \n"
        let result = inserter.copy(payload)

        #expect(result.outcome == .copied)
        #expect(board.value == payload)
        #expect(result.payloadSHA256 == SHA256.hash(data: Data(payload.utf8))
            .map { String(format: "%02x", $0) }.joined())
    }

    @Test("failed clipboard writes report no payload hash", arguments: [false, true])
    func failedClipboardWriteHasNoHash(explicitCopy: Bool) {
        let board = FakePasteboard(value: "previous clipboard")
        board.succeeds = false
        let inserter = TextInserter(pasteboard: board, accessibilityTrusted: { true },
            focusedElement: { .init(role: "AXTextArea", value: "Hello", isEditable: true) },
            sendPaste: { Issue.record("failed copy must not dispatch Paste"); return true })
        let result = explicitCopy ? inserter.copy("next") : inserter.insert("next")

        #expect(result.outcome == .copyFailed)
        #expect(result.payloadSHA256 == nil)
        #expect(board.value == "previous clipboard")
        #expect(TextInsertionResult(outcome: .copied).payloadSHA256 == nil)
    }

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

    // Synthetic AX responses only: no messaging to a running editor or reading
    // its document. The native query boundary is injected, not the spacing rule.
    @MainActor final class FakeAX {
        let field = AXUIElementCreateApplication(1)
        var document = "Hello world "
        var selection: CFRange? = CFRange(location: 5, length: 0)
        var malformedSelection = false
        var contextError: AXError = .success
        var emptyContext = false
        var oversizedContext = false
        var timeoutError: AXError = .success
        var role = "AXTextArea"
        var subrole: String? = nil
        var subroleError: AXError? = nil
        var malformedSubrole = false
        var attributes: [String] = []
        var ranges: [CFRange] = []
        var timeouts: [Float] = []
        var operations: [String] = []

        func snapshot() -> TextInsertionTarget? {
            TextInserter.currentFocusedElement(from: field,
                copyAttributeValue: { _, attribute, output in
                    let name = attribute as String
                    self.attributes.append(name)
                    self.operations.append(name)
                    switch name {
                    case kAXRoleAttribute:
                        output.pointee = self.role as CFString
                    case kAXSubroleAttribute:
                        if let error = self.subroleError { return error }
                        if self.malformedSubrole {
                            output.pointee = NSNumber(value: 42)
                            return .success
                        }
                        guard let subrole = self.subrole else { return .attributeUnsupported }
                        output.pointee = subrole as CFString
                    case kAXSelectedTextRangeAttribute:
                        if self.malformedSelection {
                            output.pointee = "not an AX range" as CFString
                        } else {
                            guard var selection = self.selection else { return .attributeUnsupported }
                            output.pointee = AXValueCreate(.cfRange, &selection)
                        }
                    case kAXValueAttribute, kAXSelectedTextAttribute:
                        Issue.record("must not request whole document or selected text")
                        return .failure
                    default:
                        return .attributeUnsupported
                    }
                    return .success
                },
                copyParameterizedAttributeValue: { _, attribute, parameter, output in
                    #expect(attribute as String == kAXStringForRangeParameterizedAttribute)
                    guard CFGetTypeID(parameter) == AXValueGetTypeID() else {
                        Issue.record("AXStringForRange needs an AXValue range")
                        return .illegalArgument
                    }
                    var range = CFRange()
                    guard AXValueGetValue(parameter as! AXValue, .cfRange, &range) else {
                        Issue.record("AXStringForRange needs a CFRange")
                        return .illegalArgument
                    }
                    self.ranges.append(range)
                    self.operations.append("context")
                    guard self.contextError == .success else { return self.contextError }
                    if self.emptyContext {
                        output.pointee = "" as CFString
                        return .success
                    }
                    if self.oversizedContext {
                        output.pointee = String(repeating: "x", count: 100) as CFString
                        return .success
                    }
                    let document = self.document as NSString
                    guard range.location >= 0, range.length > 0,
                          range.location <= document.length,
                          range.length <= document.length - range.location else { return .illegalArgument }
                    output.pointee = document.substring(with: NSRange(location: range.location,
                                                                       length: range.length)) as CFString
                    return .success
                },
                setMessagingTimeout: { _, timeout in
                    self.timeouts.append(timeout)
                    self.operations.append("timeout")
                    return self.timeoutError
                })
        }
    }

    @Test("separator follows beginning, middle and end caret positions", arguments: [0, 5, 12])
    func separatorUsesCaret(location: Int) {
        let ax = FakeAX()
        ax.selection = CFRange(location: location, length: 0)
        let board = FakePasteboard()
        let inserter = TextInserter(pasteboard: board, accessibilityTrusted: { true },
            focusedElement: { ax.snapshot() }, sendPaste: { true })

        #expect(inserter.insert(" new ").outcome == .insertedAndCopied)
        #expect(board.value == (location == 5 ? " new" : "new"))
        if location == 0 {
            #expect(ax.ranges.isEmpty)
        } else {
            #expect(ax.ranges.count == 1)
            #expect(ax.ranges.last.map { $0.location + $0.length } == location)
        }
    }

    @Test("caret whitespace matters even when the document ends in a word", arguments: [0, 6, 11])
    func separatorUsesPrecedingCharacter(location: Int) {
        let ax = FakeAX()
        ax.document = "Hello world"
        ax.selection = CFRange(location: location, length: 0)
        let board = FakePasteboard()
        let inserter = TextInserter(pasteboard: board, accessibilityTrusted: { true },
            focusedElement: { ax.snapshot() }, sendPaste: { true })

        #expect(inserter.insert("new").outcome == .insertedAndCopied)
        #expect(board.value == (location == 11 ? " new" : "new"))
    }

    @Test("replacement spacing uses the selection start, not selected text", arguments: [0, 5, 6])
    func replacementUsesSelectionStart(location: Int) {
        let ax = FakeAX()
        ax.document = "Hello OLD tail "
        ax.selection = CFRange(location: location, length: location == 5 ? 4 : 3)
        let board = FakePasteboard()
        let inserter = TextInserter(pasteboard: board, accessibilityTrusted: { true },
            focusedElement: { ax.snapshot() }, sendPaste: { true })

        #expect(inserter.insert("new").outcome == .insertedAndCopied)
        #expect(board.value == (location == 5 ? " new" : "new"))
        #expect(ax.ranges.allSatisfy { $0.location + $0.length == location })
        #expect(!ax.attributes.contains(kAXSelectedTextAttribute))
    }

    @Test("Unicode caret offsets are UTF-16 and Unicode whitespace suppresses separator",
          arguments: ["cafe\u{301}", "👩🏽‍💻", String(repeating: "👩🏽‍💻", count: 20),
                      "字幕", "مرحبا", "👩🏽‍💻\u{00A0}", "字幕\u{3000}", "字\n"])
    func unicodeCaretContext(prefix: String) {
        let ax = FakeAX()
        ax.document = prefix + "suffix "
        ax.selection = CFRange(location: prefix.utf16.count, length: 0)
        let board = FakePasteboard()
        let inserter = TextInserter(pasteboard: board, accessibilityTrusted: { true },
            focusedElement: { ax.snapshot() }, sendPaste: { true })
        let phrase = "cafe\u{301} 字幕 مرحبا 👩🏽‍💻"

        #expect(inserter.insert(phrase).outcome == .insertedAndCopied)
        #expect(board.value == (prefix.last?.isWhitespace == true ? phrase : " " + phrase))
        #expect(ax.ranges.count == 1)
        #expect(ax.ranges.last.map { $0.location + $0.length } == prefix.utf16.count)
    }

    @Test("large synthetic documents request only bounded caret context after setting timeout")
    func boundedAXContextAndTimeout() {
        let ax = FakeAX()
        ax.document = String(repeating: "x", count: 100_000) + " suffix "
        ax.selection = CFRange(location: 100_000, length: 0)
        let board = FakePasteboard()
        let inserter = TextInserter(pasteboard: board, accessibilityTrusted: { true },
            focusedElement: { ax.snapshot() }, sendPaste: { true })

        #expect(inserter.insert("new").outcome == .insertedAndCopied)
        #expect(board.value == " new")
        #expect(ax.ranges.count == 1)
        #expect(ax.ranges.allSatisfy { $0.length > 0 && $0.length <= 32
            && $0.location + $0.length == 100_000 })
        #expect(ax.timeouts.count == 1)
        #expect(ax.timeouts.allSatisfy { $0 > 0 && $0 <= 0.25 })
        #expect(ax.operations.first == "timeout")
        #expect(ax.attributes.filter { $0 == kAXSelectedTextRangeAttribute }.count == 1)
        #expect(!ax.attributes.contains(kAXValueAttribute))
    }

    @Test("unavailable or malformed selection never guesses from document text", arguments: [false, true])
    func unavailableSelectionUsesUnmodifiedPayload(malformed: Bool) {
        let ax = FakeAX()
        ax.selection = nil
        ax.malformedSelection = malformed
        let board = FakePasteboard()
        let inserter = TextInserter(pasteboard: board, accessibilityTrusted: { true },
            focusedElement: { ax.snapshot() }, sendPaste: { true })

        #expect(inserter.insert(" new ").outcome == .insertedAndCopied)
        #expect(board.value == "new")
        #expect(ax.ranges.isEmpty)
        #expect(!ax.attributes.contains(kAXValueAttribute))
    }

    @Test("invalid native selection offsets never reach AXStringForRange", arguments: [-1, Int.max])
    func invalidSelectionUsesUnmodifiedPayload(location: Int) {
        let ax = FakeAX()
        ax.selection = CFRange(location: location, length: 1)
        let board = FakePasteboard()
        let inserter = TextInserter(pasteboard: board, accessibilityTrusted: { true },
            focusedElement: { ax.snapshot() }, sendPaste: { true })

        #expect(inserter.insert("new").outcome == .insertedAndCopied)
        #expect(board.value == "new")
        #expect(ax.ranges.isEmpty)
    }

    @Test("a negative native selection length never reaches AXStringForRange")
    func negativeSelectionLengthUsesUnmodifiedPayload() {
        let ax = FakeAX()
        ax.selection = CFRange(location: 5, length: -1)
        let board = FakePasteboard()
        let inserter = TextInserter(pasteboard: board, accessibilityTrusted: { true },
            focusedElement: { ax.snapshot() }, sendPaste: { true })

        #expect(inserter.insert("new").outcome == .insertedAndCopied)
        #expect(board.value == "new")
        #expect(ax.ranges.isEmpty)
    }

    @Test("an empty bounded context never invents a leading separator")
    func emptyContextUsesUnmodifiedPayload() {
        let ax = FakeAX()
        ax.emptyContext = true
        let board = FakePasteboard()
        let inserter = TextInserter(pasteboard: board, accessibilityTrusted: { true },
            focusedElement: { ax.snapshot() }, sendPaste: { true })

        #expect(inserter.insert("new").outcome == .insertedAndCopied)
        #expect(board.value == "new")
    }

    @Test("an AX response larger than the requested context is discarded")
    func oversizedContextUsesUnmodifiedPayload() {
        let ax = FakeAX()
        ax.oversizedContext = true
        let board = FakePasteboard()
        let inserter = TextInserter(pasteboard: board, accessibilityTrusted: { true },
            focusedElement: { ax.snapshot() }, sendPaste: { true })

        #expect(inserter.insert("new").outcome == .insertedAndCopied)
        #expect(board.value == "new")
    }

    @Test("unsupported or timed-out caret context preserves the undecorated clipboard result",
          arguments: [AXError.parameterizedAttributeUnsupported, .cannotComplete])
    func unavailableContextUsesUnmodifiedPayload(error: AXError) {
        let ax = FakeAX()
        ax.contextError = error
        let board = FakePasteboard()
        var pastes = 0
        let inserter = TextInserter(pasteboard: board, accessibilityTrusted: { true },
            focusedElement: { ax.snapshot() }, sendPaste: { pastes += 1; return false })

        #expect(inserter.insert(" new ").outcome == .copied)
        #expect(board.value == "new")
        #expect(pastes == 1)
        let queries = ax.ranges.count
        #expect(inserter.copy(" exact recovery ").outcome == .copied)
        #expect(board.value == " exact recovery ")
        #expect(pastes == 1)
        #expect(ax.ranges.count == queries)
        #expect(!ax.attributes.contains(kAXValueAttribute))
    }

    @Test("failure to set an AX timeout stops querying and falls back to copy")
    func unavailableTimeoutFallsBackToCopy() {
        let ax = FakeAX()
        ax.timeoutError = .cannotComplete
        let board = FakePasteboard()
        let inserter = TextInserter(pasteboard: board, accessibilityTrusted: { true },
            focusedElement: { ax.snapshot() },
            sendPaste: { Issue.record("must not paste without a bounded target query"); return true })

        #expect(inserter.insert("new").outcome == .copied)
        #expect(board.value == "new")
        #expect(ax.attributes.isEmpty)
        #expect(ax.ranges.isEmpty)
    }

    @Test("secure AX roles and subroles never expose selection or context", arguments: [false, true])
    func secureSnapshotDoesNotReadContext(secureSubrole: Bool) {
        let ax = FakeAX()
        ax.role = secureSubrole ? "AXTextField" : "AXSecureTextField"
        ax.subrole = secureSubrole ? "AXSecureTextField" : nil
        let board = FakePasteboard()
        let inserter = TextInserter(pasteboard: board, accessibilityTrusted: { true },
            focusedElement: { ax.snapshot() },
            sendPaste: { Issue.record("must not paste into a secure target"); return true })

        let result = inserter.insert(" private ")
        #expect(result.outcome == .copied)
        #expect(result.secureTargetObserved)
        #expect(board.value == "private")
        #expect(ax.ranges.isEmpty)
        #expect(!ax.attributes.contains(kAXValueAttribute))
        #expect(!ax.attributes.contains(kAXSelectedTextAttribute))
        #expect(!ax.attributes.contains(kAXSelectedTextRangeAttribute))
    }

    @Test("failed or malformed security classification permits copying only", arguments: [false, true])
    func unavailableSecurityClassificationFallsBackToCopy(malformed: Bool) {
        let ax = FakeAX()
        ax.role = "AXTextField"
        ax.subroleError = malformed ? nil : .cannotComplete
        ax.malformedSubrole = malformed
        let board = FakePasteboard()
        let inserter = TextInserter(pasteboard: board, accessibilityTrusted: { true },
            focusedElement: { ax.snapshot() },
            sendPaste: { Issue.record("must not paste without classifying target security"); return true })

        #expect(inserter.insert("new").outcome == .copied)
        #expect(board.value == "new")
        #expect(ax.ranges.isEmpty)
        #expect(!ax.attributes.contains(kAXSelectedTextRangeAttribute))
    }

    @Test("secure or noneditable injected targets do not add document context to recovery", arguments: [false, true])
    func copyOnlyTargetDoesNotDecoratePayload(secure: Bool) {
        let board = FakePasteboard()
        let inserter = TextInserter(pasteboard: board, accessibilityTrusted: { true },
            focusedElement: { .init(role: secure ? "AXSecureTextField" : "AXStaticText",
                                   value: "synthetic private document", isEditable: false) },
            sendPaste: { Issue.record("must not paste into a copy-only target"); return true })

        let result = inserter.insert(" new ")
        #expect(result.outcome == .copied)
        #expect(result.secureTargetObserved == secure)
        #expect(board.value == "new")
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
