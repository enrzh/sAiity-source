import AppKit
import Carbon.HIToolbox
import CoreGraphics

struct DictationChord: Codable, Equatable, Sendable {
    let keyCodes: Set<UInt16>

    /// The chord a fresh install gets: hold Control and Option.
    ///
    /// The first default was a bare Control key, which fired on every
    /// Ctrl-click and Emacs-style caret movement. The second, ⌘⌥Space, is
    /// Finder search on a standard Mac, so pressing it opened a Finder window
    /// instead of dictating. Two modifiers held on their own belong to no macOS
    /// shortcut, and `DictationChordState` cancels the recording the moment any
    /// other key joins them, so ⌃⌥→ and VoiceOver commands stay what they were.
    ///
    /// Installs that already stored a chord keep it. This only decides what
    /// "the user never chose one" means.
    static let defaultControl = DictationChord(
        keyCodes: [UInt16(kVK_Control), UInt16(kVK_Option)])

    init(keyCodes: Set<UInt16>) {
        self.keyCodes = keyCodes.isEmpty ? Self.defaultControl.keyCodes : keyCodes
    }

    var displayString: String {
        keyCodes.sorted { Self.sortOrder($0) < Self.sortOrder($1) }
            .map(Self.keyName)
            .joined()
    }

    /// A chord is a modifier plus a real key, or at least two modifiers held
    /// on their own.
    ///
    /// Requiring a modifier stops a bare letter from firing while typing. A
    /// single bare modifier stays refused: it fires on every press of it in
    /// every app. Two modifiers alone are safe because a modifier-only chord is
    /// cancelled as soon as anything else is pressed with it.
    var isUsable: Bool {
        let hasModifier = keyCodes.contains(where: Self.isModifierKey)
        let hasKey = keyCodes.contains { !Self.isModifierKey($0) }
        if hasModifier && hasKey { return true }
        return isModifierOnly && modifierFamilies.count >= 2
    }

    /// Only modifier keys, such as ⌃⌥. Held, these start dictation; any other
    /// key pressed with them means the user is typing a shortcut instead.
    var isModifierOnly: Bool {
        !keyCodes.isEmpty && keyCodes.allSatisfy(Self.isModifierKey)
    }

    private var modifierFamilies: Set<UInt16> {
        Set(keyCodes.compactMap { Self.modifierFamily(for: $0)?.min() })
    }

    /// The modifier mask and key code macOS uses for this chord in its own
    /// keyboard shortcuts, or nil when the chord has no single real key.
    var symbolicHotKey: (keyCode: Int, modifiers: Int)? {
        let keys = keyCodes.filter { !Self.isModifierKey($0) }
        guard keys.count == 1, let key = keys.first else { return nil }
        var mask = 0
        for code in keyCodes {
            switch Int(code) {
            case kVK_Shift, kVK_RightShift: mask |= 1 << 17
            case kVK_Control, kVK_RightControl: mask |= 1 << 18
            case kVK_Option, kVK_RightOption: mask |= 1 << 19
            case kVK_Command, kVK_RightCommand: mask |= 1 << 20
            case kVK_Function: mask |= 1 << 23
            default: break
            }
        }
        return (Int(key), mask)
    }

    /// A modifier key is displayed without a left/right qualifier, so the
    /// physical key on either side must satisfy the same shortcut.
    func matches(_ pressed: Set<UInt16>) -> Bool {
        var available = pressed
        for required in keyCodes {
            let match = Self.candidates(for: required).first(where: available.contains)
            guard let match else { return false }
            available.remove(match)
        }
        return true
    }

    func observes(_ key: UInt16) -> Bool {
        keyCodes.contains(key) || keyCodes.contains { Self.candidates(for: $0).contains(key) }
    }

    var observedKeyCodes: Set<UInt16> {
        keyCodes.reduce(into: Set<UInt16>()) { result, key in
            result.formUnion(Self.candidates(for: key))
        }
    }

