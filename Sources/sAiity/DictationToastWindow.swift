import AppKit

private final class DictationWaveformView: NSView {
    private static let barCount = 28
    private var levels = Array(repeating: CGFloat(0.06), count: barCount)
    private var targetLevels = Array(repeating: CGFloat(0.06), count: barCount)
    private var animationTimer: Timer?
    private var barColor = NSColor.white

    override var isFlipped: Bool { true }

    func setLevels(_ values: [Float]) {
        guard !values.isEmpty else { return }
        let next = values.map { CGFloat(min(1, max(0.06, $0))) }
        if levels.count != next.count { levels = next }
        targetLevels = next
        startAnimating()
        needsDisplay = true
    }

    func reset() {
        stopAnimating()
        levels = Array(repeating: 0.06, count: Self.barCount)
        targetLevels = levels
        needsDisplay = true
    }

    func setColor(_ color: NSColor) {
        barColor = color
        needsDisplay = true
    }

    func stopAnimating() {
        animationTimer?.invalidate()
        animationTimer = nil
    }

    private func startAnimating() {
        guard animationTimer == nil else { return }
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            self?.advanceAnimation()
        }
        animationTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func advanceAnimation() {
        guard levels.count == targetLevels.count else {
            levels = targetLevels
            needsDisplay = true
            stopAnimating()
            return
        }

        var isMoving = false
        for index in levels.indices {
            let delta = targetLevels[index] - levels[index]
            if abs(delta) < 0.01 {
                levels[index] = targetLevels[index]
            } else {
                levels[index] += delta * 0.28
                isMoving = true
            }
        }
        needsDisplay = true
        if !isMoving { stopAnimating() }
    }

    deinit { animationTimer?.invalidate() }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let gap: CGFloat = 2
        let width = max(1, (bounds.width - gap * CGFloat(levels.count - 1))
            / CGFloat(levels.count))
        let mid = bounds.midY
        for (index, level) in levels.enumerated() {
            let height = max(3, bounds.height * 0.9 * level)
            let x = CGFloat(index) * (width + gap)
            let rect = NSRect(x: x, y: mid - height / 2, width: width, height: height)
            barColor.withAlphaComponent(0.9).setFill()
            NSBezierPath(roundedRect: rect, xRadius: width / 2, yRadius: width / 2).fill()
        }
    }
}

extension NSAccessibility.Role {
    static let status = Self(rawValue: "AXStatus")
}

@MainActor
final class DictationToastWindow: NSPanel {
    private static let toastSize = NSSize(width: 224, height: 54)
    private static let horizontalInset: CGFloat = 26
    private static let minimumBubbleWidth: CGFloat = 180
    private static let maximumBubbleWidth: CGFloat = 560
    private static let resultMinimumHeight: CGFloat = 54
    private static let resultMaximumHeight: CGFloat = 420
    static var postAccessibility: (Any, NSAccessibility.Notification) -> Void = NSAccessibility.post(element:notification:)
    static let systemAccessibilityPreferences: () -> (Bool, Bool, Bool) = {
        (NSWorkspace.shared.accessibilityDisplayShouldReduceMotion, NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency, NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast)
    }
    static var accessibilityPreferences = systemAccessibilityPreferences
#if SAIITY_TEST_HOOKS
    static var visibleFramesForTests: (() -> [NSRect])?
    static var activeFrameForTests: (() -> NSRect?)?
    static var saveDictationForTests: ((NSRect) -> Void)?
#endif
    private let label = NSTextField(labelWithString: "")
    private let waveform = DictationWaveformView()
    private let spinner = NSProgressIndicator()
    private let resultScrollView = NSScrollView()
    private let resultTextView = NSTextView(frame: .zero)
    private let resetButton = NSButton()
    private var autoDismissTask: Task<Void, Never>?
    private var presentationGeneration = 0
    private var hasPlacedToast = false
    private var suppressFrameSave = false
    private var isShowingResult = false
    private var labelPointSize: CGFloat?
    private var resultPointSize: CGFloat?
    private var dragStart: NSPoint?
    private var dragOrigin: NSPoint = .zero
    private var dragging = false
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

        label.font = .systemFont(ofSize: 13, weight: .semibold)
        label.textColor = .white
        label.alignment = .center
        label.lineBreakMode = .byTruncatingTail
        label.usesSingleLineMode = true
        label.setAccessibilityRole(.staticText)

