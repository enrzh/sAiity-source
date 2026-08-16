import Foundation
import Testing

@testable import sAiity

@MainActor
@Suite struct TextInsertionTests {
    final class FakePasteboard: DictationPasteboard {
        var items: [DictationPasteboardItem]

        init(items: [DictationPasteboardItem]) {
            self.items = items
        }

        func setString(_ value: String) -> Bool {
            items = [DictationPasteboardItem(representations: ["public.utf8-plain-text": Data(value.utf8)])]
            return true
        }

        func restore(_ snapshot: [DictationPasteboardItem]) {
            items = snapshot
        }
    }

    @Test("insertion restores every original pasteboard representation")
    func preservesPasteboard() {
        let original = [DictationPasteboardItem(representations: [
            "public.utf8-plain-text": Data("old".utf8),
            "public.rtf": Data([1, 2, 3])
        ])]
        let board = FakePasteboard(items: original)
        var pasted = false
        let inserter = TextInserter(pasteboard: board,
                                     accessibilityTrusted: { true },
                                     sendPaste: { pasted = true; return true },
                                     waitForPaste: {})

        let result = inserter.insert("new text")

        #expect(result.outcome == .inserted)
        #expect(pasted)
        #expect(board.items == original)
    }

    @Test("without accessibility, dictated text remains copied")
    func fallsBackToCopy() {
        let board = FakePasteboard(items: [])
        let inserter = TextInserter(pasteboard: board,
                                    accessibilityTrusted: { false },
                                    sendPaste: { false },
                                    waitForPaste: {})

        let result = inserter.insert("keep this")

        #expect(result.outcome == .copied)
        #expect(String(data: board.items[0].representations["public.utf8-plain-text"]!, encoding: .utf8) == "keep this")
    }
}