    static var current: DictationChord {
        get {
            guard let data = UserDefaults.standard.data(forKey: "dictationChord"),
                  let chord = try? JSONDecoder().decode(DictationChord.self, from: data),
                  !chord.keyCodes.isEmpty else { return .defaultControl }
            return chord
        }
        set {
            if let data = try? JSONEncoder().encode(newValue) {
                UserDefaults.standard.set(data, forKey: "dictationChord")
            }
        }
    }

    static func keyCodes(from flags: NSEvent.ModifierFlags) -> Set<UInt16> {
        var keys: Set<UInt16> = []
        if flags.contains(.command) { keys.insert(UInt16(kVK_Command)) }
        if flags.contains(.option) { keys.insert(UInt16(kVK_Option)) }
        if flags.contains(.control) { keys.insert(UInt16(kVK_Control)) }
        if flags.contains(.shift) { keys.insert(UInt16(kVK_Shift)) }
        if flags.contains(.function) { keys.insert(UInt16(kVK_Function)) }
        return keys
    }

    static func modifierIsDown(_ key: UInt16, flags: NSEvent.ModifierFlags) -> Bool {
        switch Int(key) {
        case kVK_Command, kVK_RightCommand: flags.contains(.command)
        case kVK_Option, kVK_RightOption: flags.contains(.option)
        case kVK_Control, kVK_RightControl: flags.contains(.control)
        case kVK_Shift, kVK_RightShift: flags.contains(.shift)
        case kVK_Function: flags.contains(.function)
        default: false
        }
    }

    static func modifierIsDown(_ key: UInt16, flags: CGEventFlags) -> Bool {
        switch Int(key) {
        case kVK_Command, kVK_RightCommand: flags.contains(.maskCommand)
        case kVK_Option, kVK_RightOption: flags.contains(.maskAlternate)
        case kVK_Control, kVK_RightControl: flags.contains(.maskControl)
        case kVK_Shift, kVK_RightShift: flags.contains(.maskShift)
        case kVK_Function: flags.contains(.maskSecondaryFn)
        default: false
        }
    }

    static func modifierFamily(for key: UInt16) -> Set<UInt16>? {
        switch Int(key) {
        case kVK_Command, kVK_RightCommand:
            [UInt16(kVK_Command), UInt16(kVK_RightCommand)]
        case kVK_Option, kVK_RightOption:
            [UInt16(kVK_Option), UInt16(kVK_RightOption)]
        case kVK_Control, kVK_RightControl:
            [UInt16(kVK_Control), UInt16(kVK_RightControl)]
        case kVK_Shift, kVK_RightShift:
            [UInt16(kVK_Shift), UInt16(kVK_RightShift)]
        case kVK_Function:
            [UInt16(kVK_Function)]
        default: nil
        }
    }

    private static func candidates(for key: UInt16) -> Set<UInt16> {
        modifierFamily(for: key) ?? [key]
    }

    private static func isModifierKey(_ key: UInt16) -> Bool {
        modifierFamily(for: key) != nil
    }

    /// The order macOS menus print modifiers in: fn ⌃ ⌥ ⇧ ⌘, then the key.
    private static func sortOrder(_ code: UInt16) -> Int {
        switch Int(code) {
        case kVK_Function: 0
        case kVK_Control, kVK_RightControl: 1
        case kVK_Option, kVK_RightOption: 2
        case kVK_Shift, kVK_RightShift: 3
        case kVK_Command, kVK_RightCommand: 4
        default: 100 + Int(code)
        }
    }

    static func keyName(_ code: UInt16) -> String {
        switch Int(code) {
        case kVK_Command, kVK_RightCommand: "⌘"
        case kVK_Option, kVK_RightOption: "⌥"
        case kVK_Control, kVK_RightControl: "⌃"
        case kVK_Shift, kVK_RightShift: "⇧"
        case kVK_Function: "fn"
        case kVK_Space: "Space"
        case kVK_Return: "Return"
        case kVK_Tab: "Tab"
        case kVK_Escape: "Escape"
        default: Shortcut.keyName(UInt32(code)) ?? "Key \(code)"
        }
    }
}

