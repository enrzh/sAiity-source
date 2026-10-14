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

/// The view inside the glass, and the reason the toast rests click-through.
///
/// `ignoresMouseEvents` is a whole-window property, so the toast cannot be
/// clickable over its result and transparent over the rest of its rectangle: it
/// is one or the other, everywhere. The same constraint `OverlayWindow` works
/// under. What makes a per-region answer possible is that an `NSTrackingArea`
/// keeps firing *while* the window is click-through, so hover is observed for
/// free and the flag is flipped to `false` only while the cursor is over
/// something that does something. All the view carries is the events; the
/// window owns which regions those are, because only it knows whether a result
/// is on screen.
private final class DictationToastContentView: NSView {
    /// The pointer moved to a point in this view's coordinates.
    var onHover: (@MainActor (NSPoint) -> Void)?
    /// The pointer left the bubble entirely.
    var onExit: (@MainActor () -> Void)?

    private var tracking: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        // `.activeAlways` is what makes this fire while the app is inactive —
        // and while the window itself is click-through. `.inVisibleRect` keeps
        // the rect right as the bubble changes height for a result.
        let area = NSTrackingArea(rect: bounds,
                                  options: [.mouseEnteredAndExited, .mouseMoved,
                                            .activeAlways, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) { hover(event) }
    override func mouseMoved(with event: NSEvent) { hover(event) }
    override func mouseExited(with event: NSEvent) {
        // AppKit delivers tracking events on the main thread, so this is a hop
        // back onto the actor the window lives on rather than a queued callback:
        // arming that lands a runloop turn late drops the click it was meant to
        // catch.
        MainActor.assumeIsolated { onExit?() }
    }

    private func hover(_ event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        MainActor.assumeIsolated { onHover?(point) }
    }
}

@MainActor
final class DictationToastWindow: NSPanel {
    private static let toastSize = NSSize(width: 224, height: 54)
    private static let horizontalInset: CGFloat = 26
    private static let minimumBubbleWidth: CGFloat = 180
    private static let maximumBubbleWidth: CGFloat = 560
    private static let resultMinimumHeight: CGFloat = 54
    private static let resultMaximumHeight: CGFloat = 420
    /// The strip along the top of the bubble you pick it up by. Same convention
    /// as the caption bubble: the status text below it stays click-through, so a
    /// toast parked over a button in the app being dictated into does not eat
    /// that button's clicks. Kept short deliberately — the compact pill is only
    /// 54 pt tall, and a generous grab band here would claim the label too.
    private static let dragStripHeight: CGFloat = 14
    /// Arm interactivity a few points before the cursor reaches a control: there
    /// is a measurable race between the mouse-moved event and the click that
    /// follows it, and arming late drops the first click of a gesture.
    private static let armSlack: CGFloat = 6
    /// The reset control's real hit target. Its icon is 16 pt, which is not a
    /// target, and it is the one control that has to work on the first click.
    private static let resetButtonTarget = NSSize(width: 28, height: 28)

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
    private let originalButton = NSButton()
    private let host = DictationToastContentView()
    private var autoDismissTask: Task<Void, Never>?
    private var isAutoDismissFading = false
    private var presentationGeneration = 0
    private var hasPlacedToast = false
    private var suppressFrameSave = false
    private var isShowingResult = false
    private var resultAllowsKeyboardFocus = false
    private var offersCopyRetry = false
    private var originalCopyFailed = false
    private var feedbackAccessibilityFocused = false
    private var labelPointSize: CGFloat?
    private var resultPointSize: CGFloat?
    private var dragStart: NSPoint?
    private var dragOrigin: NSPoint = .zero
    private var dragging = false
    /// True while AppKit owns the mouse gesture because a result's text area
    /// claimed the click. The window must not steal the drag and the up, or
    /// selecting text is a single click that selects nothing.
    private var textGestureInFlight = false
    /// Whether the panel is currently taking clicks, so arming only writes the
    /// flag on a change.
    private var mouseArmed = false
    private var feedbackHovered = false
    /// Backs up the hover tracking; see `startArmingTick`.
    private var armingTimer: Timer?
    var onResetPosition: (() -> Void)?
    var onRetryCopy: (() -> Void)?
    var onCopyOriginal: (() -> Bool)?
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
        // Resting state: click-through. The toast is on screen for the whole
        // dictation, and a panel that always takes clicks eats them from
        // whatever the user is dictating into. It arms itself over the strip you
        // drag it by, the reset control, and — while a result is on screen — the
        // text you can select. `OverlayWindow` solves the same whole-window
        // constraint the same way.
        ignoresMouseEvents = true
        acceptsMouseMovedEvents = true
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
        // A scroll view can only scroll a document taller than its clip view,
        // and a text view only grows to its text when the container height is
        // unbounded. Without this the "scrollable result" was one clipped line
        // tall whatever the text said, and the longer the dictation the more of
        // it was simply missing.
        resultTextView.textContainer?.containerSize = NSSize(width: 0,
                                                             height: CGFloat.greatestFiniteMagnitude)
        resultTextView.autoresizingMask = [.width]
        resultTextView.setAccessibilityRole(.staticText)
        resultTextView.setAccessibilityLabel(String(localized: "Dictation result"))
        resultScrollView.documentView = resultTextView
        resultScrollView.drawsBackground = false
        resultScrollView.borderType = .noBorder
        resultScrollView.hasHorizontalScroller = false
        resultScrollView.hasVerticalScroller = true
        resultScrollView.autohidesScrollers = true
        resultScrollView.scrollerStyle = .overlay
        resultScrollView.verticalScrollElasticity = .automatic
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

