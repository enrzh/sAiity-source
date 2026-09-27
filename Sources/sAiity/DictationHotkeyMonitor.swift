import AppKit
import Carbon.HIToolbox
import CoreGraphics

struct DictationChord: Codable, Equatable, Sendable {
    let keyCodes: Set<UInt16>

    /// The chord a fresh install gets.
    ///
    /// This used to be a bare Control key, which is not a shortcut so much as a
    /// foot-gun: the monitor is an event tap that is live from launch, so every
    /// Control press in every app — every Ctrl-click, every Emacs-style caret
    /// movement, every app with a Control-based shortcut — opened the microphone
    /// and started a recording. A real chord with a non-modifier key cannot fire
    /// by accident.
    ///
    /// Installs that already stored a chord keep it. This only decides what
    /// "the user never chose one" means.
    static let defaultControl = DictationChord(
        keyCodes: [UInt16(kVK_Command), UInt16(kVK_Option), UInt16(kVK_Space)])

    init(keyCodes: Set<UInt16>) {
        self.keyCodes = keyCodes.isEmpty ? Self.defaultControl.keyCodes : keyCodes
    }

    var displayString: String {
        keyCodes.sorted { Self.sortOrder($0) < Self.sortOrder($1) }
            .map(Self.keyName)
            .joined()
    }

    /// A chord has to carry a modifier *and* a real key.
    ///
    /// Requiring the modifier stops a bare letter from firing while typing.
    /// Requiring the non-modifier stops the mirror-image mistake: a bare
    /// modifier, which fires on every press of it in every app no matter what
    /// else is being typed.
    var isUsable: Bool {
        keyCodes.contains(where: Self.isModifierKey)
            && keyCodes.contains(where: { !Self.isModifierKey($0) })
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

    private static func sortOrder(_ code: UInt16) -> Int {
        switch Int(code) {
        case kVK_Command, kVK_RightCommand: 0
        case kVK_Option, kVK_RightOption: 1
        case kVK_Control, kVK_RightControl: 2
        case kVK_Shift, kVK_RightShift: 3
        case kVK_Function: 4
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

    enum Effect: Equatable, Sendable { case none, start, stop }

    private let chord: DictationChord
    private(set) var pressed: Set<UInt16> = []
    private var active = false

    init(chord: DictationChord) { self.chord = chord }

    mutating func handle(_ input: Input) -> Effect {
        switch input {
        case .flagsChanged(let key, let isDown):
            if isDown { pressed.insert(key) } else { pressed.remove(key) }
        case .keyDown(let key):
            pressed.insert(key)
        case .keyUp(let key):
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
        active = false
    }

    private mutating func evaluate() -> Effect {
        let matches = chord.matches(pressed)
        if matches, !active { active = true; return .start }
        if !matches, active { active = false; return .stop }
        return .none
    }
}

struct DictationChordCaptureState: Sendable {
    private var pressed: Set<UInt16> = []
    private var captured: Set<UInt16> = []

    mutating func handle(_ input: DictationChordState.Input) -> DictationChord? {
        switch input {
        case .flagsChanged(let key, let isDown):
            if isDown {
                pressed.insert(key)
                captured.insert(key)
            } else {
                pressed.remove(key)
            }
        case .keyDown(let key):
            pressed.insert(key)
            captured.insert(key)
        case .keyUp(let key):
            pressed.remove(key)
        }
        guard pressed.isEmpty, !captured.isEmpty else { return nil }
        let chord = DictationChord(keyCodes: captured)
        defer { reset() }
        return chord.isUsable ? chord : nil
    }

    mutating func reset() {
        pressed.removeAll()
        captured.removeAll()
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

    @discardableResult
    func start(onPress: @escaping @Sendable () -> Void,
               onRelease: @escaping @Sendable () -> Void) -> Bool {
        lock.lock()
        if eventTap != nil { lock.unlock(); return true }
        self.onPress = onPress
        self.onRelease = onRelease
        lock.unlock()

        let thread = DictationHotkeyThread()
        thread.name = "sAiity Dictation Hotkey"
        thread.start()
        thread.waitUntilReady()
        let request = DictationTapRequest()
        perform(#selector(installTap(_:)), on: thread, with: request, waitUntilDone: true)
        guard request.succeeded else {
            perform(#selector(uninstallTap), on: thread, with: nil, waitUntilDone: true)
            lock.withLock { self.onPress = nil; self.onRelease = nil }
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
        }
    }

    private func handle(type: CGEventType, event: CGEvent) {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
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
            guard chord.observes(key) else { return .none }
            if requiresAllKeysReleased {
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
            return chordState.handle(input)
        }
        let callback: (@Sendable () -> Void)? = lock.withLock {
            switch effect {
            case .none: return nil
            case .start: return onPress
            case .stop: return onRelease
            }
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
            request.succeeded = false
            return
        }
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        lock.withLock { eventTap = tap; runLoopSource = source }
        request.succeeded = true
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