struct DictationChordState: Sendable {
    enum Input: Equatable, Sendable {
        case flagsChanged(UInt16, isDown: Bool)
        case keyDown(UInt16)
        case keyUp(UInt16)
    }

    /// `cancel` ends a recording without delivering it: another key joined a
    /// modifier-only chord, so the user was typing a shortcut, not dictating.
    enum Effect: Equatable, Sendable { case none, start, stop, cancel }

    private let chord: DictationChord
    private(set) var pressed: Set<UInt16> = []
    private var active = false
    /// Modifiers outside the chord that are held right now. A modifier-only
    /// chord must not start while one is down: ⌘ held first and ⌃⌥ added is
    /// the start of a ⌃⌥⌘ shortcut.
    private var foreignModifiers: Set<UInt16> = []
    /// After a cancel the chord stays inert until its keys are released, so
    /// letting go of the arrow in ⌃⌥→ does not start a recording.
    private var blocked = false

    init(chord: DictationChord) { self.chord = chord }

    mutating func handle(_ input: Input) -> Effect {
        switch input {
        case .flagsChanged(let key, let isDown):
            guard chord.observes(key) else { return foreign(key, isDown: isDown, isModifier: true) }
            if isDown { pressed.insert(key) } else { pressed.remove(key) }
        case .keyDown(let key):
            guard chord.observes(key) else { return foreign(key, isDown: true, isModifier: false) }
            pressed.insert(key)
        case .keyUp(let key):
            guard chord.observes(key) else { return foreign(key, isDown: false, isModifier: false) }
            pressed.remove(key)
        }
        return evaluate()
    }

    mutating func sync(pressed: Set<UInt16>) -> Effect {
        self.pressed = pressed
        return evaluate()
    }

    mutating func resetAfterEventTapDisabled() {
        pressed.removeAll()
        foreignModifiers.removeAll()
        active = false
        blocked = false
    }

    /// Keys outside the chord only matter to a modifier-only chord. A chord
    /// with a real key keeps its old behaviour: extra keys are ignored.
    ///
    /// Any other key pressed while a chord key is held makes this hold part of
    /// a bigger shortcut, such as ⌃⌥→ or ⌃A: a running recording is
    /// cancelled, and nothing starts again until the chord keys are released.
    private mutating func foreign(_ key: UInt16, isDown: Bool, isModifier: Bool) -> Effect {
        guard chord.isModifierOnly else { return .none }
        if isModifier {
            if isDown { foreignModifiers.insert(key) } else { foreignModifiers.remove(key) }
        }
        guard isDown else { return .none }
        if !pressed.isEmpty { blocked = true }
        guard active else { return .none }
        active = false
        return .cancel
    }

    private mutating func evaluate() -> Effect {
        if pressed.isEmpty { blocked = false }
        let matches = chord.matches(pressed) && !blocked
            && (!chord.isModifierOnly || foreignModifiers.isEmpty)
        if matches, !active { active = true; return .start }
        if !matches, active { active = false; return .stop }
        return .none
    }
}

struct DictationChordCaptureState: Sendable {
    private var pressed: Set<UInt16> = []
    private(set) var captured: Set<UInt16> = []
    /// The last complete chord that could not be used, so the recorder can
    /// say why nothing changed instead of silently waiting.
    private(set) var lastRejected: DictationChord?

    mutating func handle(_ input: DictationChordState.Input) -> DictationChord? {
        switch input {
        case .flagsChanged(let key, let isDown):
            if isDown {
                pressed.insert(key)
                captured.insert(key)
                lastRejected = nil
            } else {
                pressed.remove(key)
            }
        case .keyDown(let key):
            pressed.insert(key)
            captured.insert(key)
            lastRejected = nil
        case .keyUp(let key):
            pressed.remove(key)
        }
        guard pressed.isEmpty, !captured.isEmpty else { return nil }
        let chord = DictationChord(keyCodes: captured)
        pressed.removeAll()
        captured.removeAll()
        guard chord.isUsable else {
            lastRejected = chord
            return nil
        }
        return chord
    }