        originalButton.isBordered = false
        originalButton.isHidden = true
        originalButton.image = NSImage(systemSymbolName: "doc.text", accessibilityDescription: nil)
        originalButton.toolTip = String(localized: "Copy Original")
        originalButton.setAccessibilityLabel(String(localized: "Copy Original"))
        originalButton.target = self
        originalButton.action = #selector(copyOriginal)

        host.onHover = { [weak self] point in
            self?.updateMouseArming(atContentPoint: point)
        }
        host.onExit = { [weak self] in
            self?.feedbackHovered = false
            self?.armMouseEvents(false)
        }
        host.addSubview(spinner)
        host.addSubview(resetButton)
        host.addSubview(originalButton)
        host.addSubview(label)
        host.addSubview(waveform)
        host.addSubview(resultScrollView)
        spinner.translatesAutoresizingMaskIntoConstraints = false
        resetButton.translatesAutoresizingMaskIntoConstraints = false
        originalButton.translatesAutoresizingMaskIntoConstraints = false
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
            originalButton.leadingAnchor.constraint(equalTo: host.leadingAnchor, constant: 8),
            originalButton.centerYAnchor.constraint(equalTo: host.centerYAnchor),
            originalButton.widthAnchor.constraint(equalToConstant: 16),
            originalButton.heightAnchor.constraint(equalToConstant: 16),
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
        originalButton.contentTintColor = color
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
            // Remember position only. Reapplying a saved size undoes the
            // current preset and can resurrect a previous result's height.
            setFrameOrigin(frame.origin)
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
        if offersCopyRetry {
            guard let onRetryCopy else { return false }
            onRetryCopy()
            return true
        }
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

    func beginDrag(atScreenPoint point: NSPoint) {
        dragStart = point
        dragOrigin = frame.origin
        keepFeedbackVisibleIfInteracting()
    }
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
        if originalTargetArea?.contains(point) == true { copyOriginal(); return }
        // The same padded target the arming uses. Anything the panel claims a
        // click for has to do something with it, or the ring around the icon
        // would swallow clicks and start a drag instead.
        guard !resetTargetArea.contains(point) else { resetPositionFromButton(); return }
        dragging = true
        beginDrag(atScreenPoint: convertPoint(toScreen: event.locationInWindow))
    }
    override func mouseDragged(with event: NSEvent) {
        drag(toScreenPoint: convertPoint(toScreen: event.locationInWindow))
    }
    override func mouseUp(with event: NSEvent) { if dragging { endDrag() } }