        resultTextView.drawsBackground = false
        resultTextView.isEditable = false
        resultTextView.isSelectable = true
        resultTextView.isHorizontallyResizable = false
        resultTextView.isVerticallyResizable = true
        resultTextView.font = .systemFont(ofSize: 13, weight: .semibold)
        resultTextView.textColor = .white
        resultTextView.alignment = .center
        resultTextView.textContainerInset = NSSize(width: 4, height: 4)
        resultTextView.textContainer?.lineFragmentPadding = 0
        resultTextView.textContainer?.widthTracksTextView = true
        resultTextView.setAccessibilityRole(.staticText)
        resultTextView.setAccessibilityLabel(String(localized: "Dictation result"))
        resultScrollView.documentView = resultTextView
        resultScrollView.drawsBackground = false
        resultScrollView.borderType = .noBorder
        resultScrollView.hasHorizontalScroller = false
        resultScrollView.hasVerticalScroller = true
        resultScrollView.autohidesScrollers = true
        resultScrollView.scrollerStyle = .overlay
        resultScrollView.isHidden = true
        resultScrollView.setAccessibilityRole(.group)

        waveform.setAccessibilityRole(.image)
        waveform.setAccessibilityLabel(String(localized: "Audio waveform"))
        waveform.isHidden = true
        waveform.translatesAutoresizingMaskIntoConstraints = false

        spinner.style = .spinning
        spinner.controlSize = .small
        resetButton.image = NSImage(systemSymbolName: "arrow.counterclockwise", accessibilityDescription: "Reset Position")
        resetButton.isBordered = false
        resetButton.toolTip = "Reset Position"
        resetButton.setAccessibilityRole(.button)
        resetButton.setAccessibilityLabel("Reset Position")
        resetButton.target = self
        resetButton.action = #selector(resetPositionFromButton)