    mutating func reset() {
        pressed.removeAll()
        captured.removeAll()
        lastRejected = nil
    }
}

/// macOS's own keyboard shortcuts, read from the same preferences System
/// Settings → Keyboard → Keyboard Shortcuts writes.
///
/// A listen-only monitor cannot stop a system shortcut, so a chord macOS
/// already uses does both things at once: ⌥⌘Space opened a Finder window and
/// moved focus away from the text that dictation was meant for.
enum SystemShortcuts {
    /// What macOS does with this chord, or nil when it is free.
    static func conflict(for chord: DictationChord,
                         hotKeys: [String: Any]? = enabledHotKeys()) -> String? {
        guard let target = chord.symbolicHotKey, let hotKeys else { return nil }
        for (id, value) in hotKeys {
            guard let entry = value as? [String: Any],
                  (entry["enabled"] as? Bool ?? (entry["enabled"] as? Int).map { $0 != 0 } ?? false),
                  let parameters = (entry["value"] as? [String: Any])?["parameters"] as? [Int],
                  parameters.count >= 3,
                  parameters[1] == target.keyCode,
                  parameters[2] == target.modifiers else { continue }
            return name(for: Int(id) ?? -1)
        }
        return nil
    }

    static func enabledHotKeys() -> [String: Any]? {
        UserDefaults(suiteName: "com.apple.symbolichotkeys")?
            .dictionary(forKey: "AppleSymbolicHotKeys")
    }

    private static func name(for id: Int) -> String {
        switch id {
        case 64: String(localized: "Spotlight")
        case 65: String(localized: "Finder search")
        case 60, 61: String(localized: "switching input sources")
        case 32, 33, 34, 35, 36, 37: String(localized: "Mission Control")
        case 28, 29, 30, 31, 184: String(localized: "screenshots")
        default: String(localized: "another macOS shortcut")
        }
    }
}

/// Listen-only physical-key chord monitor based on Ghost Pepper's event model.
/// The tap owns a dedicated run loop so model preparation cannot delay key-up.
final class DictationHotkeyMonitor: NSObject, @unchecked Sendable {
    private let lock = NSLock()
    private var chord: DictationChord
    private var chordState: DictationChordState
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var eventThread: DictationHotkeyThread?
    private var suspended = false
    private var requiresAllKeysReleased = false
    private var onPress: (@Sendable () -> Void)?
    private var onRelease: (@Sendable () -> Void)?
    private var onCancel: (@Sendable () -> Void)?
    private var pressedAt: ContinuousClock.Instant?

    /// A modifier-only chord released sooner than this was a stray tap, not
    /// dictation: nobody finishes a sentence in a quarter of a second, and
    /// delivering the empty result would only flash the bubble.
    static let minimumModifierOnlyHold: Duration = .milliseconds(250)

    init(chord: DictationChord = .current) {
        self.chord = chord
        self.chordState = DictationChordState(chord: chord)
    }

    nonisolated static func isControlDown(flags: CGEventFlags) -> Bool { flags.contains(.maskControl) }
    nonisolated static func hasTransition(from previous: Bool, to current: Bool) -> Bool { previous != current }

    /// Converts one event tap edge into the state-machine input. Normal key
    /// handling must stay edge-driven; consulting the session-wide key snapshot
    /// here can briefly report a held modifier as released while another key is
    /// being delivered.
    nonisolated static func eventInput(type: CGEventType,
                                       key: UInt16,
                                       flags: CGEventFlags) -> DictationChordState.Input? {
        switch type {
        case .flagsChanged:
            guard DictationChord.modifierFamily(for: key) != nil else { return nil }
            return .flagsChanged(key, isDown: DictationChord.modifierIsDown(key, flags: flags))
        case .keyDown:
            return .keyDown(key)
        case .keyUp:
            return .keyUp(key)
        default:
            return nil
        }
    }