    /// Routing for the left mouse button, which is the only thing the window
    /// claims for itself.
    ///
    /// Dragging and the reset control belong to the panel and are handled here.
    /// A click on a result's text area does not: selecting text is an AppKit
    /// gesture that needs the whole down/drag/up sequence delivered to the text
    /// view, and this override used to swallow all three and start a window drag
    /// instead — so the result was `isSelectable = true` in name only, with the
    /// only way to select it being to give up on dragging. Handing the sequence
    /// to AppKit is what makes the result text and its scroll view behave like
    /// text and a scroll view.
    override func sendEvent(_ event: NSEvent) {
        switch event.type {
        case .leftMouseDown:
            let claimed = claimsTextGesture(atWindowPoint: event.locationInWindow)
            textGestureInFlight = claimed
            keepFeedbackVisibleIfInteracting()
            guard claimed else { mouseDown(with: event); return }
            super.sendEvent(event)
        case .leftMouseDragged:
            guard !textGestureInFlight else { super.sendEvent(event); return }
            mouseDragged(with: event)
        case .leftMouseUp:
            defer { textGestureInFlight = false }
            guard !textGestureInFlight else { super.sendEvent(event); return }
            mouseUp(with: event)
        default:
            super.sendEvent(event)
        }
    }

    // MARK: - Where the panel takes clicks

    /// The bubble's own rectangle. `NSWindow` has no `bounds` in Swift — a
    /// window is a `frame` — and every region below is in content coordinates
    /// anyway, which for this borderless panel is the same rectangle.
    private var contentBounds: NSRect { contentView?.bounds ?? .zero }

    /// The strip along the top of the bubble, in content coordinates.
    private var dragRegion: NSRect {
        let bounds = contentBounds
        return NSRect(x: 0, y: bounds.height - Self.dragStripHeight,
                      width: bounds.width, height: Self.dragStripHeight)
    }

    /// The result's scroll area in content coordinates, or nil when no result is
    /// on screen.
    private var resultArea: NSRect? {
        guard isShowingResult, !resultScrollView.isHidden else { return nil }
        return resultScrollView.convert(resultScrollView.bounds, to: contentView)
    }

    private var resetControlArea: NSRect {
        resetButton.convert(resetButton.bounds, to: contentView)
    }

    private var originalTargetArea: NSRect? {
        originalButton.isHidden ? nil : originalButton.convert(originalButton.bounds, to: contentView).insetBy(dx: -6, dy: -6)
    }

    @objc func copyOriginal() {
        guard !originalButton.isHidden, let onCopyOriginal else { return }
        let copied = onCopyOriginal()
        originalCopyFailed = !copied
        keepFeedbackVisibleIfInteracting()
        let title = copied ? String(localized: "Original copied") : String(localized: "Copy failed — try again")
        originalButton.image = NSImage(systemSymbolName: copied ? "checkmark" : "exclamationmark.circle",
                                      accessibilityDescription: nil)
        originalButton.toolTip = title
        originalButton.setAccessibilityLabel(title + ". " + String(localized: "Copy Original"))
        Self.postAccessibility(originalButton, .announcementRequested)
    }

    /// The reset control's real hit target: a 16 pt icon is not a 16 pt target.
    private var resetTargetArea: NSRect {
        let dx = max(0, (Self.resetButtonTarget.width - resetControlArea.width) / 2)
        let dy = max(0, (Self.resetButtonTarget.height - resetControlArea.height) / 2)
        return resetControlArea.insetBy(dx: -dx, dy: -dy)
    }

    /// Whether a click at a point in the window belongs to the result's text area
    /// rather than to the panel. The whole routing in `sendEvent` hangs off this
    /// one answer, so it is named and visible rather than buried in the event
    /// handler.
    func claimsTextGesture(atWindowPoint windowPoint: NSPoint) -> Bool {
        guard let resultArea,
              let point = contentView?.convert(windowPoint, from: nil) else { return false }
        if originalTargetArea?.contains(point) == true { return false }
        return resultArea.contains(point)
    }

    /// The one arming decision, asked on hover, on presentation, and by tests.
    func updateMouseArming(atContentPoint point: NSPoint) {
        let inContent = armingPoint(forContentPoint: point)
        feedbackHovered = inContent.map { contentBounds.contains($0) } ?? false
        keepFeedbackVisibleIfInteracting()
        guard let inContent,
              isInteractive(inContent) else {
            armMouseEvents(false)
            return
        }
        armMouseEvents(true)
        // An open hand over the drag strip says "you can move this"; the arrow
        // everywhere else keeps the controls and the text honest.
        if resetTargetArea.contains(inContent) || originalTargetArea?.contains(inContent) == true || !dragRegion.contains(inContent) {
            NSCursor.arrow.set()
        } else {
            NSCursor.openHand.set()
        }
    }

