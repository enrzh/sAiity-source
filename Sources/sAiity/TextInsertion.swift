import AppKit
import ApplicationServices
import Carbon.HIToolbox
import CoreGraphics
import CryptoKit
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
        case copyFailed
    }

    let outcome: Outcome
    var secureTargetObserved = false
    /// SHA-256 of the exact UTF-8 payload successfully written to the clipboard.
    var payloadSHA256: String? = nil
    /// Copied only because Accessibility is off, so the message can say what
    /// would make the next dictation paste by itself.
    var accessibilityMissing = false

    var deliveryEndpoint: String? {
        switch outcome {
        case .copied: "copied"
        case .insertedAndCopied: "paste-dispatched"
        case .copyFailed: nil
        }
    }
}

/// The accessibility snapshot used for one dictation insertion. Keeping role,
/// subrole, value, and editability together avoids making separate
/// focused-element queries that can disagree while another app is handling
/// keyboard events.
struct TextInsertionTarget: Equatable {
    let role: String?
    /// Bounded text immediately before the selection start. Legacy injected
    /// snapshots may still supply an end-of-field prefix here.
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
    /// The one character right after the caret or selection, or nil at the
    /// end of the text. Only used to decide on a trailing space, so text
    /// inserted before a word does not run into it ("tomorrowbeta").
    var following: String? = nil

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
// AX handles are retained here and inspected only by the main-actor inserter.
struct DictationFocusToken: Equatable, @unchecked Sendable {
    let processIdentifier: pid_t
    let bundleIdentifier: String?
    var field: AXUIElement? = nil

    static func == (lhs: Self, rhs: Self) -> Bool {
        guard lhs.processIdentifier == rhs.processIdentifier,
              lhs.bundleIdentifier == rhs.bundleIdentifier else { return false }
        switch (lhs.field, rhs.field) {
        case (nil, nil): return true
        case let (left?, right?): return CFEqual(left, right)
        default: return false
        }
    }
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
    nonisolated static let secureRole = "AXSecureTextField"

    private static let accessibilityTimeout: Float = 0.2

    private let pasteboard: any DictationPasteboard
    private let accessibilityTrusted: @MainActor () -> Bool
    private let focusedElement: @MainActor () -> TextInsertionTarget?
    private let sendPaste: @MainActor () -> Bool
    private let currentFocus: @MainActor () -> DictationFocusToken?

    init(pasteboard: any DictationPasteboard = SystemDictationPasteboard(),
         accessibilityTrusted: @escaping @MainActor () -> Bool = AXIsProcessTrusted,
         focusedElement: @escaping @MainActor () -> TextInsertionTarget? = TextInserter.currentFocusedElement,
         sendPaste: @escaping @MainActor () -> Bool = TextInserter.postPaste,
         currentFocus: @escaping @MainActor () -> DictationFocusToken? = TextInserter.currentFocusToken) {
        self.pasteboard = pasteboard
        self.accessibilityTrusted = accessibilityTrusted
        self.focusedElement = focusedElement
        self.sendPaste = sendPaste
        self.currentFocus = currentFocus
    }

    /// The frontmost app right now, for `captureFocus()`.
    static func currentFocusToken() -> DictationFocusToken? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        guard AXIsProcessTrusted() else {
            return DictationFocusToken(processIdentifier: app.processIdentifier,
                                       bundleIdentifier: app.bundleIdentifier)
        }
        exposeAccessibilityTree(of: app.processIdentifier, bundleIdentifier: app.bundleIdentifier)
        // Only a real text input counts as "the field". A browser that has not
        // built its tree yet reports its whole web area, which would never
        // match the text area it reports a moment later.
        let field = currentFocusedUIElement().flatMap { isTextInput($0) ? $0 : nil }
        return DictationFocusToken(processIdentifier: app.processIdentifier,
                                   bundleIdentifier: app.bundleIdentifier,
                                   field: field)
    }