    func updateChord(_ chord: DictationChord) {
        lock.withLock {
            self.chord = chord
            self.chordState = DictationChordState(chord: chord)
            self.requiresAllKeysReleased = false
        }
    }

    func setSuspended(_ suspended: Bool) {
        lock.withLock {
            self.suspended = suspended
            chordState = DictationChordState(chord: chord)
            requiresAllKeysReleased = !suspended && !currentlyPressedKeys().isEmpty
        }
    }

    /// Whether macOS lets this process see every key, not just modifiers.
    ///
    /// Without Input Monitoring, macOS still creates a listen-only tap but
    /// silently narrows it to modifier changes. That tap looked like success:
    /// a ⌃⌥ chord half-worked, other keys never cancelled it, and a chord with
    /// a real key never fired at all. So the tap is only installed with full
    /// access, and the app's retry loop installs it once access arrives.
    nonisolated(unsafe) static var hasFullKeyAccess: () -> Bool = { CGPreflightListenEventAccess() }

    @discardableResult
    func start(onPress: @escaping @Sendable () -> Void,
               onRelease: @escaping @Sendable () -> Void,
               onCancel: (@Sendable () -> Void)? = nil) -> Bool {
        guard Self.hasFullKeyAccess() else {
            NSLog("sAiity dictation shortcut: waiting for Input Monitoring before listening")
            return false
        }
        lock.lock()
        if eventTap != nil { lock.unlock(); return true }
        self.onPress = onPress
        self.onRelease = onRelease
        self.onCancel = onCancel ?? onRelease
        lock.unlock()

        let thread = DictationHotkeyThread()
        thread.name = "sAiity Dictation Hotkey"
        thread.start()
        thread.waitUntilReady()
        let request = DictationTapRequest()
        perform(#selector(installTap(_:)), on: thread, with: request, waitUntilDone: true)
        guard request.succeeded else {
            perform(#selector(uninstallTap), on: thread, with: nil, waitUntilDone: true)
            lock.withLock { self.onPress = nil; self.onRelease = nil; self.onCancel = nil }
            return false
        }
        lock.withLock { eventThread = thread }
        return true
    }

    func stop() {
        let thread = lock.withLock { eventThread }
        if let thread {
            perform(#selector(uninstallTap), on: thread, with: nil, waitUntilDone: true)
        }
        lock.withLock {
            eventThread = nil
            chordState = DictationChordState(chord: chord)
            requiresAllKeysReleased = false
            onPress = nil
            onRelease = nil
            onCancel = nil
        }
    }

    private func handle(type: CGEventType, event: CGEvent) {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            NSLog("sAiity dictation shortcut: listener paused by macOS (\(type == .tapDisabledByTimeout ? "timeout" : "user input")), re-enabling")
            lock.withLock {
                chordState.resetAfterEventTapDisabled()
                requiresAllKeysReleased = !currentlyPressedKeys().isEmpty
            }
            if let tap = lock.withLock({ eventTap }) {
                CGEvent.tapEnable(tap: tap, enable: true)
            }
            return
        }
        guard type == .flagsChanged || type == .keyDown || type == .keyUp else { return }
        let key = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
        guard let input = Self.eventInput(type: type, key: key, flags: event.flags) else { return }

        let effect: DictationChordState.Effect = lock.withLock {
            guard !suspended else { return .none }
            if requiresAllKeysReleased, chord.observes(key) {
                let authoritative = Set(chord.observedKeyCodes.filter {
                    Self.physicalKeyDown($0, flags: event.flags)
                })
                if authoritative.isEmpty {
                    requiresAllKeysReleased = false
                    chordState = DictationChordState(chord: chord)
                } else if authoritative == [key] {
                    requiresAllKeysReleased = false
                } else {
                    return .none
                }
            }
            var effect = chordState.handle(input)
            switch effect {
            case .start:
                pressedAt = .now
            case .stop:
                if chord.isModifierOnly, let pressedAt,
                   ContinuousClock.now - pressedAt < Self.minimumModifierOnlyHold {
                    effect = .cancel
                }
                pressedAt = nil
            case .cancel:
                pressedAt = nil
            case .none:
                break
            }
            return effect
        }
        let callback: (@Sendable () -> Void)? = lock.withLock {
            switch effect {
            case .none: return nil
            case .start: return onPress
            case .stop: return onRelease
            case .cancel: return onCancel
            }
        }
        if effect != .none {
            NSLog("sAiity dictation shortcut: \(effect)")
        }
        callback?()
    }

    static func physicalKeyDown(_ key: UInt16, flags: CGEventFlags) -> Bool {
        if let mask = modifierMask(for: key) {
            return flags.rawValue & mask == mask
        }
        return CGEventSource.keyState(.combinedSessionState, key: CGKeyCode(key))
    }

    private func currentlyPressedKeys() -> Set<UInt16> {
        let flags = CGEventSource.flagsState(.combinedSessionState)
        return chord.observedKeyCodes.filter { Self.physicalKeyDown($0, flags: flags) }
    }

    private static func modifierMask(for key: UInt16) -> UInt64? {
        switch Int(key) {
        case kVK_Command, kVK_RightCommand: CGEventFlags.maskCommand.rawValue
        case kVK_Shift, kVK_RightShift: CGEventFlags.maskShift.rawValue
        case kVK_Option, kVK_RightOption: CGEventFlags.maskAlternate.rawValue
        case kVK_Control, kVK_RightControl: CGEventFlags.maskControl.rawValue
        case kVK_Function: CGEventFlags.maskSecondaryFn.rawValue
        default: nil
        }
    }

    @objc private func installTap(_ request: DictationTapRequest) {
        let mask = CGEventMask(1 << CGEventType.flagsChanged.rawValue)
            | CGEventMask(1 << CGEventType.keyDown.rawValue)
            | CGEventMask(1 << CGEventType.keyUp.rawValue)
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap,
                                          place: .tailAppendEventTap,
                                          options: .listenOnly,
                                          eventsOfInterest: mask,
                                          callback: Self.callback,
                                          userInfo: Unmanaged.passUnretained(self).toOpaque()) else {
            NSLog("sAiity dictation shortcut: macOS refused the keyboard listener (Input Monitoring)")
            request.succeeded = false
            return
        }
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        lock.withLock { eventTap = tap; runLoopSource = source }
        request.succeeded = true
        let display = lock.withLock { chord.displayString }
        NSLog("sAiity dictation shortcut: listening for \(display)")
    }

    @objc private func uninstallTap() {
        let pair = lock.withLock { () -> (CFMachPort?, CFRunLoopSource?) in
            defer { eventTap = nil; runLoopSource = nil }
            return (eventTap, runLoopSource)
        }
        if let tap = pair.0 { CGEvent.tapEnable(tap: tap, enable: false) }
        if let source = pair.1 { CFRunLoopRemoveSource(CFRunLoopGetCurrent(), source, .commonModes) }
        CFRunLoopStop(CFRunLoopGetCurrent())
    }

    private static let callback: CGEventTapCallBack = { _, type, event, refcon in
        guard let refcon else { return Unmanaged.passUnretained(event) }
        Unmanaged<DictationHotkeyMonitor>.fromOpaque(refcon).takeUnretainedValue()
            .handle(type: type, event: event)
        return Unmanaged.passUnretained(event)
    }
}

private final class DictationHotkeyThread: Thread, @unchecked Sendable {
    private let ready = DispatchSemaphore(value: 0)
    private let keepAlive = Port()

    override func main() {
        autoreleasepool {
            RunLoop.current.add(keepAlive, forMode: .default)
            ready.signal()
            CFRunLoopRun()
        }
    }

    func waitUntilReady() { ready.wait() }
}

private final class DictationTapRequest: NSObject { var succeeded = false }