    /// The same decision for a point in screen coordinates, for callers with no
    /// hover event — presentation, mainly. The panel can appear under a cursor
    /// that never moves, and a click-through panel that swallows nothing is
    /// right while one that swallows everything is the bug this exists to fix.
    func updateMouseArming(atScreenPoint point: NSPoint) {
        updateMouseArming(atContentPoint: host.convert(convertPoint(fromScreen: point), from: nil))
    }

    /// The same decision, without touching the cursor: for a caller that is not a
    /// hover, where forcing a cursor under a stationary pointer would be noise.
    private func arm(atContentPoint point: NSPoint) {
        let inContent = armingPoint(forContentPoint: point)
        feedbackHovered = inContent.map { contentBounds.contains($0) } ?? false
        keepFeedbackVisibleIfInteracting()
        guard let inContent else {
            armMouseEvents(false)
            return
        }
        armMouseEvents(isInteractive(inContent))
    }

    private func armingPoint(forContentPoint point: NSPoint) -> NSPoint? {
        guard contentBounds.height > 0 else { return nil }
        return contentView?.convert(point, from: host)
    }

    private func isInteractive(_ point: NSPoint) -> Bool {
        let slack = Self.armSlack
        return dragRegion.insetBy(dx: -slack, dy: -slack).contains(point)
            || resetTargetArea.insetBy(dx: -slack, dy: -slack).contains(point)
            || (originalTargetArea?.insetBy(dx: -slack, dy: -slack).contains(point) ?? false)
            || (resultArea?.insetBy(dx: -slack, dy: -slack).contains(point) ?? false)
    }

    /// Hover is the fast path; this is the guarantee behind it.
    ///
    /// A tracking area reporting into a window that is itself click-through is
    /// the one behaviour in here that no unit test can prove — the same thing
    /// `OverlayWindow` relies on, and if it ever stopped holding, the toast's
    /// controls would be unreachable rather than merely inconvenient. So the
    /// arming is re-decided from the pointer a few times a second while the panel
    /// is up. It costs a rectangle test, and it also covers a `mouseExited` that
    /// never arrives, which would otherwise leave the panel armed with the cursor
    /// somewhere else entirely.
    private func startArmingTick() {
        guard armingTimer == nil else { return }
        let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                guard self.isVisible else { self.armMouseEvents(false); return }
                self.arm(atContentPoint: self.host.convert(
                    self.convertPoint(fromScreen: NSEvent.mouseLocation), from: nil))
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        armingTimer = timer
    }

    private func armMouseEvents(_ interactive: Bool) {
        guard mouseArmed != interactive else { return }
        mouseArmed = interactive
        ignoresMouseEvents = !interactive
        keepFeedbackVisibleIfInteracting()
    }

    var isInteractingWithFeedback: Bool {
        guard isVisible else { return false }
        if feedbackHovered || mouseArmed || textGestureInFlight || dragging || dragStart != nil
            || offersCopyRetry || originalCopyFailed || feedbackAccessibilityFocused { return true }
        if isShowingResult, resultTextView.selectedRanges.contains(where: { $0.rangeValue.length > 0 }) {
            return true
        }
        if isKeyWindow, let focused = firstResponder as? NSView,
           focused.window === self, !focused.isHiddenOrHasHiddenAncestor { return true }
        let controls: [NSView] = [resultTextView, resetButton, originalButton]
        return controls.contains {
            !$0.isHiddenOrHasHiddenAncestor && $0.isAccessibilityFocused()
        }
    }

    override func makeFirstResponder(_ responder: NSResponder?) -> Bool {
        let accepted = super.makeFirstResponder(responder)
        keepFeedbackVisibleIfInteracting()
        return accepted
    }

    override func setAccessibilityFocused(_ flag: Bool) {
        super.setAccessibilityFocused(flag)
        feedbackAccessibilityFocused = flag
        keepFeedbackVisibleIfInteracting()
    }

