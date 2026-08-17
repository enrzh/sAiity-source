import AppKit
import ApplicationServices
import Carbon.HIToolbox
import CoreGraphics
import Foundation

protocol DictationPasteboard: AnyObject {
    func setString(_ value: String) -> Bool
}

final class SystemDictationPasteboard: DictationPasteboard {
    private let pasteboard: NSPasteboard

    init(pasteboard: NSPasteboard = .general) {
        self.pasteboard = pasteboard
    }

    func setString(_ value: String) -> Bool {
        pasteboard.clearContents()
        return pasteboard.setString(value, forType: .string)
    }
}

struct TextInsertionResult: Equatable {
    enum Outcome: Equatable {
        case insertedAndCopied
        case copied
    }

    let outcome: Outcome
}

/// Puts dictated text on the clipboard and, when the current frontmost app has
/// an editable focused element, pastes it at that element's insertion point.
@MainActor
final class TextInserter {
    private static let editableRoles: Set<String> = [
        kAXTextFieldRole as String,
        kAXTextAreaRole as String,
        kAXComboBoxRole as String,
        "AXSearchField",
    ]

    private let pasteboard: any DictationPasteboard
    private let accessibilityTrusted: @MainActor () -> Bool
    private let focusedRole: @MainActor () -> String?
    private let sendPaste: @MainActor () -> Bool

    init(pasteboard: any DictationPasteboard = SystemDictationPasteboard(),
         accessibilityTrusted: @escaping @MainActor () -> Bool = AXIsProcessTrusted,
         focusedRole: @escaping @MainActor () -> String? = TextInserter.currentFocusedRole,
         sendPaste: @escaping @MainActor () -> Bool = TextInserter.postPaste) {
        self.pasteboard = pasteboard
        self.accessibilityTrusted = accessibilityTrusted
        self.focusedRole = focusedRole
        self.sendPaste = sendPaste
    }

    func insert(_ text: String) -> TextInsertionResult {
        let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        _ = pasteboard.setString(cleaned)

        guard !cleaned.isEmpty,
              accessibilityTrusted(),
              let role = focusedRole(),
              Self.editableRoles.contains(role),
              sendPaste() else {
            return TextInsertionResult(outcome: .copied)
        }
        return TextInsertionResult(outcome: .insertedAndCopied)
    }

    private static func currentFocusedRole() -> String? {
        let system = AXUIElementCreateSystemWide()
        var focusedValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(system,
                                            kAXFocusedUIElementAttribute as CFString,
                                            &focusedValue) == .success,
              let focusedValue else { return nil }

        guard CFGetTypeID(focusedValue) == AXUIElementGetTypeID() else { return nil }
        let focused = focusedValue as! AXUIElement
        var roleValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(focused,
                                            kAXRoleAttribute as CFString,
                                            &roleValue) == .success else { return nil }
        return roleValue as? String
    }

    private static func postPaste() -> Bool {
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
}