    private static var exposedProcesses = Set<pid_t>()

    /// Browsers built on Chromium. They ignore `AXManualAccessibility` and
    /// expose page content only with `AXEnhancedUserInterface`, the switch a
    /// screen reader uses. It is not set for other apps: some animate window
    /// changes differently while it is on.
    static let chromiumBrowsers: Set<String> = [
        "com.google.Chrome", "com.google.Chrome.beta", "com.google.Chrome.canary",
        "com.microsoft.edgemac", "com.brave.Browser", "company.thebrowser.Browser",
        "com.operasoftware.Opera", "com.vivaldi.Vivaldi", "org.chromium.Chromium",
    ]

    /// Chromium and Electron apps (Chrome, Slack, VS Code and many more) build
    /// their accessibility tree only when an assistive app asks for it. Until
    /// then a page's text area is invisible, so dictation could only copy.
    /// `AXManualAccessibility` is Electron's switch; other apps ignore it.
    private static func exposeAccessibilityTree(of pid: pid_t, bundleIdentifier: String?) {
        guard exposedProcesses.insert(pid).inserted else { return }
        let app = AXUIElementCreateApplication(pid)
        _ = AXUIElementSetMessagingTimeout(app, accessibilityTimeout)
        _ = AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        if let bundleIdentifier, chromiumBrowsers.contains(bundleIdentifier) {
            _ = AXUIElementSetAttributeValue(app, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
        }
    }

    private static func isTextInput(_ element: AXUIElement) -> Bool {
        var roleValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &roleValue) == .success,
              let role = roleValue as? String else { return false }
        if editableRoles.contains(role) || role == secureRole { return true }
        var range: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &range) == .success
    }

    /// Record which app the user was in when dictation started. Call this at the
    /// press, not at the insertion.
    func captureFocus() -> DictationFocusToken? {
        currentFocus()
    }

    /// Insert dictated text, but only into the app that was focused when
    /// dictation started. If the user switched apps while the model was working,
    /// the text is still copied — it is just not pasted somewhere they did not
    /// ask for.
    func insert(_ text: String, expecting expected: DictationFocusToken?) -> TextInsertionResult {
        guard let expected, isStillFrontmost(expected) else {
            let trusted = accessibilityTrusted()
            let target = trusted ? focusedElement() : nil
            var result = copy(text)
            result.secureTargetObserved = target?.isSecure == true
            result.accessibilityMissing = !trusted
            return result
        }
        return insert(text, shouldPaste: { self.isStillFrontmost(expected) })
    }

    private func isStillFrontmost(_ token: DictationFocusToken) -> Bool {
        guard let current = currentFocus() else { return false }
        if current.processIdentifier != token.processIdentifier { return false }
        // Some apps expose no bundle identifier; the process identity is enough
        // in that case, and requiring both would reject perfectly good targets.
        if let expectedID = token.bundleIdentifier, let currentID = current.bundleIdentifier,
           expectedID != currentID { return false }
        // No text field could be identified at the press: typically an app
        // that was still building its accessibility tree. The same app still
        // in front is the best evidence there is; the paste itself still
        // requires an editable, non-secure field at insertion time.
        guard let expectedField = token.field else { return true }
        guard let currentField = current.field, CFEqual(expectedField, currentField) else { return false }
        return true
    }

    func insert(_ text: String) -> TextInsertionResult {
        insert(text, shouldPaste: { true })
    }

    /// Retry copies only; it must never paste into a newly focused destination.
    func copy(_ text: String) -> TextInsertionResult {
        let copied = pasteboard.setString(text)
        return TextInsertionResult(outcome: copied ? .copied : .copyFailed,
                                   payloadSHA256: copied ? Self.payloadSHA256(text) : nil)
    }

    private func insert(_ text: String, shouldPaste: () -> Bool) -> TextInsertionResult {
        let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else {
            return copy(cleaned)
        }

        let trusted = accessibilityTrusted()
        let target = trusted ? focusedElement() : nil
        let canPaste = target.map(Self.canPasteInto) == true
        // The separating space rides inside the pasted string rather than being
        // posted as its own keystroke. A synthetic Space is delivered to
        // whatever happens to be focused when the event lands — it can become
        // part of a Terminal command, advance a slide deck, and it stays in the
        // document even when the paste that follows it fails.
        var payload = canPaste && Self.needsSeparator(before: target?.value) ? " " + cleaned : cleaned
        if canPaste, Self.needsSeparator(after: cleaned, following: target?.following) { payload += " " }
        guard pasteboard.setString(payload) else {
            return TextInsertionResult(outcome: .copyFailed, secureTargetObserved: target?.isSecure == true)
        }
        let payloadSHA256 = Self.payloadSHA256(payload)

        guard canPaste, shouldPaste() else {
            return TextInsertionResult(outcome: .copied, secureTargetObserved: target?.isSecure == true,
                                       payloadSHA256: payloadSHA256, accessibilityMissing: !trusted)
        }

        guard sendPaste() else { return TextInsertionResult(outcome: .copied, payloadSHA256: payloadSHA256) }
        return TextInsertionResult(outcome: .insertedAndCopied, payloadSHA256: payloadSHA256)
    }

    private static func payloadSHA256(_ payload: String) -> String {
        SHA256.hash(data: Data(payload.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private static func canPasteInto(_ target: TextInsertionTarget) -> Bool {
        guard !target.isSecure else { return false }
        return target.isEditable || target.role.map(editableRoles.contains) == true
    }

    /// Separates a phrase at the selection start without duplicating whitespace.
    private static func needsSeparator(before precedingContext: String?) -> Bool {
        precedingContext?.last?.isWhitespace == false
    }

    /// A space after the dictated text only when a word follows directly:
    /// not before punctuation or whitespace, and not between scripts that
    /// are written without spaces.
    static func needsSeparator(after text: String, following: String?) -> Bool {
        guard let next = following?.first, let last = text.last,
              next.isLetter || next.isNumber,
              !last.isWhitespace,
              !writtenWithoutSpaces(next), !writtenWithoutSpaces(last) else { return false }
        return true
    }

    private static func writtenWithoutSpaces(_ character: Character) -> Bool {
        character.unicodeScalars.contains { scalar in
            scalar.properties.isIdeographic || (0x3040...0x30FF).contains(scalar.value)
        }
    }

    private static func currentFocusedUIElement() -> AXUIElement? {
        let system = AXUIElementCreateSystemWide()
        if AXUIElementSetMessagingTimeout(system, accessibilityTimeout) == .success,
           let element = focusedElement(of: system) {
            return element
        }
        // Chrome answers the system-wide query with "cannot complete" even when
        // its own focused element is a perfectly good text area. Ask the
        // frontmost app directly before giving up.
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        let element = AXUIElementCreateApplication(app.processIdentifier)
        guard AXUIElementSetMessagingTimeout(element, accessibilityTimeout) == .success else { return nil }
        return focusedElement(of: element)
    }

    private static func focusedElement(of element: AXUIElement) -> AXUIElement? {
        var focusedValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element,
                                            kAXFocusedUIElementAttribute as CFString,
                                            &focusedValue) == .success,
              let focusedValue,
              CFGetTypeID(focusedValue) == AXUIElementGetTypeID() else { return nil }
        return (focusedValue as! AXUIElement)
    }

    private static func currentFocusedElement() -> TextInsertionTarget? {
        guard let focused = currentFocusedUIElement() else { return nil }
        return currentFocusedElement(from: focused)
    }

    static func currentFocusedElement(
        from focused: AXUIElement,
        copyAttributeValue: (AXUIElement, CFString, UnsafeMutablePointer<CFTypeRef?>) -> AXError = AXUIElementCopyAttributeValue,
        copyParameterizedAttributeValue: (AXUIElement, CFString, CFTypeRef, UnsafeMutablePointer<CFTypeRef?>) -> AXError = AXUIElementCopyParameterizedAttributeValue,
        setMessagingTimeout: (AXUIElement, Float) -> AXError = AXUIElementSetMessagingTimeout
    ) -> TextInsertionTarget? {
        guard setMessagingTimeout(focused, accessibilityTimeout) == .success else { return nil }
        var roleValue: CFTypeRef?
        guard copyAttributeValue(focused, kAXRoleAttribute as CFString, &roleValue) == .success,
              let role = roleValue as? String else { return nil }
        if role == secureRole {
            return TextInsertionTarget(role: role, value: nil, isEditable: false)
        }

        var subroleValue: CFTypeRef?
        let subroleError = copyAttributeValue(focused, kAXSubroleAttribute as CFString, &subroleValue)
        // A failed security classification must not turn a password field into
        // an ordinary editable target. Missing subroles are normal for editors.
        guard subroleError == .success || subroleError == .attributeUnsupported || subroleError == .noValue else { return nil }
        let subrole = subroleValue as? String
        guard subroleError != .success || subrole != nil else { return nil }
        if subrole == secureRole {
            return TextInsertionTarget(role: role, value: nil, isEditable: false, subrole: subrole)
        }

        var selectionValue: CFTypeRef?
        let hasSelectedTextRange = copyAttributeValue(focused, kAXSelectedTextRangeAttribute as CFString,
                                                      &selectionValue) == .success
        let isEditable = editableRoles.contains(role) || hasSelectedTextRange
            || attributeIsSettable(kAXValueAttribute, on: focused)
        let target = TextInsertionTarget(role: role, value: nil, isEditable: isEditable, subrole: subrole)
        guard isEditable, hasSelectedTextRange, let selectionValue,
              CFGetTypeID(selectionValue) == AXValueGetTypeID() else { return target }
        var selection = CFRange()
        guard AXValueGetValue(selectionValue as! AXValue, .cfRange, &selection),
              selection.location >= 0, selection.length >= 0,
              selection.location <= Int.max - selection.length - 1 else { return target }

        // One UTF-16 unit after the selection, for the trailing space. Asked
        // first so the bounded preceding query below stays the last one.
        var followingRange = CFRange(location: selection.location + selection.length, length: 1)
        var following: String?
        if let rangeValue = AXValueCreate(.cfRange, &followingRange) {
            var followingValue: CFTypeRef?
            if copyParameterizedAttributeValue(focused, kAXStringForRangeParameterizedAttribute as CFString,
                                               rangeValue, &followingValue) == .success,
               let text = followingValue as? String, text.utf16.count == 1 {
                following = text
            }
        }
        let withFollowing = TextInsertionTarget(role: role, value: nil, isEditable: isEditable,
                                                subrole: subrole, following: following)
        guard selection.location > 0 else { return withFollowing }

        // AX offsets are UTF-16. Query only before the selection start, so
        // replacement text and an unrelated document suffix cannot affect it.
        let length = min(selection.location, 32)
        var precedingRange = CFRange(location: selection.location - length, length: length)
        guard let rangeValue = AXValueCreate(.cfRange, &precedingRange) else { return withFollowing }
        var contextValue: CFTypeRef?
        guard copyParameterizedAttributeValue(focused, kAXStringForRangeParameterizedAttribute as CFString,
                                               rangeValue, &contextValue) == .success,
              let context = contextValue as? String,
              context.utf16.count <= length else { return withFollowing }
        return TextInsertionTarget(role: role, value: context, isEditable: isEditable,
                                   subrole: subrole, following: following)
    }

    private static func attributeIsSettable(_ attribute: String, on element: AXUIElement) -> Bool {
        var settable = DarwinBoolean(false)
        guard AXUIElementIsAttributeSettable(element,
                                             attribute as CFString,
                                             &settable) == .success else { return false }
        return settable.boolValue
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