    override var canBecomeKey: Bool { isShowingResult && resultAllowsKeyboardFocus }
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
    func performCopyOriginalButtonAction() { originalButton.performClick(nil) }
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
    var offersCopyRetryForTests: Bool { offersCopyRetry }
    var resultVisibleForTests: Bool { !resultScrollView.isHidden }
    var resultTextForTests: String { resultTextView.string }
    var resultFontSizeForTests: CGFloat { resultTextView.font?.pointSize ?? 0 }
    var resultScrollFrameForTests: NSRect { resultScrollView.convert(resultScrollView.bounds, to: contentView) }
    /// How tall the result text actually is, against the height it is shown in.
    /// Equal heights mean the "scrollable result" is a clipped one.
    var resultDocumentHeightForTests: CGFloat { resultTextView.frame.height }
    var resultClipHeightForTests: CGFloat { resultScrollView.contentView.bounds.height }
    var resultScrollableForTests: Bool {
        resultDocumentHeightForTests > resultClipHeightForTests + 0.5
    }
    var resultSelectableForTests: Bool { resultTextView.isSelectable }
    var resultTextViewForTests: NSTextView { resultTextView }
    var textGestureInFlightForTests: Bool {
        get { textGestureInFlight }
        set { textGestureInFlight = newValue }
    }
    var autoDismissActionForTests: () -> Void {
        let generation = presentationGeneration
        return { [weak self] in self?.finishAutoDismiss(generation: generation) }
    }
    var isAutoDismissFadingForTests: Bool { isAutoDismissFading }
    func stopArmingTickForTests() {
        armingTimer?.invalidate()
        armingTimer = nil
    }
    /// The result area in content coordinates, or nil when no result is shown.
    var resultAreaForTests: NSRect? { resultArea }
    var originalTargetAreaForTests: NSRect? { originalTargetArea }
    var resetTargetAreaForTests: NSRect { resetTargetArea }
    private(set) var resetCallbackCountForTests = 0
#endif