        let host = NSView()
        host.addSubview(spinner)
        host.addSubview(resetButton)
        host.addSubview(label)
        host.addSubview(waveform)
        host.addSubview(resultScrollView)
        spinner.translatesAutoresizingMaskIntoConstraints = false
        resetButton.translatesAutoresizingMaskIntoConstraints = false
        label.translatesAutoresizingMaskIntoConstraints = false
        resultScrollView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            spinner.leadingAnchor.constraint(equalTo: host.leadingAnchor, constant: 8),
            spinner.centerYAnchor.constraint(equalTo: host.centerYAnchor),
            spinner.widthAnchor.constraint(equalToConstant: 16),
            spinner.heightAnchor.constraint(equalToConstant: 16),
            resetButton.trailingAnchor.constraint(equalTo: host.trailingAnchor, constant: -8),
            resetButton.centerYAnchor.constraint(equalTo: host.centerYAnchor),
            resetButton.widthAnchor.constraint(equalToConstant: 16),
            resetButton.heightAnchor.constraint(equalToConstant: 16),
            label.centerXAnchor.constraint(equalTo: host.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: host.centerYAnchor),
            label.leadingAnchor.constraint(equalTo: host.leadingAnchor, constant: Self.horizontalInset),
            label.trailingAnchor.constraint(equalTo: host.trailingAnchor, constant: -Self.horizontalInset),
            // Keep the compact status baseline stable while the result text
            // itself can use the larger, scrollable layout.
            label.heightAnchor.constraint(equalToConstant: 20),
            waveform.centerXAnchor.constraint(equalTo: host.centerXAnchor),
            waveform.centerYAnchor.constraint(equalTo: host.centerYAnchor),
            waveform.leadingAnchor.constraint(equalTo: host.leadingAnchor, constant: Self.horizontalInset),
            waveform.trailingAnchor.constraint(equalTo: host.trailingAnchor, constant: -Self.horizontalInset),
            waveform.heightAnchor.constraint(equalToConstant: 34),
            resultScrollView.centerXAnchor.constraint(equalTo: host.centerXAnchor),
            resultScrollView.leadingAnchor.constraint(equalTo: host.leadingAnchor, constant: Self.horizontalInset),
            resultScrollView.trailingAnchor.constraint(equalTo: host.trailingAnchor, constant: -Self.horizontalInset),
            resultScrollView.topAnchor.constraint(equalTo: host.topAnchor, constant: 8),
            resultScrollView.bottomAnchor.constraint(equalTo: host.bottomAnchor, constant: -8),
        ])
        contentView = BubbleSurfaceView(contentView: host)
        applyAccessibilitySurface()
        applyBubbleStyle()
        applyTextStyle()
        NotificationCenter.default.addObserver(
            forName: .saiityDictationStyleChanged, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in self?.applyBubbleStyle() }
            }
        NotificationCenter.default.addObserver(
            forName: .saiityDictationPreview, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.show(resultText: CaptionStyle.longDictationPreview,
                               autoDismissAfter: .seconds(4.5))
                }
            }
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
            object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.applyAccessibilitySurface()
                    self?.applyBubbleStyle()
                }
            }
        if let saved = FrameStore.loadDictation(), let visible = injectedVisibleFrame(for: saved) {
            setFrame(FrameStore.clamp(saved, into: visible), display: false)
            hasPlacedToast = true
        }
    }

    private func applyAccessibilitySurface() {
        let (_, reduceTransparency, increaseContrast) = Self.accessibilityPreferences()
        if reduceTransparency {
            isOpaque = true
            backgroundColor = NSColor.windowBackgroundColor
        } else {
            isOpaque = false
            backgroundColor = .clear
        }
        if increaseContrast {
            hasShadow = true
            effectBorderColor = NSColor.labelColor
        } else {
            effectBorderColor = nil
        }
    }

    private func applyBubbleStyle() {
        guard let surface = contentView as? BubbleSurfaceView else { return }
        let (_, reduceTransparency, increaseContrast) = Self.accessibilityPreferences()
        surface.apply(style: CaptionStyle.currentDictation,
                      forceSolid: reduceTransparency || increaseContrast)
        applyTextStyle()
        resizeVisibleBubble()
    }

    private func applyTextStyle() {
        let text = CaptionStyle.currentDictation.original
        let color = text.color.withAlphaComponent(CGFloat(min(1, max(0.2, text.opacity))))
        let labelFont = text.stabilizedFont(for: label.stringValue,
                                            width: contentWidth(),
                                            minimumSize: 13,
                                            maxLines: 1,
                                            previousPointSize: labelPointSize)
        labelPointSize = labelFont.pointSize
        label.font = labelFont
        label.textColor = color
        let resultFont = text.stabilizedFont(for: resultTextView.string,
                                             width: contentWidth(),
                                             minimumSize: 13,
                                             maxLines: 5,
                                             previousPointSize: resultPointSize)
        resultPointSize = resultFont.pointSize
        resultTextView.font = resultFont
        resultTextView.textColor = color
        waveform.setColor(color)
    }

    private func bubbleWidth(for style: CaptionStyle = CaptionStyle.currentDictation) -> CGFloat {
        min(Self.maximumBubbleWidth, max(Self.minimumBubbleWidth, CGFloat(style.dictationWidth)))
    }

    private func contentWidth(for style: CaptionStyle = CaptionStyle.currentDictation) -> CGFloat {
        max(80, bubbleWidth(for: style) - Self.horizontalInset * 2)
    }

    private func statusSize(for style: CaptionStyle = CaptionStyle.currentDictation) -> NSSize {
        NSSize(width: bubbleWidth(for: style), height: Self.toastSize.height)
    }

    private func resizeVisibleBubble() {
        guard isVisible else { return }
        let oldFrame = frame
        let size = isShowingResult ? resultSize(for: resultTextView.string) : statusSize()
        guard oldFrame.size != size else { return }
        setContentSize(size)
        setFrameOrigin(NSPoint(x: oldFrame.midX - size.width / 2,
                               y: oldFrame.midY - size.height / 2))
        contentView?.layoutSubtreeIfNeeded()
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
        let frame = self.frame
        let wasShowingResult = isShowingResult
        let visibleFrame = placementVisibleFrame
        let needsPlacement = !hasPlacedToast &&
            (frame.width <= 1 || frame.height <= 1 ||
             (frame.height <= 16 && visibleFrame?.contains(frame) != true))
        show(text: p.value, animated: phase == .preparing || phase == .starting || phase == .dictating || phase == .transcribing || phase == .cleaning || phase == .translating || phase == .inserting, autoDismissAfter: autoDismissAfter)
        if phase == .dictating { showWaveform() }
        if needsPlacement && FrameStore.loadDictation() == nil,
           let v = visibleFrame {
            setFrameOrigin(NSPoint(x: v.midX - self.frame.width / 2, y: v.minY + 80))
        }
        hasPlacedToast = true
        if !needsPlacement || FrameStore.loadDictation() != nil {
            if wasShowingResult {
                // Result text may have made the panel taller. Keep its screen
                // position when returning to a compact status, but do not
                // restore the stale result height.
                setFrameOrigin(frame.origin)
            } else {
                setFrame(frame, display: false)
            }
        }
        setAccessibilityValue(p.value)
        setAccessibilityLabel(p.label)
        Self.postAccessibility(self, .announcementRequested)
    }

    private var placementVisibleFrame: NSRect? {
#if SAIITY_TEST_HOOKS
        if let frames = Self.visibleFramesForTests?(), let active = Self.activeFrameForTests?() {
            return frames.first(where: { $0.contains(NSPoint(x: active.midX, y: active.midY)) }) ?? frames.first
        }
#endif
        let screen = NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) }) ?? NSScreen.main
        return screen?.visibleFrame
    }

    private func injectedVisibleFrame(for frame: NSRect) -> NSRect? {
#if SAIITY_TEST_HOOKS
        if let frames = Self.visibleFramesForTests?() {
            let center = NSPoint(x: frame.midX, y: frame.midY)
            return frames.first(where: { $0.contains(center) }) ?? frames.first
        }
#endif
        return FrameStore.bestScreen(for: frame)?.visibleFrame
    }

    func performResetPosition() -> Bool {
        guard let onResetPosition else { return false }
        onResetPosition()
        return true
    }

    func saveDraggedFrame() {
#if SAIITY_TEST_HOOKS
        Self.saveDictationForTests?(frame)
#endif
        FrameStore.saveDictation(frame)
    }

    func beginDrag(atScreenPoint point: NSPoint) { dragStart = point; dragOrigin = frame.origin }
    func drag(toScreenPoint point: NSPoint) {
        guard let dragStart else { return }
        setFrameOrigin(NSPoint(x: dragOrigin.x + point.x - dragStart.x, y: dragOrigin.y + point.y - dragStart.y))
    }
    func endDrag() {
        guard dragStart != nil else { return }
        dragStart = nil
        let screen = FrameStore.bestScreen(for: frame) ?? NSScreen.main
        if let screen { setFrame(FrameStore.clamp(frame, into: screen.visibleFrame), display: false) }
        saveDraggedFrame()
        dragging = false
    }
    override func mouseDown(with event: NSEvent) {
        let point = contentView?.convert(event.locationInWindow, from: nil) ?? .zero
        let resetFrame = resetButton.convert(resetButton.bounds, to: contentView)
        guard !resetFrame.contains(point) else { resetPositionFromButton(); return }
        dragging = true
        beginDrag(atScreenPoint: convertPoint(toScreen: event.locationInWindow))
    }
    override func mouseDragged(with event: NSEvent) {
        drag(toScreenPoint: convertPoint(toScreen: event.locationInWindow))
    }
    override func mouseUp(with event: NSEvent) { if dragging { endDrag() } }

    override func sendEvent(_ event: NSEvent) {
        switch event.type {
        case .leftMouseDown: mouseDown(with: event)
        case .leftMouseDragged: mouseDragged(with: event)
        case .leftMouseUp: mouseUp(with: event)
        default: super.sendEvent(event)
        }
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

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

    @objc private func resetPositionFromButton() {
#if SAIITY_TEST_HOOKS
        resetCallbackCountForTests += 1
#endif
        _ = performResetPosition()
    }
    func performResetButtonAction() { resetButton.performClick(nil) }
#if SAIITY_TEST_HOOKS
    var renderedBubbleStyleForTests: Int { (contentView as? BubbleSurfaceView)?.renderedStyle ?? -1 }
    var usesLiquidGlassForTests: Bool { (contentView as? BubbleSurfaceView)?.usesLiquidGlassForTests ?? false }
    var bubbleContentAttachedForTests: Bool { (contentView as? BubbleSurfaceView)?.contentAttachedForTests ?? false }
    var resetButtonBoundsForTests: NSRect { resetButton.convert(resetButton.bounds, to: nil) }
    var labelMidXForTests: CGFloat { label.convert(label.bounds, to: contentView).midX }
    var labelFrameForTests: NSRect { label.convert(label.bounds, to: contentView) }
    var contentFrameForTests: NSRect { contentView?.bounds ?? .zero }
    var contentMidXForTests: CGFloat { contentView?.bounds.midX ?? 0 }
    var waveformFrameForTests: NSRect { waveform.convert(waveform.bounds, to: contentView) }
    var waveformVisibleForTests: Bool { !waveform.isHidden }
    var labelVisibleForTests: Bool { !label.isHidden }
    var resetButtonVisibleForTests: Bool { !resetButton.isHidden }
    var resultVisibleForTests: Bool { !resultScrollView.isHidden }
    var resultTextForTests: String { resultTextView.string }
    var resultFontSizeForTests: CGFloat { resultTextView.font?.pointSize ?? 0 }
    var resultScrollFrameForTests: NSRect { resultScrollView.convert(resultScrollView.bounds, to: contentView) }
    private(set) var resetCallbackCountForTests = 0
#endif

    func show(text: String, animated: Bool, autoDismissAfter: Duration? = nil) {
        cancelAutoDismiss()
        isShowingResult = false
        labelPointSize = nil
        label.isHidden = false
        resultScrollView.isHidden = true
        waveform.stopAnimating()
        waveform.isHidden = true
        label.stringValue = text
        applyTextStyle()
        setAccessibilityLabel(String(localized: "Dictation"))
        setAccessibilityValue(text)
        setAccessibilityEnabled(true)
        applyAccessibilitySurface()
        spinner.isHidden = !animated
        animated ? spinner.startAnimation(nil) : spinner.stopAnimation(nil)
        present(size: statusSize(), autoDismissAfter: autoDismissAfter)
    }

    /// Displays the completed dictation, after insertion/clipboard handling has
    /// finished. Long results stay inside the bubble and scroll vertically.
    func show(resultText: String, autoDismissAfter: Duration? = .seconds(4.5)) {
        cancelAutoDismiss()
        isShowingResult = true
        resultPointSize = nil
        label.isHidden = true
        waveform.stopAnimating()
        waveform.isHidden = true
        spinner.stopAnimation(nil)
        spinner.isHidden = true
        resultTextView.string = resultText
        resultTextView.scrollToBeginningOfDocument(nil)
        applyTextStyle()
        resultScrollView.isHidden = false
        setAccessibilityLabel(String(localized: "Dictation result"))
        setAccessibilityValue(resultText)
        setAccessibilityEnabled(true)
        applyAccessibilitySurface()
        present(size: resultSize(for: resultText), autoDismissAfter: autoDismissAfter)
    }

    private func resultSize(for text: String) -> NSSize {
        let font = resultTextView.font ?? .systemFont(ofSize: 13, weight: .medium)
        let style = CaptionStyle.currentDictation
        let measured = (text as NSString).boundingRect(
            with: NSSize(width: contentWidth(for: style), height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: font])
        let configuredMaximum = CGFloat(style.maxHeight)
        let maximum = min(Self.resultMaximumHeight,
                          max(Self.resultMinimumHeight, configuredMaximum))
        let height = min(maximum, max(Self.resultMinimumHeight, ceil(measured.height) + 24))
        return NSSize(width: bubbleWidth(for: style), height: height)
    }

    private func present(size: NSSize, autoDismissAfter: Duration?) {
        alphaValue = 1
        // Status and recording states keep one stable footprint. Completed
        // text may grow vertically, but its width stays fixed and its height
        // is bounded before AppKit lays out the panel.
        setContentSize(size)
        // Resolve the fixed hierarchy before display. This avoids a one-frame
        // stale layout on macOS 27 and keeps production geometry deterministic.
        contentView?.layoutSubtreeIfNeeded()
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

            if Self.accessibilityPreferences().0 {
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
            // A borderless nonactivating panel can skip the AppKit animation
            // completion callback when the window server is settling or a
            // test host has no active app. Keep the dismissal deterministic.
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(0.9))
                guard let self, self.presentationGeneration == generation else { return }
                self.orderOut(nil)
                self.alphaValue = 1
                self.autoDismissTask = nil
            }
        }
    }

    func updateWaveform(_ values: [Float]) {
        waveform.setLevels(values)
    }

    private func showWaveform() {
        waveform.reset()
        label.isHidden = true
        waveform.isHidden = false
    }

    private func orderFrontForPresentation() {
#if SAIITY_TEST_HOOKS
        orderFrontCallsForTests += 1
#endif
        orderFrontRegardless()
    }

    func dismiss() {
        cancelAutoDismiss()
        waveform.stopAnimating()
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
