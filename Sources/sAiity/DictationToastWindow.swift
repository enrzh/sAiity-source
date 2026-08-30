import AppKit

extension NSAccessibility.Role {
    static let status = Self(rawValue: "AXStatus")
}

@MainActor
final class DictationToastWindow: NSPanel {
    static var postAccessibility: (Any, NSAccessibility.Notification) -> Void = NSAccessibility.post(element:notification:)
    private let label = NSTextField(labelWithString: "")
    private let spinner = NSProgressIndicator()
    private let resetButton = NSButton()
    private var autoDismissTask: Task<Void, Never>?
    private var presentationGeneration = 0
    private var hasPlacedToast = false
    private var suppressFrameSave = false
    var onResetPosition: (() -> Void)?
#if SAIITY_TEST_HOOKS
    private(set) var orderFrontCallsForTests = 0
#endif

    override init(contentRect: NSRect, styleMask: NSWindow.StyleMask, backing: NSWindow.BackingStoreType, defer flag: Bool) {
        super.init(contentRect: contentRect, styleMask: styleMask, backing: backing, defer: flag)
        self.styleMask.insert(.nonactivatingPanel)
        isFloatingPanel = true
        becomesKeyOnlyIfNeeded = true
        level = .screenSaver
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        ignoresMouseEvents = false
        hidesOnDeactivate = false
        isMovable = true
        setAccessibilityRole(.status)
        setAccessibilityLabel("Dictation")
        setAccessibilityEnabled(true)

        let effect = NSGlassEffectView()
        effect.style = .regular
        effect.cornerRadius = 22

        label.font = .systemFont(ofSize: 13, weight: .medium)
        label.textColor = .white
        label.alignment = .center
        label.lineBreakMode = .byTruncatingTail

        spinner.style = .spinning
        spinner.controlSize = .small
        resetButton.image = NSImage(systemSymbolName: "arrow.counterclockwise", accessibilityDescription: "Reset Position")
        resetButton.isBordered = false
        resetButton.toolTip = "Reset Position"
        resetButton.setAccessibilityRole(.button)
        resetButton.setAccessibilityLabel("Reset Position")
        resetButton.target = self
        resetButton.action = #selector(resetPositionFromButton)

        let stack = NSStackView(views: [spinner, label, resetButton])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 9, left: 14, bottom: 9, right: 14)
        let host = NSView()
        host.addSubview(stack)
        stack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: host.trailingAnchor),
            stack.topAnchor.constraint(equalTo: host.topAnchor),
            stack.bottomAnchor.constraint(equalTo: host.bottomAnchor),
            label.widthAnchor.constraint(greaterThanOrEqualToConstant: 86),
        ])
        effect.contentView = host
        contentView = effect
        applyAccessibilitySurface()
        if let saved = FrameStore.loadDictation(), let screen = FrameStore.bestScreen(for: saved) {
            setFrame(FrameStore.clamp(saved, into: screen.visibleFrame), display: false)
            hasPlacedToast = true
        }
        NotificationCenter.default.addObserver(forName: NSWindow.didMoveNotification,
                                               object: self, queue: .main) { [weak self] _ in
            if self?.suppressFrameSave == false { self?.saveDraggedFrame() }
        }
    }

    private func applyAccessibilitySurface() {
        if NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency {
            isOpaque = true
            backgroundColor = NSColor.windowBackgroundColor
        } else {
            isOpaque = false
            backgroundColor = .clear
        }
        if NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast {
            hasShadow = true
            effectBorderColor = NSColor.labelColor
        } else {
            effectBorderColor = nil
        }
    }

    private var effectBorderColor: NSColor? {
        get { contentView?.layer?.borderColor.flatMap(NSColor.init(cgColor:)) }
        set {
            contentView?.wantsLayer = true
            contentView?.layer?.borderWidth = newValue == nil ? 0 : 1
            contentView?.layer?.borderColor = newValue?.cgColor
        }
    }

    func show(phase: DictationPhase) {
        show(phase: phase, autoDismissAfter: nil)
    }

    func show(phase: DictationPhase, autoDismissAfter: Duration?) {
        let p = phase.toastPresentation
        let needsPlacement = !hasPlacedToast
        let frame = self.frame
        show(text: p.value, animated: phase == .preparing || phase == .starting || phase == .dictating || phase == .transcribing || phase == .cleaning || phase == .translating || phase == .inserting, autoDismissAfter: autoDismissAfter)
        if needsPlacement && FrameStore.loadDictation() == nil,
           let screen = NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) }) ?? NSScreen.main {
            let v = screen.visibleFrame
            setFrameOrigin(NSPoint(x: v.midX - self.frame.width / 2, y: v.minY + 80))
        }
        hasPlacedToast = true
        if !needsPlacement || FrameStore.loadDictation() != nil {
            setFrame(frame, display: false)
        }
        setAccessibilityValue(p.value)
        Self.postAccessibility(self, .announcementRequested)
    }

    func performResetPosition() -> Bool {
        guard let onResetPosition else { return false }
        onResetPosition()
        return true
    }

    func saveDraggedFrame() { FrameStore.saveDictation(frame) }

    func resetPosition() {
        FrameStore.resetDictation()
        let screen = FrameStore.bestScreen(for: frame) ?? NSScreen.main
        guard let screen else { return }
        let v = screen.visibleFrame
        let f = NSRect(x: v.midX - frame.width / 2, y: v.minY + 80,
                       width: max(frame.width, 150), height: max(frame.height, 36))
        suppressFrameSave = true
        setFrame(FrameStore.clamp(f, into: v), display: false)
        suppressFrameSave = false
    }

    @objc private func resetPositionFromButton() { resetPosition() }

    func show(text: String, animated: Bool, autoDismissAfter: Duration? = nil) {
        cancelAutoDismiss()
        label.stringValue = text
        setAccessibilityValue(text)
        setAccessibilityEnabled(true)
        applyAccessibilitySurface()
        spinner.isHidden = !animated
        animated ? spinner.startAnimation(nil) : spinner.stopAnimation(nil)
        alphaValue = 1
        let size = contentView?.fittingSize ?? NSSize(width: 150, height: 34)
        setContentSize(NSSize(width: max(150, size.width), height: 36))
        contentView?.layoutSubtreeIfNeeded()
        contentView?.displayIfNeeded()
        display()
        // `isVisible` can remain true after AppKit has accepted an order request
        // that the window server dropped during launch. Always re-order the panel
        // when its content changes so the ready state is visible over the current
        // frontmost app as well as the later dictating states.
        orderFrontForPresentation()
        // During application launch AppKit can report the panel visible before
        // the window server has placed it on screen. Re-order once after the
        // caller has positioned the panel so the first ready toast is visible.
        Task { @MainActor [weak self] in
            await Task.yield()
            guard let self, self.isVisible else { return }
            self.contentView?.layoutSubtreeIfNeeded()
            self.contentView?.displayIfNeeded()
            self.display()
            self.orderFrontRegardless()
        }

        guard let autoDismissAfter else { return }
        let generation = presentationGeneration
        autoDismissTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: autoDismissAfter)
            } catch {
                return
            }
            guard let self,
                  self.presentationGeneration == generation,
                  self.isVisible else { return }

            if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
                self.dismiss()
                return
            }
            NSAnimationContext.runAnimationGroup { [weak self] context in
                guard let self else { return }
                context.duration = 0.85
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                self.animator().alphaValue = 0
            } completionHandler: { [weak self] in
                Task { @MainActor [weak self] in
                    guard let self, self.presentationGeneration == generation else { return }
                    self.orderOut(nil)
                    self.alphaValue = 1
                    self.autoDismissTask = nil
                }
            }
        }
    }

    private func orderFrontForPresentation() {
#if SAIITY_TEST_HOOKS
        orderFrontCallsForTests += 1
#endif
        orderFrontRegardless()
    }

    func dismiss() {
        cancelAutoDismiss()
        spinner.stopAnimation(nil)
        alphaValue = 1
        orderOut(nil)
    }

    private func cancelAutoDismiss() {
        presentationGeneration += 1
        autoDismissTask?.cancel()
        autoDismissTask = nil
    }
}