    func show(text: String, animated: Bool, autoDismissAfter: Duration? = nil) {
        cancelAutoDismiss()
        originalCopyFailed = false
        originalButton.isHidden = true
        configureCopyRetry(false)
        isShowingResult = false
        resultAllowsKeyboardFocus = false
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
    func show(resultText: String, autoDismissAfter: Duration? = .seconds(4.5), retryCopy: Bool = false,
              canCopyOriginal: Bool = false, allowsKeyboardFocus: Bool = true) {
        cancelAutoDismiss()
        originalCopyFailed = false
        originalButton.isHidden = !canCopyOriginal
        originalButton.image = NSImage(systemSymbolName: "doc.text", accessibilityDescription: nil)
        originalButton.toolTip = String(localized: "Copy Original")
        originalButton.setAccessibilityLabel(String(localized: "Copy Original"))
        configureCopyRetry(retryCopy)
        isShowingResult = true
        resultAllowsKeyboardFocus = allowsKeyboardFocus
        resultPointSize = nil
        label.isHidden = true
        waveform.stopAnimating()
        waveform.isHidden = true
        spinner.stopAnimation(nil)
        spinner.isHidden = true
        resultTextView.string = resultText
        resultTextView.setSelectedRange(NSRange(location: 0, length: 0))
        applyTextStyle()
        resultScrollView.isHidden = false
        setAccessibilityLabel(String(localized: "Dictation result"))
        setAccessibilityValue(resultText)
        setAccessibilityEnabled(true)
        applyAccessibilitySurface()
        present(size: resultSize(for: resultText), autoDismissAfter: autoDismissAfter)
        if retryCopy {
            setAccessibilityLabel(String(localized: "Copy failed — use Retry Copy in the bubble."))
            Self.postAccessibility(self, .announcementRequested)
        }
    }

    private func configureCopyRetry(_ enabled: Bool) {
        offersCopyRetry = enabled
        let title = enabled ? String(localized: "Retry Copy") : String(localized: "Reset Position")
        resetButton.image = NSImage(systemSymbolName: enabled ? "doc.on.clipboard" : "arrow.counterclockwise",
                                   accessibilityDescription: title)
        resetButton.toolTip = title
        resetButton.setAccessibilityLabel(title)
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
        if isShowingResult {
            // The document has to outgrow its clip view, or "long results scroll"
            // is a promise the layout never keeps and the tail of a long
            // dictation is simply not on screen. Measured here rather than in
            // `show(resultText:)` because the wrap width is only known once the
            // panel has been sized and laid out.
            resultTextView.sizeToFit()
            resultTextView.scrollToBeginningOfDocument(nil)
        }
        display()
        // A result changes which parts of the bubble are clickable, so the
        // arming is re-decided for wherever the pointer happens to be — a panel
        // that keeps the resting click-through state after growing a text area
        // would leave the result unselectable until the next hover.
        updateMouseArming(atScreenPoint: NSEvent.mouseLocation)
        startArmingTick()
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
        scheduleAutoDismiss(after: autoDismissAfter, generation: presentationGeneration)
    }

    private func scheduleAutoDismiss(after delay: Duration, generation: Int) {
        autoDismissTask?.cancel()
        autoDismissTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: delay)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            self?.finishAutoDismiss(generation: generation)
        }
    }

    private func finishAutoDismiss(generation: Int) {
        guard presentationGeneration == generation, isVisible else { return }
        if isInteractingWithFeedback {
            restoreFeedbackVisibility()
            scheduleAutoDismiss(after: .milliseconds(250), generation: generation)
            return
        }
        guard !isAutoDismissFading else { return }
        if Self.accessibilityPreferences().0 {
            dismiss()
            return
        }
        isAutoDismissFading = true
        NSAnimationContext.runAnimationGroup { [weak self] context in
            guard let self else { return }
            context.duration = 0.85
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            self.animator().alphaValue = 0
        }
        autoDismissTask?.cancel()
        autoDismissTask = Task { @MainActor [weak self] in
            let deadline = ContinuousClock.now + .milliseconds(850)
            repeat {
                do { try await Task.sleep(for: .milliseconds(50)) }
                catch { return }
                guard !Task.isCancelled, let self,
                      self.presentationGeneration == generation, self.isVisible else { return }
                if self.isInteractingWithFeedback {
                    self.restoreFeedbackVisibility()
                    self.scheduleAutoDismiss(after: .milliseconds(250), generation: generation)
                    return
                }
            } while ContinuousClock.now < deadline
            guard !Task.isCancelled, let self, self.presentationGeneration == generation else { return }
            self.finishAutoDismissFade(generation: generation)
        }
    }

    private func finishAutoDismissFade(generation: Int) {
        guard presentationGeneration == generation, isVisible else { return }
        if isInteractingWithFeedback {
            restoreFeedbackVisibility()
            scheduleAutoDismiss(after: .milliseconds(250), generation: generation)
        } else {
            dismiss()
        }
    }

    private func restoreFeedbackVisibility() {
        guard isAutoDismissFading else { return }
        isAutoDismissFading = false
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0
            self.animator().alphaValue = 1
        }
        alphaValue = 1
    }

    private func keepFeedbackVisibleIfInteracting() {
        guard isAutoDismissFading, isInteractingWithFeedback else { return }
        restoreFeedbackVisibility()
        scheduleAutoDismiss(after: .milliseconds(250), generation: presentationGeneration)
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
        resultAllowsKeyboardFocus = false
        originalButton.isHidden = true
        waveform.stopAnimating()
        spinner.stopAnimation(nil)
        alphaValue = 1
        // Back to resting. An ordered-out panel keeps whatever
        // `ignoresMouseEvents` it was dismissed with, and a hidden panel that is
        // still armed swallows the first click after it comes back. The tick goes
        // with it: it exists to answer for a visible panel.
        armMouseEvents(false)
        armingTimer?.invalidate()
        armingTimer = nil
        textGestureInFlight = false
        dragging = false
        dragStart = nil
        originalCopyFailed = false
        feedbackAccessibilityFocused = false
        feedbackHovered = false
        orderOut(nil)
    }

    private func cancelAutoDismiss() {
        presentationGeneration += 1
        autoDismissTask?.cancel()
        autoDismissTask = nil
        restoreFeedbackVisibility()
    }

    deinit {
        // The tick is only needed while the panel is on screen, and it holds a
        // closure that could otherwise outlive the window it is asking about.
        armingTimer?.invalidate()
    }
}
