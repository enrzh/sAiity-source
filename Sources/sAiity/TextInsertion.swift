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
/// subrole, value, and editability together avoids making separate
/// focused-element queries that can disagree while another app is handling
/// keyboard events.
struct TextInsertionTarget: Equatable {
    let role: String?
    let value: String?
    let isEditable: Bool
    /// `AXSecureTextField` is a *subrole* of `AXTextField`, so the role alone
    /// cannot tell a password box from a plain one. macOS's own dictation
    /// refuses secure fields, and so must this: pasting a dictated secret into a
    /// password manager would both reveal it in the document and leave it in
    /// cleartext on the general pasteboard.
    // `var`, not `let`: Swift's synthesized memberwise initializer only carries
    // defaults for stored `var`s, so a `let` with an initial value is not a
    // parameter at all and every call site passing `subrole:` fails to compile.
    var subrole: String? = nil

    var isSecure: Bool {
        role == TextInserter.secureRole || subrole == TextInserter.secureRole
    }
}

/// The app that was frontmost when the dictation key went down.
///
/// Recognition, cleanup, and translation all happen between the press and the
/// insertion, which takes seconds. Without this the text lands in whatever
/// became frontmost in the meantime — a Mail draft you switched to, a Terminal,
/// a password prompt. Capturing the identity at press time and re-checking it at
/// insert time turns that silent misdelivery into an ordinary clipboard copy.
struct DictationFocusToken: Equatable, Sendable {
    let processIdentifier: pid_t
    let bundleIdentifier: String?
}

extension DictationTextInsertion {
    /// A capture-less insertion path: test doubles and any future implementation
    /// that cannot see the frontmost app fall back to a plain insert.
    func captureFocus() -> DictationFocusToken? { nil }

    func insert(_ text: String, expecting expected: DictationFocusToken?) -> TextInsertionResult {
        insert(text)
    }
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

    /// A secure text field reports `AXTextField` as its role and
    /// `AXSecureTextField` as its subrole. Neither may ever receive dictated
    /// text: the secret would land in the target document *and* stay on the
    /// general pasteboard in cleartext.
    static let secureRole = "AXSecureTextField"

    private let pasteboard: any DictationPasteboard
    private let accessibilityTrusted: @MainActor () -> Bool
    private let focusedElement: @MainActor () -> TextInsertionTarget?
    private let sendPaste: @MainActor () -> Bool

    init(pasteboard: any DictationPasteboard = SystemDictationPasteboard(),
         accessibilityTrusted: @escaping @MainActor () -> Bool = AXIsProcessTrusted,
         focusedElement: @escaping @MainActor () -> TextInsertionTarget? = TextInserter.currentFocusedElement,
         sendPaste: @escaping @MainActor () -> Bool = TextInserter.postPaste) {
        self.pasteboard = pasteboard
        self.accessibilityTrusted = accessibilityTrusted
        self.focusedElement = focusedElement
        self.sendPaste = sendPaste
    }

    /// The frontmost app right now, for `captureFocus()`.
    static func currentFocusToken() -> DictationFocusToken? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        return DictationFocusToken(processIdentifier: app.processIdentifier,
                                   bundleIdentifier: app.bundleIdentifier)
    }

    /// Record which app the user was in when dictation started. Call this at the
    /// press, not at the insertion.
    func captureFocus() -> DictationFocusToken? {
        Self.currentFocusToken()
    }

    /// Insert dictated text, but only into the app that was focused when
    /// dictation started. If the user switched apps while the model was working,
    /// the text is still copied — it is just not pasted somewhere they did not
    /// ask for.
    func insert(_ text: String, expecting expected: DictationFocusToken?) -> TextInsertionResult {
        if let expected, !Self.isStillFrontmost(expected) {
            let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
            _ = pasteboard.setString(cleaned)
            return TextInsertionResult(outcome: .copied)
        }
        return insert(text)
    }

    private static func isStillFrontmost(_ token: DictationFocusToken) -> Bool {
        guard let current = currentFocusToken() else { return false }
        if current.processIdentifier != token.processIdentifier { return false }
        // Some apps expose no bundle identifier; the process identity is enough
        // in that case, and requiring both would reject perfectly good targets.
        guard let expectedID = token.bundleIdentifier,
              let currentID = current.bundleIdentifier else { return true }
        return expectedID == currentID
    }

    func insert(_ text: String) -> TextInsertionResult {
        let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else {
            _ = pasteboard.setString(cleaned)
            return TextInsertionResult(outcome: .copied)
        }

        let target = accessibilityTrusted() ? focusedElement() : nil
        let canPaste = target.map(Self.canPasteInto) == true
        // The separating space rides inside the pasted string rather than being
        // posted as its own keystroke. A synthetic Space is delivered to
        // whatever happens to be focused when the event lands — it can become
        // part of a Terminal command, advance a slide deck, and it stays in the
        // document even when the paste that follows it fails.
        let payload = Self.needsSeparator(before: target?.value) ? " " + cleaned : cleaned
        _ = pasteboard.setString(payload)

        guard canPaste else {
            return TextInsertionResult(outcome: .copied)
        }

        guard sendPaste() else { return TextInsertionResult(outcome: .copied) }
        return TextInsertionResult(outcome: .insertedAndCopied)
    }

    private static func canPasteInto(_ target: TextInsertionTarget) -> Bool {
        guard !target.isSecure else { return false }
        return target.isEditable || target.role.map(editableRoles.contains) == true
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
        let subrole = stringAttribute(kAXSubroleAttribute, from: focused)
        let value = stringAttribute(kAXValueAttribute, from: focused)
        let hasSelectedTextRange = attributeIsAvailable(kAXSelectedTextRangeAttribute, on: focused)
        let valueIsSettable = attributeIsSettable(kAXValueAttribute, on: focused)
        let isEditable = editableRoles.contains(role ?? "")
            || hasSelectedTextRange
            || (value != nil && valueIsSettable)
        return TextInsertionTarget(role: role, value: value, isEditable: isEditable, subrole: subrole)
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
}
