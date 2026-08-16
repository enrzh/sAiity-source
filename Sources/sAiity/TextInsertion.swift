import AppKit
import Carbon.HIToolbox
import CoreGraphics
import Foundation

struct DictationPasteboardItem: Equatable {
    let representations: [String: Data]
}

protocol DictationPasteboard: AnyObject {
    var items: [DictationPasteboardItem] { get }
    func setString(_ value: String) -> Bool
    func restore(_ snapshot: [DictationPasteboardItem])
}

final class SystemDictationPasteboard: DictationPasteboard {
    private let pasteboard: NSPasteboard

    init(pasteboard: NSPasteboard = .general) {
        self.pasteboard = pasteboard
    }

    var items: [DictationPasteboardItem] {
        pasteboard.pasteboardItems?.map { item in
            let representations: [String: Data] = Dictionary(uniqueKeysWithValues: item.types.compactMap { type in
                guard let data = item.data(forType: type) else { return nil }
                return (type.rawValue, data)
            })
            return DictationPasteboardItem(representations: representations)
        } ?? []
    }

    func setString(_ value: String) -> Bool {
        pasteboard.clearContents()
        return pasteboard.setString(value, forType: .string)
    }

    func restore(_ snapshot: [DictationPasteboardItem]) {
        pasteboard.clearContents()
        let items = snapshot.map { snapshotItem -> NSPasteboardItem in
            let item = NSPasteboardItem()
            for (rawType, data) in snapshotItem.representations {
                item.setData(data, forType: NSPasteboard.PasteboardType(rawValue: rawType))
            }
            return item
        }
        _ = pasteboard.writeObjects(items)
    }
}

struct TextInsertionResult: Equatable {
    enum Outcome: Equatable {
        case inserted
        case copied
    }

    let outcome: Outcome
}

/// Inserts text into the focused app without destroying the user's clipboard.
@MainActor
final class TextInserter {
    private let pasteboard: any DictationPasteboard
    private let accessibilityTrusted: () -> Bool
    private let sendPaste: () -> Bool
    private let waitForPaste: () -> Void

    init(pasteboard: any DictationPasteboard = SystemDictationPasteboard(),
         accessibilityTrusted: @escaping () -> Bool = AXIsProcessTrusted,
         sendPaste: @escaping () -> Bool = TextInserter.postPaste,
         waitForPaste: @escaping () -> Void = TextInserter.waitForPasteConsumption) {
        self.pasteboard = pasteboard
        self.accessibilityTrusted = accessibilityTrusted
        self.sendPaste = sendPaste
        self.waitForPaste = waitForPaste
    }

    func insert(_ text: String) -> TextInsertionResult {
        let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return TextInsertionResult(outcome: .copied) }
        let original = pasteboard.items

        guard pasteboard.setString(cleaned), accessibilityTrusted(), sendPaste() else {
            _ = pasteboard.setString(cleaned)
            return TextInsertionResult(outcome: .copied)
        }

        waitForPaste()
        pasteboard.restore(original)
        return TextInsertionResult(outcome: .inserted)
    }

    func copy(_ text: String) -> TextInsertionResult {
        _ = pasteboard.setString(text.trimmingCharacters(in: .whitespacesAndNewlines))
        return TextInsertionResult(outcome: .copied)
    }

    nonisolated private static func postPaste() -> Bool {
        guard let source = CGEventSource(stateID: .combinedSessionState),
              let down = CGEvent(keyboardEventSource: source,
                                  virtualKey: CGKeyCode(kVK_ANSI_V),
                                  keyDown: true),
              let up = CGEvent(keyboardEventSource: source,
                               virtualKey: CGKeyCode(kVK_ANSI_V),
                               keyDown: false) else { return false }
        down.flags = .maskCommand
        up.flags = .maskCommand
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
        return true
    }

    nonisolated private static func waitForPasteConsumption() {
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
    }
}
