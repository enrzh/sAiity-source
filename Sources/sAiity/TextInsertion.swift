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

/// The accessibility snapshot used for one dictation insertion. Keeping role,
/// value, and editability together avoids making separate focused-element
/// queries that can disagree while another app is handling keyboard events.
struct TextInsertionTarget: Equatable {
    let role: String?
    let value: String?
    let isEditable: Bool
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
    private let focusedElement: @MainActor () -> TextInsertionTarget?
    private let sendSpace: @MainActor () -> Bool
    private let sendPaste: @MainActor () -> Bool

    init(pasteboard: any DictationPasteboard = SystemDictationPasteboard(),
         accessibilityTrusted: @escaping @MainActor () -> Bool = AXIsProcessTrusted,
         focusedElement: @escaping @MainActor () -> TextInsertionTarget? = TextInserter.currentFocusedElement,
         sendSpace: @escaping @MainActor () -> Bool = TextInserter.postSpace,
         sendPaste: @escaping @MainActor () -> Bool = TextInserter.postPaste) {
        self.pasteboard = pasteboard
        self.accessibilityTrusted = accessibilityTrusted
        self.focusedElement = focusedElement
        self.sendSpace = sendSpace
        self.sendPaste = sendPaste
    }

    func insert(_ text: String) -> TextInsertionResult {
        let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else {
            _ = pasteboard.setString(cleaned)
            return TextInsertionResult(outcome: .copied)
        }

        let target = accessibilityTrusted() ? focusedElement() : nil
        let canPaste = target.map(Self.canPasteInto) == true
        _ = pasteboard.setString(cleaned)

        guard canPaste else {
            return TextInsertionResult(outcome: .copied)
        }

        if Self.needsSeparator(before: target?.value), !sendSpace() {
            return TextInsertionResult(outcome: .copied)
        }
        guard sendPaste() else { return TextInsertionResult(outcome: .copied) }
        return TextInsertionResult(outcome: .insertedAndCopied)
    }

    private static func canPasteInto(_ target: TextInsertionTarget) -> Bool {
        target.isEditable || target.role.map(editableRoles.contains) == true
    }

    /// Separates a new dictated phrase from text already in the target while
    /// avoiding a duplicate when the target already ends in whitespace.
    private static func needsSeparator(before existingValue: String?) -> Bool {
        guard let existingValue,
              !existingValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              existingValue.last?.isWhitespace != true else {
            return false
        }
        return true
    }

    private static func currentFocusedElement() -> TextInsertionTarget? {
        let system = AXUIElementCreateSystemWide()
        var focusedValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(system,
                                            kAXFocusedUIElementAttribute as CFString,
                                            &focusedValue) == .success,
              let focusedValue else { return nil }

        guard CFGetTypeID(focusedValue) == AXUIElementGetTypeID() else { return nil }
        let focused = focusedValue as! AXUIElement
        let role = stringAttribute(kAXRoleAttribute, from: focused)
        let value = stringAttribute(kAXValueAttribute, from: focused)
        let hasSelectedTextRange = attributeIsAvailable(kAXSelectedTextRangeAttribute, on: focused)
        let valueIsSettable = attributeIsSettable(kAXValueAttribute, on: focused)
        let isEditable = editableRoles.contains(role ?? "")
            || hasSelectedTextRange
            || (value != nil && valueIsSettable)
        return TextInsertionTarget(role: role, value: value, isEditable: isEditable)
    }

    private static func stringAttribute(_ attribute: String, from element: AXUIElement) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element,
                                            attribute as CFString,
                                            &value) == .success else { return nil }
        return value as? String
    }

    private static func attributeIsSettable(_ attribute: String, on element: AXUIElement) -> Bool {
        var settable = DarwinBoolean(false)
        guard AXUIElementIsAttributeSettable(element,
                                             attribute as CFString,
                                             &settable) == .success else { return false }
        return settable.boolValue
    }

    private static func attributeIsAvailable(_ attribute: String, on element: AXUIElement) -> Bool {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(element,
                                             attribute as CFString,
                                             &value) == .success
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

    private static func postSpace() -> Bool {
        guard let source = CGEventSource(stateID: .combinedSessionState),
              let down = CGEvent(keyboardEventSource: source,
                                  virtualKey: CGKeyCode(kVK_Space),
                                  keyDown: true),
              let up = CGEvent(keyboardEventSource: source,
                               virtualKey: CGKeyCode(kVK_Space),
                               keyDown: false) else { return false }

        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
        return true
    }
}
