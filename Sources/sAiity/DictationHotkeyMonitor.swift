import ApplicationServices
import AppKit
import Carbon.HIToolbox
import CoreGraphics

/// Observes the default Control press-to-talk gesture without consuming any
/// keyboard event from the application the user is typing in.
@MainActor
final class DictationHotkeyMonitor {
    private let keyCode: UInt16
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var previousControlDown = false
    private var onPress: (() -> Void)?
    private var onRelease: (() -> Void)?

    init(keyCode: UInt16 = UInt16(kVK_Control)) {
        self.keyCode = keyCode
    }

    nonisolated static func isControlDown(flags: CGEventFlags) -> Bool {
        flags.contains(.maskControl)
    }

    nonisolated static func hasTransition(from previous: Bool, to current: Bool) -> Bool {
        previous != current
    }

    @discardableResult
    func start(onPress: @escaping () -> Void,
               onRelease: @escaping () -> Void) -> Bool {
        guard eventTap == nil, AXIsProcessTrusted() else { return false }

        self.onPress = onPress
        self.onRelease = onRelease

        let mask = CGEventMask(1 << CGEventType.flagsChanged.rawValue)
        let context = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: mask,
            callback: Self.eventTapCallback,
            userInfo: context
        ) else {
            self.onPress = nil
            self.onRelease = nil
            return false
        }

        eventTap = tap
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        if let runLoopSource {
            CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }
        CGEvent.tapEnable(tap: tap, enable: true)
        return true
    }

    func stop() {
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }
        if let eventTap {
            CGEvent.tapEnable(tap: eventTap, enable: false)
        }
        runLoopSource = nil
        eventTap = nil
        previousControlDown = false
        onPress = nil
        onRelease = nil
    }

    private func handle(type: CGEventType, event: CGEvent) {
        guard type == .flagsChanged else {
            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                stop()
            }
            return
        }
        guard UInt16(event.getIntegerValueField(.keyboardEventKeycode)) == keyCode else { return }

        let current = Self.isControlDown(flags: event.flags)
        guard Self.hasTransition(from: previousControlDown, to: current) else { return }
        previousControlDown = current
        if current {
            onPress?()
        } else {
            onRelease?()
        }
    }

    private static let eventTapCallback: CGEventTapCallBack = { _, type, event, refcon in
        guard let refcon else { return Unmanaged.passUnretained(event) }
        let monitor = Unmanaged<DictationHotkeyMonitor>.fromOpaque(refcon).takeUnretainedValue()
        Task { @MainActor [weak monitor] in
            monitor?.handle(type: type, event: event)
        }
        return Unmanaged.passUnretained(event)
    }
}
