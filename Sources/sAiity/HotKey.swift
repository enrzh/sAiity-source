import AppKit
import Carbon.HIToolbox

/// A global keyboard shortcut.
///
/// Carbon's `RegisterEventHotKey` is used rather than
/// `NSEvent.addGlobalMonitorForEvents` deliberately: a global *keyboard* monitor
/// requires Accessibility permission, which would be a second scary prompt on
/// top of Screen Recording. Carbon hot keys need no permission at all. The API
/// is ancient but it is not deprecated and it is what every menu-bar utility
/// still uses.
struct Shortcut: Equatable, Codable, Sendable {
    var keyCode: UInt32
    var modifiers: UInt32      // Carbon modifier mask

    /// ⌥⌘C — unclaimed by macOS and by the apps this sits on top of.
    static let defaultToggle = Shortcut(keyCode: UInt32(kVK_ANSI_C),
                                        modifiers: UInt32(optionKey | cmdKey))

    var displayString: String {
        var s = ""
        if modifiers & UInt32(controlKey) != 0 { s += "⌃" }
        if modifiers & UInt32(optionKey)  != 0 { s += "⌥" }
        if modifiers & UInt32(shiftKey)   != 0 { s += "⇧" }
        if modifiers & UInt32(cmdKey)     != 0 { s += "⌘" }
        return s + (Self.keyName(keyCode) ?? "?")
    }

    static func keyName(_ code: UInt32) -> String? {
        let map: [Int: String] = [
            kVK_ANSI_A: "A", kVK_ANSI_B: "B", kVK_ANSI_C: "C", kVK_ANSI_D: "D",
            kVK_ANSI_E: "E", kVK_ANSI_F: "F", kVK_ANSI_G: "G", kVK_ANSI_H: "H",
            kVK_ANSI_I: "I", kVK_ANSI_J: "J", kVK_ANSI_K: "K", kVK_ANSI_L: "L",
            kVK_ANSI_M: "M", kVK_ANSI_N: "N", kVK_ANSI_O: "O", kVK_ANSI_P: "P",
            kVK_ANSI_Q: "Q", kVK_ANSI_R: "R", kVK_ANSI_S: "S", kVK_ANSI_T: "T",
            kVK_ANSI_U: "U", kVK_ANSI_V: "V", kVK_ANSI_W: "W", kVK_ANSI_X: "X",
            kVK_ANSI_Y: "Y", kVK_ANSI_Z: "Z",
            kVK_ANSI_0: "0", kVK_ANSI_1: "1", kVK_ANSI_2: "2", kVK_ANSI_3: "3",
            kVK_ANSI_4: "4", kVK_ANSI_5: "5", kVK_ANSI_6: "6", kVK_ANSI_7: "7",
            kVK_ANSI_8: "8", kVK_ANSI_9: "9",
            kVK_Space: String(localized: "Space"), kVK_Return: "↩", kVK_Escape: "⎋", kVK_Tab: "⇥",
            kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5",
            kVK_F6: "F6", kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10",
            kVK_F11: "F11", kVK_F12: "F12", kVK_F13: "F13", kVK_F14: "F14",
            kVK_F15: "F15", kVK_F16: "F16", kVK_F17: "F17", kVK_F18: "F18",
            kVK_F19: "F19", kVK_F20: "F20",
        ]
        return map[Int(code)]
    }

    /// AppKit modifier flags -> Carbon mask, for translating a recorded event.
    static func carbonModifiers(from flags: NSEvent.ModifierFlags) -> UInt32 {
        var m: UInt32 = 0
        if flags.contains(.control) { m |= UInt32(controlKey) }
        if flags.contains(.option)  { m |= UInt32(optionKey) }
        if flags.contains(.shift)   { m |= UInt32(shiftKey) }
        if flags.contains(.command) { m |= UInt32(cmdKey) }
        return m
    }

    /// A shortcut with no modifier would fire while typing anywhere on the
    /// system. Require at least one of ⌃⌥⌘ (shift alone is not enough).
    var isUsable: Bool {
        modifiers & UInt32(controlKey | optionKey | cmdKey) != 0
            && Self.keyName(keyCode) != nil
    }
}

/// Registers global hot keys and routes them to handlers.
@MainActor
final class HotKeyCenter {
    static let shared = HotKeyCenter()

    enum Action: String, CaseIterable {
        case toggleCaptions
        case copyLastLine

        var title: String {
            switch self {
            case .toggleCaptions: return String(localized: "Start / stop captions")
            case .copyLastLine:   return String(localized: "Copy the current caption")
            }
        }
        var defaultShortcut: Shortcut? {
            switch self {
            case .toggleCaptions: return .defaultToggle
            case .copyLastLine:   return nil
            }
        }
        var defaultsKey: String { "shortcut.\(rawValue)" }
    }

    private var refs: [Action: EventHotKeyRef] = [:]
    private var handlers: [Action: () -> Void] = [:]
    private var installed = false

    /// Persisted shortcut for an action, falling back to its default. A stored
    /// empty value means the user deliberately cleared it.
    nonisolated static func shortcut(for action: Action) -> Shortcut? {
        let d = UserDefaults.standard
        guard let data = d.data(forKey: action.defaultsKey) else { return action.defaultShortcut }
        if data.isEmpty { return nil }
        return try? JSONDecoder().decode(Shortcut.self, from: data)
    }

    nonisolated static func setShortcut(_ s: Shortcut?, for action: Action) {
        let d = UserDefaults.standard
        if let s, let data = try? JSONEncoder().encode(s) {
            d.set(data, forKey: action.defaultsKey)
        } else {
            d.set(Data(), forKey: action.defaultsKey)   // explicit "none"
        }
    }

    func register(_ action: Action, handler: @escaping () -> Void) {
        handlers[action] = handler
        installHandlerIfNeeded()
        rebind(action)
    }

    /// Re-read the stored shortcut and re-register. Called after the user edits it.
    func rebind(_ action: Action) {
        if let existing = refs[action] {
            UnregisterEventHotKey(existing)
            refs[action] = nil
        }
        guard let s = Self.shortcut(for: action), s.isUsable else { return }

        var ref: EventHotKeyRef?
        // The signature is arbitrary but must be stable; the id indexes our table.
        let hotKeyID = EventHotKeyID(signature: OSType(0x73416974 /* 'sAit' */),
                                     id: UInt32(Action.allCases.firstIndex(of: action) ?? 0))
        let status = RegisterEventHotKey(s.keyCode, s.modifiers, hotKeyID,
                                         GetApplicationEventTarget(), 0, &ref)
        if status == noErr, let ref {
            NSLog("sAiity hotkey registered: \(action.rawValue) = \(s.displayString)")
            refs[action] = ref
        } else {
            // Almost always means another app already owns this combination.
            NSLog("sAiity hotkey \(action.rawValue) failed to register: \(status)")
        }
    }

    func rebindAll() { Action.allCases.forEach { rebind($0) } }

    private func installHandlerIfNeeded() {
        guard !installed else { return }
        installed = true
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                 eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ -> OSStatus in
            var id = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject),
                              EventParamType(typeEventHotKeyID), nil,
                              MemoryLayout<EventHotKeyID>.size, nil, &id)
            let idx = Int(id.id)
            MainActor.assumeIsolated {
                guard idx < HotKeyCenter.Action.allCases.count else { return }
                let action = HotKeyCenter.Action.allCases[idx]
                NSLog("sAiity hotkey fired: \(action.rawValue)")
                HotKeyCenter.shared.handlers[action]?()
            }
            return noErr
        }, 1, &spec, nil, nil)
    }
}
