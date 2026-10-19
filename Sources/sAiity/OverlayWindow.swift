import AppKit

/// Where the caption bubble lives, remembered across launches.
enum FrameStore {
    private static let key = "captionFrame"

    static func save(_ f: NSRect) {
        UserDefaults.standard.set(NSStringFromRect(f), forKey: key)
    }

    static func load() -> NSRect? {
        guard let s = UserDefaults.standard.string(forKey: key) else { return nil }
        let r = NSRectFromString(s)
        return (r.width > 1 && r.height > 1) ? r : nil
    }

    /// A width the user chose by dragging an edge, stored separately from the
    /// frame.
    ///
    /// The frame is saved after any settle, including ones the app caused, so
    /// deriving "the user picked this width" from it was wrong — and it switched
    /// off the automatic width and the screen margin for everyone from their
    /// second launch onwards.
    private static let widthKey = "captionUserWidth"

    static func saveUserWidth(_ w: CGFloat) {
        UserDefaults.standard.set(Double(w), forKey: widthKey)
    }

    static func loadUserWidth() -> CGFloat? {
        let v = UserDefaults.standard.double(forKey: widthKey)
        return v > 1 ? CGFloat(v) : nil
    }

    static func clearUserWidth() {
        UserDefaults.standard.removeObject(forKey: widthKey)
    }

    static func reset() {
        UserDefaults.standard.removeObject(forKey: key)
        clearUserWidth()
    }

    private static let dictationKey = "dictationToastFrame"
    static func saveDictation(_ f: NSRect) { UserDefaults.standard.set(NSStringFromRect(f), forKey: dictationKey) }
    static func loadDictation() -> NSRect? {
        guard let s = UserDefaults.standard.string(forKey: dictationKey) else { return nil }
        let r = NSRectFromString(s)
        return r.width > 1 && r.height > 1 ? r : nil
    }
    static func resetDictation() { UserDefaults.standard.removeObject(forKey: dictationKey) }

    /// Pull a saved frame back onto a screen that still exists. Shrink before
    /// moving, so a frame saved on a big display cannot end up wider than the
    /// laptop panel you just undocked to.
    static func clamp(_ saved: NSRect, into visible: NSRect) -> NSRect {
        var f = saved
        f.size.width = min(f.width, visible.width)
        f.size.height = min(f.height, visible.height)
        f.origin.x = min(max(f.minX, visible.minX), visible.maxX - f.width)
        f.origin.y = min(max(f.minY, visible.minY), visible.maxY - f.height)
        return f
    }

    /// The screen the bubble is on, decided by its CENTRE rather than by which
    /// display it overlaps most.
    ///
    /// Overlap area is not stable under resize: a bubble straddling two displays
    /// can flip to the other one purely by growing a line taller, and since the
    /// bubble's width is derived from the screen, it would then jump width for
    /// no reason the user can see. Observed exactly that — the width changed on
    /// the tallest caption of a session. A centre point cannot flip unless the
    /// bubble is actually moved.
    static func bestScreen(for frame: NSRect) -> NSScreen? {
        let c = NSPoint(x: frame.midX, y: frame.midY)
        if let hit = NSScreen.screens.first(where: { NSPointInRect(c, $0.frame) }) { return hit }
        // Centre is off every display (a monitor was unplugged): fall back to
        // whichever still overlaps, then to the primary.
        var best: NSScreen?
        var bestArea: CGFloat = 0
        for s in NSScreen.screens {
            let a = s.visibleFrame.intersection(frame)
            let area = a.isNull ? 0 : a.width * a.height
            if area > bestArea { bestArea = area; best = s }
        }
        return best ?? NSScreen.main
    }
}

/// An image view that is a real button to assistive tech, not just one that
/// claims the role. VoiceOver announced "button" (the role was set) but
/// VO-Space did nothing: NSImageView has no AXPress action, and every actual
/// activation ran through mouseDown hit-testing on a window that rests
/// click-through — a path a screen reader can never drive.
final class AccessibleIconButton: NSImageView {
    var onPress: (() -> Void)?
    /// Fired when the VoiceOver cursor lands here, so the bubble can reveal
    /// controls that otherwise rest at alpha 0 until a literal mouse hover.
    var onAccessibilityFocus: (() -> Void)?

    /// The hand-rolled ring. AppKit draws its own for a normal window; a
    /// `.nonactivatingPanel` gets nothing.
    private var keyboardFocusRing: CAShapeLayer?

    override func accessibilityPerformPress() -> Bool {
        guard let onPress else { return false }
        onPress()
        return true
    }

    override func setAccessibilityFocused(_ flag: Bool) {
        super.setAccessibilityFocused(flag)
        if flag { onAccessibilityFocus?() }
    }

    // The bubble window is a `.nonactivatingPanel`, so Full Keyboard Access
    // never draws a focus ring inside it. Without an explicit ring the controls
    // are reachable and completely invisible while focused — the same "looks
    // inert" state ShortcutRecorder had to fix for itself. Drawn on
    // `viewDidMoveToWindow` and on focus, because AppKit's own ring machinery
    // never runs for a non-activating panel.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateKeyboardFocusRing()
    }

    // `becomeFirstResponder`, not `focus(withSender:)`: AppKit removed the
    // latter from NSView, and this is the call a non-activating panel's full
    // keyboard access actually makes.
    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        updateKeyboardFocusRing()
        return accepted
    }

    private var keyboardFocused: Bool { window?.firstResponder === self }

    private func updateKeyboardFocusRing() {
        guard keyboardFocused else {
            keyboardFocusRing?.removeFromSuperlayer()
            keyboardFocusRing = nil
            return
        }
        if keyboardFocusRing != nil { return }
        let ring = NSBezierPath(roundedRect: bounds.insetBy(dx: -3, dy: -3),
                                 xRadius: 7, yRadius: 7)
        let shape = CAShapeLayer()
        shape.path = ring.cgPath
        shape.fillColor = NSColor.clear.cgColor
        shape.strokeColor = NSColor.keyboardFocusIndicatorColor.cgColor
        shape.lineWidth = 3
        shape.frame = bounds
        wantsLayer = true
        layer?.addSublayer(shape)
        keyboardFocusRing = shape
        setAccessibilityFocused(true)
    }
}

/// The view inside the glass. Owns hover tracking, the control strip, and
/// dragging.
///
/// The central constraint: `ignoresMouseEvents` is a whole-window property —
/// a window cannot be click-through in one region and interactive in another.
/// But an `NSTrackingArea` keeps firing *even while the window is
/// click-through* (with `.activeAlways`), so hover can be tracked for free and
/// the flag flipped to `false` only while the cursor is over the control strip.
/// The caption text itself therefore never eats a click meant for the video
/// underneath.
final class BubbleContentView: NSView {
    var onCopy: (() -> Void)?
    var onSaveTranscript: (() -> Void)?
    var onClear: (() -> Void)?
    var onJumpToLatest: (() -> Void)?
    var showsJumpToLatest = false {
        didSet { jumpButton.isHidden = !showsJumpToLatest }
    }

    private let controlStripHeight: CGFloat = 38
    /// Matches OverlayWindow's cornerRadius. Content inset by the radius lines up
    /// with the point where the rounded edge becomes straight; anything less
    /// tucks the icon into the curve, which is what looked wrong.
    static let cornerRadius: CGFloat = 22
    /// Arm interactivity slightly before the cursor reaches the visible control:
    /// there is a measurable few-ms race between the toggle and the click.
    private let armSlack: CGFloat = 12

    /// When true, only the top strip is interactive and clicks on the caption
    /// text pass through to whatever is underneath. When false (the default),
    /// the whole bubble can be grabbed and dragged — you cannot have both, since
    /// a surface that receives a drag necessarily consumes the click.
    var clickThroughText: Bool { UserDefaults.standard.bool(forKey: "captionClickThrough") }

    private var tracking: NSTrackingArea?
    private let copyButton = AccessibleIconButton()
    private let saveButton = AccessibleIconButton()
    private let clearButton = AccessibleIconButton()
    private let jumpButton = AccessibleIconButton()
    private let transcriptStatus = NSButton(title: "", target: nil, action: nil)
    private var openTranscript: (() -> Void)?
    private let recordDot = NSView()
    private var copyFlashWork: DispatchWorkItem?

    var isRecording = false {
        didSet { recordDot.isHidden = !isRecording }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        setupControls()
    }
    required init?(coder: NSCoder) { fatalError() }

    private func setupControls() {
        let cfg = NSImage.SymbolConfiguration(pointSize: 13, weight: .semibold)
        copyButton.image = NSImage(systemSymbolName: "doc.on.doc",
                                   accessibilityDescription: nil)?
            .withSymbolConfiguration(cfg)
        copyButton.contentTintColor = NSColor.white.withAlphaComponent(0.75)
        copyButton.alphaValue = 0
        copyButton.toolTip = String(localized: "Copy this line")

        saveButton.image = NSImage(systemSymbolName: "square.and.arrow.down",
                                   accessibilityDescription: nil)?
            .withSymbolConfiguration(cfg)
        saveButton.contentTintColor = NSColor.white.withAlphaComponent(0.75)
        saveButton.alphaValue = 0
        saveButton.toolTip = String(localized: "Save transcript")
        saveButton.setAccessibilityHelp(String(localized: "Bubble history shows the latest 50 lines. Saving includes all committed lines."))

        transcriptStatus.isBordered = false
        transcriptStatus.font = .systemFont(ofSize: 13)
        transcriptStatus.contentTintColor = .white
        transcriptStatus.isHidden = true
        transcriptStatus.target = self
        transcriptStatus.action = #selector(openSavedTranscript)
        transcriptStatus.cell?.lineBreakMode = .byTruncatingTail
        transcriptStatus.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        // Wipe what is on screen without stopping recognition — for the moment
        // a caption is still sitting over something you want to see, or a line
        // you would rather not leave on a shared screen.
        clearButton.image = NSImage(systemSymbolName: "xmark.circle",
                                    accessibilityDescription: nil)?
            .withSymbolConfiguration(cfg)
        clearButton.contentTintColor = NSColor.white.withAlphaComponent(0.75)
        clearButton.alphaValue = 0
        clearButton.toolTip = String(localized: "Clear the caption")

        jumpButton.image = NSImage(systemSymbolName: "arrow.down.to.line", accessibilityDescription: nil)?
            .withSymbolConfiguration(cfg)
        jumpButton.contentTintColor = .white
        jumpButton.isHidden = true
        jumpButton.toolTip = String(localized: "Jump to latest")
        jumpButton.setAccessibilityRole(.button)
        jumpButton.setAccessibilityLabel(String(localized: "Jump to latest"))
        jumpButton.onPress = { [weak self] in self?.onJumpToLatest?() }

        // Recording writes a durable, permanent record — it gets a marker on the
        // one element guaranteed to be on screen.
        recordDot.wantsLayer = true
        recordDot.layer?.backgroundColor = NSColor.systemRed.cgColor
        recordDot.layer?.cornerRadius = 4
        recordDot.isHidden = true

        // The bubble was a VoiceOver dead zone: image views and a bare NSView,
        // no roles, no labels — a subtitle app whose own subtitles and controls
        // a screen reader could not see.
        copyButton.setAccessibilityRole(.button)
        copyButton.setAccessibilityLabel(String(localized: "Copy this caption"))
        saveButton.setAccessibilityRole(.button)
        saveButton.setAccessibilityLabel(String(localized: "Save transcript"))
        clearButton.setAccessibilityRole(.button)
        clearButton.setAccessibilityLabel(String(localized: "Clear the caption"))
        recordDot.setAccessibilityRole(.image)
        recordDot.setAccessibilityLabel(String(localized: "Recording a transcript"))

        // The AX press and the mouse click share the same handlers, so the
        // two input paths cannot drift apart.
        copyButton.onPress = { [weak self] in
            self?.onCopy?()
            self?.flashCopied()
        }
        saveButton.onPress = { [weak self] in self?.onSaveTranscript?() }
        clearButton.onPress = { [weak self] in self?.onClear?() }
        for b in [copyButton, saveButton, clearButton] {
            b.onAccessibilityFocus = { [weak self] in self?.setControls(visible: true) }
        }

        for v in [copyButton, saveButton, clearButton, jumpButton, recordDot, transcriptStatus] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        // Two clusters, hard in the corners: status on the left, action on the
        // right. Anything drifting toward the middle competes with the caption.
        // Inset by the corner radius horizontally, and centre vertically in the
        // control strip, so both icons sit on the same optical line as the
        // straight part of the edge rather than crowding the curve.
        let inset = Self.cornerRadius
        NSLayoutConstraint.activate([
            recordDot.widthAnchor.constraint(equalToConstant: 8),
            recordDot.heightAnchor.constraint(equalToConstant: 8),
            recordDot.leadingAnchor.constraint(equalTo: leadingAnchor, constant: inset + 2),
            recordDot.centerYAnchor.constraint(equalTo: topAnchor, constant: controlStripHeight / 2),

            saveButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -inset),
            saveButton.centerYAnchor.constraint(equalTo: recordDot.centerYAnchor),
            saveButton.widthAnchor.constraint(equalToConstant: 16),
            saveButton.heightAnchor.constraint(equalToConstant: 16),

            copyButton.trailingAnchor.constraint(equalTo: saveButton.leadingAnchor,
                                                  constant: -10),
            copyButton.centerYAnchor.constraint(equalTo: recordDot.centerYAnchor),
            copyButton.widthAnchor.constraint(equalToConstant: 16),
            copyButton.heightAnchor.constraint(equalToConstant: 16),

            // Immediately left of Copy, in the same right-hand action cluster.
            clearButton.trailingAnchor.constraint(equalTo: copyButton.leadingAnchor,
                                                  constant: -10),
            clearButton.centerYAnchor.constraint(equalTo: recordDot.centerYAnchor),
            clearButton.widthAnchor.constraint(equalToConstant: 16),
            clearButton.heightAnchor.constraint(equalToConstant: 16),
            jumpButton.trailingAnchor.constraint(equalTo: clearButton.leadingAnchor, constant: -12),
            jumpButton.centerYAnchor.constraint(equalTo: recordDot.centerYAnchor),
            jumpButton.widthAnchor.constraint(equalToConstant: 20),
            jumpButton.heightAnchor.constraint(equalToConstant: 20),
            transcriptStatus.leadingAnchor.constraint(greaterThanOrEqualTo: recordDot.trailingAnchor, constant: 12),
            transcriptStatus.trailingAnchor.constraint(equalTo: jumpButton.leadingAnchor, constant: -12),
            transcriptStatus.centerYAnchor.constraint(equalTo: recordDot.centerYAnchor),
            transcriptStatus.heightAnchor.constraint(equalToConstant: 28),
        ])
    }

    func showTranscriptSaveStatus(_ message: String, open: (() -> Void)? = nil) {
        openTranscript = open
        transcriptStatus.title = message
        transcriptStatus.isHidden = false
        transcriptStatus.isEnabled = open != nil
        transcriptStatus.toolTip = open == nil ? message : String(localized: "Open transcript")
        transcriptStatus.setAccessibilityLabel(message)
        transcriptStatus.setAccessibilityHelp(transcriptStatus.toolTip)
        NSAccessibility.post(element: transcriptStatus, notification: .announcementRequested,
                             userInfo: [.announcement: message,
                                        .priority: NSAccessibilityPriorityLevel.medium.rawValue])
    }

    @objc private func openSavedTranscript() { openTranscript?() }

    // MARK: - Hit regions

    /// The full-width strip along the top. Dragging happens here so the caption
    /// text below stays click-through.
    private var controlStrip: NSRect {
        NSRect(x: 0, y: bounds.maxY - controlStripHeight,
               width: bounds.width, height: controlStripHeight)
    }

    /// Everything you can pick the bubble up by.
    private var dragRegion: NSRect { clickThroughText ? controlStrip : bounds }

    private var copyRect: NSRect { copyButton.frame.insetBy(dx: -10, dy: -10) }
    private var saveRect: NSRect { saveButton.frame.insetBy(dx: -10, dy: -10) }
    private var clearRect: NSRect { clearButton.frame.insetBy(dx: -10, dy: -10) }
    private var jumpRect: NSRect { jumpButton.isHidden ? .zero : jumpButton.frame.insetBy(dx: -4, dy: -4) }

    // MARK: - Tracking

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let t = tracking { removeTrackingArea(t) }
        // .activeAlways is what makes this fire while the app is inactive, and
        // .inVisibleRect keeps the rect right as the bubble resizes with the
        // caption length.
        let t = NSTrackingArea(rect: bounds,
                               options: [.mouseEnteredAndExited, .mouseMoved,
                                         .activeAlways, .inVisibleRect],
                               owner: self, userInfo: nil)
        addTrackingArea(t)
        tracking = t
    }

    override func mouseEntered(with event: NSEvent) {
        setControls(visible: true)
    }

    override func mouseExited(with event: NSEvent) {
        setControls(visible: false)
        NSCursor.arrow.set()
        // Always fall back to click-through when the cursor leaves.
        window?.ignoresMouseEvents = true
    }

    override func mouseMoved(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        // The resize band stays live even in click-through mode. It is 8 pt, so
        // it costs the video underneath almost nothing, and without it the
        // bubble is resizable in principle and ungrabbable in practice.
        let interactive = dragRegion.insetBy(dx: -armSlack, dy: -armSlack).contains(p)
            || resizeCursor(at: p) != nil
        if window?.ignoresMouseEvents != !interactive {
            window?.ignoresMouseEvents = !interactive
        }
        // An open hand over the strip is a far better "you can move this" hint
        // than a glyph that looks clickable but is not.
        guard interactive else { return }
        if let resize = resizeCursor(at: p) {
            resize.set()
        } else if copyRect.contains(p) || saveRect.contains(p) || clearRect.contains(p) || jumpRect.contains(p)
                    || (!transcriptStatus.isHidden && transcriptStatus.frame.contains(p)) {
            NSCursor.arrow.set()
        } else {
            NSCursor.openHand.set()
        }
    }

    /// How wide the grab band around each edge is. Matches the band `mouseDown`
    /// hands to the system's resize machinery, so the cursor never promises a
    /// resize that the click would turn into a drag.
    static let edgeGrab: CGFloat = 8

    /// The resize cursor for this point, or nil if it is not near an edge.
    ///
    /// A borderless panel draws no frame, so macOS provides no cursor for it —
    /// the bubble was resizable with no indication whatsoever that it was. These
    /// are the private system cursors AppKit itself uses for window edges;
    /// `NSCursor.resizeLeftRight` is the documented fallback, which points the
    /// right way but does not show the corner diagonals.
    func resizeCursor(at p: NSPoint) -> NSCursor? {
        let e = Self.edgeGrab
        let left = p.x < e, right = p.x > bounds.maxX - e
        let bottom = p.y < e, top = p.y > bounds.maxY - e
        switch (left, right, bottom, top) {
        case (true, _, true, _), (_, true, _, true):
            return Self.systemCursor("_windowResizeNorthEastSouthWestCursor")
                ?? .resizeLeftRight
        case (true, _, _, true), (_, true, true, _):
            return Self.systemCursor("_windowResizeNorthWestSouthEastCursor")
                ?? .resizeLeftRight
        case (true, _, _, _), (_, true, _, _):
            return Self.systemCursor("_windowResizeEastWestCursor") ?? .resizeLeftRight
        case (_, _, true, _), (_, _, _, true):
            return Self.systemCursor("_windowResizeNorthSouthCursor") ?? .resizeUpDown
        default:
            return nil
        }
    }

    /// AppKit's own window-edge cursors are unexported. Asked for by name so a
    /// future macOS that drops them degrades to the public arrows rather than
    /// crashing.
    private static func systemCursor(_ name: String) -> NSCursor? {
        let sel = NSSelectorFromString(name)
        guard NSCursor.responds(to: sel) else { return nil }
        return NSCursor.perform(sel)?.takeUnretainedValue() as? NSCursor
    }

    private func setControls(visible: Bool) {
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.14
            ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            ctx.allowsImplicitAnimation = true
            copyButton.animator().alphaValue = visible ? 1 : 0
            saveButton.animator().alphaValue = visible ? 1 : 0
            clearButton.animator().alphaValue = visible ? 1 : 0
        }
    }

    // MARK: - Click / drag

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)

        if !transcriptStatus.isHidden, transcriptStatus.frame.contains(p) {
            transcriptStatus.performClick(nil)
            return
        }

        if !jumpButton.isHidden, jumpRect.contains(p) {
            jumpButton.onPress?()
            return
        }

        if copyRect.contains(p) {
            copyButton.onPress?()
            return
        }
        if saveRect.contains(p) {
            saveButton.onPress?()
            return
        }
        if clearRect.contains(p) {
            clearButton.onPress?()
            return
        }
        // Edges first, and regardless of the drag region: the system's resize
        // machinery owns the gesture there, and starting a window drag instead
        // would make the bubble un-resizable. Checked before the drag-region
        // guard so the edges still work in click-through mode.
        if resizeCursor(at: p) != nil {
            super.mouseDown(with: event)
            return
        }
        guard dragRegion.insetBy(dx: -armSlack, dy: -armSlack).contains(p) else { return }
        // Option-drag is macOS's own window-tiling accelerator — letting it
        // through relocates the bubble to a screen edge after mouseUp.
        guard !event.modifierFlags.contains(.option) else { return }

        // performDrag hands the gesture to the window server: exact, and it keeps
        // the window participating in Space switching. It works even with
        // isMovable = false, which is what kills accidental background drags.
        window?.performDrag(with: event)
    }

    private func flashCopied() {
        copyFlashWork?.cancel()
        let cfg = NSImage.SymbolConfiguration(pointSize: 13, weight: .semibold)
        copyButton.image = NSImage(systemSymbolName: "checkmark",
                                   accessibilityDescription: nil)?
            .withSymbolConfiguration(cfg)
        copyButton.contentTintColor = NSColor.systemGreen
        copyButton.setAccessibilityLabel(String(localized: "Copied"))
        let w = DispatchWorkItem { [weak self] in
            self?.copyButton.image = NSImage(systemSymbolName: "doc.on.doc",
                                             accessibilityDescription: nil)?
                .withSymbolConfiguration(cfg)
            self?.copyButton.contentTintColor = NSColor.white.withAlphaComponent(0.75)
            self?.copyButton.setAccessibilityLabel(String(localized: "Copy this caption"))
        }
        copyFlashWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2, execute: w)
    }
}

/// A single original/translation pair in the scrollable subtitle history.
private final class FlippedDocumentView: NSView {
    override var isFlipped: Bool { true }
}

private final class CaptionRowView: NSView {
    let original = NSTextField(labelWithString: "")
    private let speaker = NSTextField(labelWithString: "")
    let translation = NSTextField(labelWithString: "")
    private var style = CaptionStyle()
    private var originalPointSize: CGFloat?
    private var translationPointSize: CGFloat?
    private static let textHeightCache: NSCache<NSString, NSNumber> = {
        let cache = NSCache<NSString, NSNumber>()
        cache.countLimit = 512
        return cache
    }()

    override init(frame: NSRect) {
        super.init(frame: frame)
        // The row is frame-managed by OverlayWindow. Keeping this small view
        // free of Auto Layout also removes a second re-entry point while the
        // scroll document is first being displayed on macOS 27.
        translatesAutoresizingMaskIntoConstraints = true
        addSubview(original)
        addSubview(translation)
        addSubview(speaker)
        speaker.font = .systemFont(ofSize: 12, weight: .medium)
        speaker.textColor = .secondaryLabelColor
        speaker.alignment = .center
        speaker.isHidden = true
        speaker.setAccessibilityRole(.staticText)
        for text in [original, translation] {
            text.alignment = .center
            text.lineBreakMode = .byWordWrapping
            text.cell?.wraps = true
            text.translatesAutoresizingMaskIntoConstraints = true
            text.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        }
        original.setAccessibilityRole(.staticText)
        original.setAccessibilityLabel(String(localized: "Live caption"))
        translation.setAccessibilityRole(.staticText)
        translation.setAccessibilityLabel(String(localized: "Translation"))
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        let width = max(1, bounds.width)
        let originalFont = style.original.stabilizedFont(
            for: original.stringValue,
            width: width,
            minimumSize: 18,
            maxLines: style.original.maxLines,
            previousPointSize: originalPointSize)
        originalPointSize = originalFont.pointSize
        original.font = originalFont
        let originalHeight = Self.textHeight(original.stringValue,
                                              font: originalFont,
                                              width: width,
                                              maxLines: style.original.maxLines)
        var top = bounds.height
        if !speaker.isHidden {
            speaker.frame = NSRect(x: 0, y: max(0, top - 18), width: width, height: 16)
            top -= 20
        }
        original.frame = NSRect(x: 0,
                                y: max(0, top - originalHeight),
                                width: width,
                                height: originalHeight)
        if abs(original.preferredMaxLayoutWidth - width) > 0.5 {
            original.preferredMaxLayoutWidth = width
        }
        top -= originalHeight

        if !translation.isHidden {
            top -= CGFloat(style.lineGap)
            let translationFont = style.translation.stabilizedFont(
                for: translation.stringValue.isEmpty ? " " : translation.stringValue,
                width: width,
                minimumSize: 16,
                maxLines: style.translation.maxLines,
                previousPointSize: translationPointSize)
            translationPointSize = translationFont.pointSize
            translation.font = translationFont
            let translationHeight = Self.textHeight(
                translation.stringValue.isEmpty ? " " : translation.stringValue,
                font: translationFont,
                width: width,
                maxLines: style.translation.maxLines)
            translation.frame = NSRect(x: 0,
                                       y: max(0, top - translationHeight),
                                       width: width,
                                       height: translationHeight)
            if abs(translation.preferredMaxLayoutWidth - width) > 0.5 {
                translation.preferredMaxLayoutWidth = width
            }
        } else {
            translation.frame = .zero
        }
    }

    func apply(style: CaptionStyle, staleDim: CGFloat, reserveTranslation: Bool) {
        self.style = style
        original.font = style.original.font
        original.textColor = style.original.color
        speaker.textColor = style.original.color
        speaker.alphaValue = style.original.opacity * 0.75
        original.alphaValue = style.original.opacity
        original.maximumNumberOfLines = style.original.maxLines
        translation.font = style.translation.font
        translation.textColor = style.translation.color
        translation.alphaValue = style.translation.opacity * staleDim
        translation.maximumNumberOfLines = style.translation.maxLines
        translation.isHidden = !style.showTranslation
            || (translation.stringValue.isEmpty && !reserveTranslation)
        needsLayout = true
    }

    func set(entry: CaptionHistoryEntry, style: CaptionStyle, staleDim: CGFloat,
             reserveTranslation: Bool) {
        speaker.stringValue = entry.speakerLabel ?? ""
        speaker.isHidden = entry.speakerLabel == nil
        original.stringValue = entry.original
        translation.stringValue = entry.translation ?? ""
        apply(style: style,
              staleDim: entry.translationIsStale ? staleDim : 1,
              reserveTranslation: reserveTranslation)
    }

    static func textHeight(_ text: String, font: NSFont, width: CGFloat,
                           maxLines: Int) -> CGFloat {
        guard !text.isEmpty else { return 0 }
        let cacheWidth = max(1, floor(width / 4) * 4)
        let key = "\(text)|\(font.fontName)|\(font.pointSize)|\(maxLines)|\(cacheWidth)" as NSString
        if let cached = textHeightCache.object(forKey: key) {
            return CGFloat(cached.doubleValue)
        }
        let rect = (text as NSString).boundingRect(
            with: NSSize(width: cacheWidth, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: font])
        var height = ceil(rect.height)
        if maxLines > 0 {
            let line = ceil(font.ascender - font.descender + font.leading)
            height = min(height, line * CGFloat(maxLines) + 2)
        }
        textHeightCache.setObject(NSNumber(value: Double(height)), forKey: key)
        return height
    }

    static func height(for entry: CaptionHistoryEntry, style: CaptionStyle,
                       width: CGFloat, reserveTranslation: Bool) -> CGFloat {
        let originalFont = style.original.fittedFont(for: entry.original,
                                                     width: width,
                                                     minimumSize: 18,
                                                     maxLines: style.original.maxLines)
        let original = textHeight(entry.original, font: originalFont,
                                  width: width, maxLines: style.original.maxLines)
            + (entry.speakerLabel == nil ? 0 : 20)
        guard style.showTranslation,
              reserveTranslation || !(entry.translation ?? "").isEmpty else {
            return original
        }
        let t = entry.translation ?? " "
        let translationFont = style.translation.fittedFont(for: t,
                                                           width: width,
                                                           minimumSize: 16,
                                                           maxLines: style.translation.maxLines)
        return original + CGFloat(style.lineGap)
            + textHeight(t, font: translationFont, width: width,
                         maxLines: style.translation.maxLines)
    }
}

/// The caption bubble: a borderless Liquid Glass panel that floats above
/// everything, passes clicks through, and can be picked up by its top strip.
///
/// Window flags that are load-bearing, each verified:
///   - `.nonactivatingPanel` — receives mouse events without ever activating the
///     app or taking key focus from whatever you are watching.
///   - `isOpaque = false` + `backgroundColor = .clear` — without both,
///     `NSGlassEffectView` renders as a flat dark rectangle, with no error.
///   - `isMovable = false` — kills accidental and system-initiated background
///     drags; `performDrag(with:)` still works.
///   - level `.screenSaver` + `.fullScreenAuxiliary` — stays visible over
///     full-screen video instead of vanishing.
final class OverlayWindow: NSPanel {
    private let scrollView = NSScrollView()
    /// A plain document view is deliberate. NSStackView asks AppKit to infer
    /// the document height while rows are being inserted, which can re-enter
    /// layout during the first presentation on macOS 27. Rows are positioned
    /// explicitly instead, so the scroll view always has a real frame to draw.
    private let historyStack = FlippedDocumentView()
    private let host = BubbleContentView()
    private lazy var surface = BubbleSurfaceView(contentView: host)
    private var history = CaptionHistory()
    private var rowViews: [Int: CaptionRowView] = [:]

    private var saveWork: DispatchWorkItem?
    private var hasCustomFrame = false
    private var appliedHidden = CaptionStyle.current.hidden
    /// Width chosen by dragging an edge; nil = size to the text.
    private var userWidth: CGFloat?

    var onCopy: (() -> Void)? {
        get { host.onCopy }
        set { host.onCopy = newValue }
    }

    var onSaveTranscript: (() -> Void)? {
        get { host.onSaveTranscript }
        set { host.onSaveTranscript = newValue }
    }

    func showTranscriptSaveStatus(_ message: String, open: (() -> Void)? = nil) {
        host.showTranscriptSaveStatus(message, open: open)
    }

    var onClear: (() -> Void)? {
        get { host.onClear }
        set { host.onClear = newValue }
    }

    var isRecording: Bool {
        get { host.isRecording }
        set { host.isRecording = newValue }
    }

    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 1000, height: 110),
            styleMask: [.borderless, .nonactivatingPanel, .resizable],
            backing: .buffered,
            defer: false
        )

        isFloatingPanel = true
        becomesKeyOnlyIfNeeded = true
        level = .screenSaver
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = true      // resting state: click-through
        isMovable = false              // move only via performDrag
        hidesOnDeactivate = false
        acceptsMouseMovedEvents = true
        // No system fade. A panel's default order-out animation kept the
        // bubble on screen for about 0.3 s after Stop, three times the 100 ms
        // target, and captions appear and leave with the speech anyway.
        animationBehavior = .none

        historyStack.frame = NSRect(x: 0, y: 0, width: 1, height: 1)
        historyStack.autoresizingMask = [.width]
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        scrollView.verticalScrollElasticity = .automatic
        scrollView.documentView = historyStack
        scrollView.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(historyScrollChanged(_:)),
                                               name: NSView.boundsDidChangeNotification, object: scrollView.contentView)
        host.onJumpToLatest = { [weak self] in self?.jumpToLatest() }

        host.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(scrollView)
        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: host.leadingAnchor, constant: 24),
            scrollView.trailingAnchor.constraint(equalTo: host.trailingAnchor, constant: -24),
            // Leave room for the control strip so hovering never covers the text.
            scrollView.topAnchor.constraint(equalTo: host.topAnchor, constant: 34),
            scrollView.bottomAnchor.constraint(equalTo: host.bottomAnchor, constant: -14),
        ])

        contentView = surface

        contentMinSize = NSSize(width: 280, height: 110)
        restoreFrame()
        applyStyle(CaptionStyle.current)

        // A user-dragged edge sets the bubble's width; from then on text wraps
        // to it instead of the bubble resizing itself around the text.
        NotificationCenter.default.addObserver(
            forName: NSWindow.didEndLiveResizeNotification, object: self,
            queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    // A deliberate edge drag is the opt-in manual sizing mode.
                    // Keep the setting honest so the next launch restores the
                    // width the user actually chose.
                    if CaptionStyle.current.autoResize {
                        var style = CaptionStyle.current
                        style.autoResize = false
                        CaptionStyle.current = style
                    }
                    // Cap what we remember, not just what we draw: an
                    // un-capped width restored later on a smaller display is
                    // how the bubble ended up hanging off both edges.
                    let usable = (FrameStore.bestScreen(for: self.frame)
                                  ?? NSScreen.main)?.visibleFrame.width ?? self.frame.width
                    let w = min(self.frame.width, usable)
                    self.userWidth = w
                    self.hasCustomFrame = true
                    // The one place a deliberate width is recorded.
                    FrameStore.saveUserWidth(w)
                    self.sizeToFit(immediateShrink: true)
                    self.keepOnScreen()
                    FrameStore.save(self.frame)
                }
            }

        NotificationCenter.default.addObserver(
            forName: .saiityCaptionStyleChanged, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in self?.applyStyle(CaptionStyle.current) }
            }
        // Reduce Transparency / Increase Contrast changing mid-session must
        // take effect immediately, like every other style change.
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
            object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in self?.applyStyle(CaptionStyle.current) }
            }
        NotificationCenter.default.addObserver(
            forName: .saiityCaptionPreview, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in self?.showPreview() }
            }

        NotificationCenter.default.addObserver(
            self, selector: #selector(frameMoved),
            name: NSWindow.didMoveNotification, object: self)
        NotificationCenter.default.addObserver(
            self, selector: #selector(screensChanged),
            name: NSApplication.didChangeScreenParametersNotification, object: nil)
    }

    // MARK: - Geometry

    private func defaultFrame(on screen: NSScreen) -> NSRect {
        let v = screen.visibleFrame
        let width = Self.minWidth
        return NSRect(x: v.midX - width / 2, y: v.minY + 90, width: width, height: 110)
    }

    /// Non-zero while the app itself is moving the window.
    ///
    /// `setFrame` posts `didMoveNotification` exactly like a user drag does, and
    /// telling the two apart is the whole ballgame: `frameMoved` used to mark
    /// EVERY move as user-chosen, so the app's very first frame assignment —
    /// inside `restoreFrame`, before a caption had ever been shown — permanently
    /// disabled the re-centring branch in `sizeToFit`. Nothing could pull the
    /// bubble back after that, which is why it stayed wherever a clamp put it.
    private var programmaticMoves = 0

    private func moveProgrammatically(_ body: () -> Void) {
        programmaticMoves += 1
        body()
        // The notification is posted synchronously by setFrame, so by here it
        // has already been handled and the count can come straight back down.
        programmaticMoves -= 1
    }

    /// Every internal frame change goes through this. A `setFrame` that skips it
    /// will be mistaken for a user drag.
    private func setFrameInternal(_ rect: NSRect, display: Bool = true) {
        moveProgrammatically { setFrame(rect, display: display) }
    }

    private func restoreFrame() {
        guard let saved = FrameStore.load(),
              let screen = FrameStore.bestScreen(for: saved) else {
            if let s = NSScreen.main { setFrameInternal(defaultFrame(on: s), display: false) }
            return
        }
        hasCustomFrame = true
        // A saved frame means "this is where it was", not "the user chose this
        // width". Restore a stored drag width only in manual sizing mode, so an
        // automatic bubble cannot inherit a stale width from an older session.
        let v = screen.visibleFrame
        let st = CaptionStyle.current
        userWidth = st.autoResize ? nil
                                  : FrameStore.loadUserWidth().map { min($0, screen.visibleFrame.width) }
        var f = FrameStore.clamp(saved, into: v)
        // A saved frame records WHERE the bubble was, never how wide it should
        // be. Without a stored user width the width is a setting, so a width
        // left over from a wider display, an older build or a since-changed
        // setting must not survive the restore. Found in the field: 1520pt
        // restored onto a 1710pt screen whose setting asks for 1060, which left
        // 41pt of gap on one side and 149 on the other and honoured the 24pt
        // margin on neither.
        if st.autoResize || userWidth == nil {
            f.size.width = BubbleGeometry.autoWidth(visible: v.width,
                                                    fraction: CGFloat(st.widthFraction),
                                                    margin: CGFloat(st.screenMargin))
        }
        // And the margin-aware clamp, not FrameStore's margin-blind one — that
        // one only caps at the screen edge, so it would happily restore a bubble
        // running the full width of the display with no margin at all.
        setFrameInternal(BubbleGeometry.clamp(f, into: v,
                                              margin: CGFloat(st.screenMargin),
                                              respectMargin: st.autoResize || userWidth == nil),
                         display: false)
    }

    @objc private func frameMoved() {
        // A move the app made itself says nothing about what the user wants.
        guard programmaticMoves == 0 else { return }
        hasCustomFrame = true
        // Coalesce the flood of move notifications during a drag.
        saveWork?.cancel()
        let w = DispatchWorkItem { [weak self] in
            guard let self else { return }
            // Applied after the drag ends rather than during it, so the bubble
            // does not fight the cursor — but it always ends up on screen.
            self.keepOnScreen()
            FrameStore.save(self.frame)
        }
        saveWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: w)
    }

    @objc private func screensChanged() {
        // A display was added, removed or resized. Whatever the bubble's width
        // was — a remembered drag from a wider monitor, most likely — it has to
        // fit the screen it is on now.
        userWidth = CaptionStyle.current.autoResize ? nil : userWidth.map {
            min($0, (FrameStore.bestScreen(for: frame) ?? NSScreen.main)?.visibleFrame.width ?? $0)
        }
        keepOnScreen()
        sizeToFit(immediateShrink: true)
    }

    private static let hPadding: CGFloat = 24      // each side
    private static let topPadding: CGFloat = 34    // control strip
    private static let bottomPadding: CGFloat = 14
    private static let historyRowGap: CGFloat = 10
    /// Wide enough that the corner controls never collide with the text.
    private static var minWidth: CGFloat { BubbleGeometry.minWidth }

    /// The width the bubble should have, independent of what it is showing.
    ///
    /// THIS is the fix for "the bubble moves when a translation arrives". The
    /// width used to be `max(caption width, translation width)`, so the instant
    /// a translation landed the measurement jumped and the window re-centred —
    /// and because the translation arrives in its own async callback, the user
    /// saw two layout events per line. Nothing about the text enters this
    /// calculation any more.
    private func targetWidth(in visible: NSRect) -> CGFloat {
        let st = CaptionStyle.current
        if !st.autoResize, let uw = userWidth {
            return BubbleGeometry.draggedWidth(uw, visible: visible.width)
        }
        return BubbleGeometry.autoWidth(visible: visible.width,
                                        fraction: CGFloat(st.widthFraction),
                                        margin: CGFloat(st.screenMargin))
    }

    /// Size the bubble to the caption — in BOTH axes.
    ///
    /// A fixed-width bar leaves short captions floating in a wide empty slab and
    /// strands the corner controls far from the text. So: measure the text
    /// unwrapped, clamp into [minWidth, maxWidth], then measure the height at
    /// that width. Growth is symmetric about the bubble's centre, and the top
    /// edge stays put, so a bubble the user has placed does not walk around as
    /// the caption length changes.
    ///
    /// Grow-fast/shrink-slow for the height. The next sentence's first
    /// volatile replaces the whole previous sentence, so a three-line caption
    /// used to collapse to the minimum and regrow word by word — a glass-slab
    /// pulse at every sentence boundary, worst in rapid dialogue where
    /// turnovers come every couple of seconds. Growth stays immediate; a
    /// shrink only lands once the smaller need has persisted for this long.
    private static let shrinkHold: TimeInterval = 1.5
    private var shrinkWork: DispatchWorkItem?
    private var allowShrink = false
    private var scrollToLatestPending = false
    private var followsLatest = true
    private var isAdjustingScroll = false
    private static let volatileRenderInterval: TimeInterval = 0.1
    private var renderWork: DispatchWorkItem?
    private var pendingRenderSentenceID: Int?
    private var lastRenderAt = Date.distantPast
    private var volatileSentenceID: Int?
    #if SAIITY_TEST_HOOKS
    private var renderPassCount = 0
    private var historyLayoutPassCount = 0
    private var presentationRequestCount = 0
    #endif

    /// Gated on an actual size change: glass costs more per resize than a
    /// visual-effect view, and captions update several times a second.
    ///
    /// `immediateShrink` bypasses the shrink hold — for deliberate user
    /// actions (style change, reset, resize, display change), where a bubble
    /// that answers 1.5 s late reads as broken rather than calm.
    private func sizeToFit(immediateShrink: Bool = false) {
        guard let screen = FrameStore.bestScreen(for: frame) ?? NSScreen.main else { return }
        let v = screen.visibleFrame
        // The same adjusted style applyStyle draws with — measuring with the raw
        // one would size the bubble for a lighter font than is on screen when
        // Increase Contrast is active.
        let st = effectiveStyle

        let targetW = targetWidth(in: v)
        let contentW = targetW - Self.hPadding * 2
        // Wrap to the bubble's CURRENT width, not to whatever it was when the
        // labels were built. This is also what keeps the height measured below
        // in agreement with what is actually drawn — measuring a wrap at one
        // width and laying it out at another is how a bubble ends up with a
        // line more than it has room for.
        // Only the HEIGHT responds to content: text wraps inside a fixed width
        // and the bubble grows until the persisted limit, then the scroll view
        // carries the older rows.
        var contentH: CGFloat = 0
        for (index, entry) in history.entries.enumerated() {
            let reserve = reservesTranslationRow
                && entry.sentenceID == history.entries.last?.sentenceID
            contentH += CaptionRowView.height(for: entry, style: st,
                                              width: contentW,
                                              reserveTranslation: reserve)
            if index > 0 { contentH += Self.historyRowGap }
        }
        let configuredMax = max(110, CGFloat(st.maxHeight))
        let targetH = min(max(110, contentH + Self.topPadding + Self.bottomPadding),
                          min(configuredMax, v.height * 0.8))

        var height = targetH
        if immediateShrink || allowShrink || targetH >= frame.height - 0.5 {
            // Growing, matching, or explicitly allowed to shrink: no hold.
            shrinkWork?.cancel()
            shrinkWork = nil
        } else {
            // Smaller than what is on screen: hold the current height and
            // remeasure in a beat. Deliberately NOT re-armed per caption —
            // rapid short captions would push the deadline forever and the
            // bubble would never come down.
            height = frame.height
            if shrinkWork == nil {
                let w = DispatchWorkItem { [weak self] in
                    guard let self else { return }
                    self.shrinkWork = nil
                    self.allowShrink = true
                    self.sizeToFit()
                    self.allowShrink = false
                }
                shrinkWork = w
                DispatchQueue.main.asyncAfter(deadline: .now() + Self.shrinkHold,
                                              execute: w)
            }
        }

        var f = frame
        f.size = NSSize(width: targetW, height: height)
        // Width only changes when a SETTING changes, so re-centring on it is
        // now a deliberate response to the user, not per-caption jitter.
        if abs(targetW - frame.width) > 0.5 { f.origin.x = frame.midX - targetW / 2 }
        // origin.y is left alone: in AppKit that is the bottom edge, so the
        // bubble grows upward and its base stays where the user put it.
        if !hasCustomFrame {
            f.origin.x = v.midX - targetW / 2
            f.origin.y = v.minY + 90
        }
        let final = clampKeepingBottom(f, into: v, margin: CGFloat(st.screenMargin))

        // Compare against the CLAMPED result, not the unclamped target. The
        // early-out used to sit above this, so a frame that was already off the
        // screen — restored from a wider display, or left over from a drag —
        // matched its own target and was returned unchanged, hanging off both
        // edges with the text clipped. Containment now wins every time.
        guard abs(final.width - frame.width) > 0.5
                || abs(final.height - frame.height) > 0.5
                || abs(final.origin.x - frame.origin.x) > 0.5
                || abs(final.origin.y - frame.origin.y) > 0.5 else {
            layoutHistory()
            return
        }

        if TestHooks.verboseLogging {
            // The bubble's stillness cannot be seen from a script, so it is
            // logged: x and width must not change between captions.
            NSLog(String(format: "sAiity bubble: x=%.0f y=%.0f w=%.0f h=%.0f screen=%.0f",
                         final.origin.x, final.origin.y, final.width, final.height, v.width))
        }
        setFrameInternal(final)
        layoutHistory()
    }

    /// Force the bubble back inside its screen, whatever put it outside.
    ///
    /// Called after anything that can move or resize it, including the user
    /// doing so themselves: a window dragged half off the display, or a width
    /// restored from a monitor that is no longer attached, has to come back.
    /// The rule is simply that the bubble is always fully on screen.
    func keepOnScreen() {
        guard let screen = FrameStore.bestScreen(for: frame) ?? NSScreen.main else { return }
        let margin = CGFloat(CaptionStyle.current.screenMargin)
        let f = clampKeepingBottom(frame, into: screen.visibleFrame, margin: margin)
        if f != frame { setFrameInternal(f) }
    }

    /// Keep the bubble on screen without undoing the bottom anchor.
    ///
    /// The generic clamp pushed the whole window DOWN when growth took its top
    /// edge past the screen, which reads as the bubble jumping. Here the height
    /// is trimmed instead, so the base never moves. The margin is honoured
    /// horizontally unless the user has deliberately dragged the bubble wider.
    private func clampKeepingBottom(_ rect: NSRect, into visible: NSRect,
                                    margin: CGFloat) -> NSRect {
        BubbleGeometry.clamp(rect, into: visible, margin: margin,
                             respectMargin: CaptionStyle.current.autoResize || userWidth == nil)
    }

    /// Push the persisted look onto the live window. Called on every change so
    /// the settings page is a real preview, not a promise about next launch.
    /// The system accessibility settings the style must defer to. A user who
    /// set Reduce Transparency system-wide has answered the glass question for
    /// every app; the bubble does not get to overrule that.
    private var effectiveStyle: CaptionStyle {
        var st = CaptionStyle.current
        let a11y = NSWorkspace.shared
        if a11y.accessibilityDisplayShouldReduceTransparency,
           st.glassStyle != CaptionStyle.solidGlass {
            st.glassStyle = CaptionStyle.solidGlass   // solid
        }
        if a11y.accessibilityDisplayShouldIncreaseContrast {
            st.glassStyle = CaptionStyle.solidGlass
            st.original.weight = max(st.original.weight, 0.3)
            st.translation.weight = max(st.translation.weight, 0.3)
            st.original.opacity = 1.0
            st.translation.opacity = 1.0
            // The volatile dim says "the engine may still revise this", but
            // 0.72-alpha text on glass is exactly the legibility loss the
            // setting exists to forbid. Contrast wins over the hint.
            st.original.volatileOpacity = 1.0
            st.translation.volatileOpacity = 1.0
        }
        return st
    }

    /// The stale-translation dim factor. Increase Contrast lifts it for the
    /// same reason effectiveStyle lifts the volatile dim: dimming is how the
    /// row says "previous sentence", and legibility outranks the hint.
    private var staleDim: CGFloat {
        NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast ? 1.0 : 0.55
    }

    func applyStyle(_ ignored: CaptionStyle) {
        let st = effectiveStyle
        if st.autoResize {
            userWidth = nil
            FrameStore.clearUserWidth()
        }
        // Every visual property comes from the struct. Nothing is hardcoded
        // here any more: the original used to be fixed white/semibold and the
        // translation fixed teal/medium, so half the style fields were read but
        // could never be changed and the rest were not read at all.
        for entry in history.entries {
            rowViews[entry.sentenceID]?.set(
                entry: entry,
                style: st,
                staleDim: staleDim,
                reserveTranslation: reservesTranslationRow
                    && entry.sentenceID == history.entries.last?.sentenceID)
        }

        surface.apply(style: st)
        // Both directions. Only the hide half existed, so un-hiding — which
        // now has its own global hot key — did nothing visible until the next
        // caption chunk happened to arrive, which during a pause in speech
        // reads as a broken shortcut.
        let wasHidden = appliedHidden
        appliedHidden = st.hidden
        if st.hidden {
            orderOut(nil)
        } else if !history.entries.isEmpty {
            presentIfNeeded()
        } else if wasHidden {
            reveal()
        }
        sizeToFit(immediateShrink: true)
    }

#if SAIITY_TEST_HOOKS
    var renderedBubbleStyleForTests: Int { surface.renderedStyle }
    var usesLiquidGlassForTests: Bool { surface.usesLiquidGlassForTests }
    var renderedStyleForTests: CaptionStyle { effectiveStyle }
    var renderPassesForTests: Int { renderPassCount }
    var historyLayoutPassesForTests: Int { historyLayoutPassCount }
    var presentationRequestsForTests: Int { presentationRequestCount }
    var followsLatestForTests: Bool { followsLatest }
    var historyScrollOffsetForTests: CGFloat { scrollView.contentView.bounds.minY }
    var historyEntriesForTests: [CaptionHistoryEntry] { history.entries }
    var historyScrollMaximumForTests: CGFloat { max(0, historyStack.bounds.height - scrollView.contentView.bounds.height) }
    func scrollHistoryForTests(to offset: CGFloat) {
        scrollView.contentView.scroll(to: NSPoint(x: 0, y: offset))
        historyScrollChanged()
    }
#endif

    /// Reveal an intentionally enabled bubble even before the first caption
    /// arrives. Keeping this separate from `presentIfNeeded` avoids showing an
    /// empty panel on launch while making the Show Bubble toggle immediate.
    func reveal() {
        guard !CaptionStyle.current.hidden else { return }
        guard let screen = FrameStore.bestScreen(for: frame) ?? NSScreen.main else { return }
        if frame.width <= 1 || frame.height <= 1 {
            setFrameInternal(defaultFrame(on: screen), display: false)
        }
        sizeToFit(immediateShrink: true)
        presentIfNeeded(allowEmpty: true)
    }

    /// Present the bubble from one place. A panel can retain a logically valid
    /// but unusable frame after launch, display changes, or a saved frame from
    /// another monitor. Ordering that frame front does not make the bubble
    /// visible; repair it first, then raise the panel explicitly.
    private func presentIfNeeded(allowEmpty: Bool = false) {
        guard !CaptionStyle.current.hidden, allowEmpty || !history.entries.isEmpty else {
            orderOut(nil)
            return
        }
        guard let screen = FrameStore.bestScreen(for: frame) ?? NSScreen.main else { return }
        let visible = screen.visibleFrame
        if frame.width <= 1 || frame.height <= 1 {
            setFrameInternal(defaultFrame(on: screen), display: false)
        }
        let repaired = BubbleGeometry.clamp(frame,
                                            into: visible,
                                            margin: CGFloat(CaptionStyle.current.screenMargin),
                                            respectMargin: CaptionStyle.current.autoResize || userWidth == nil)
        if repaired != frame { setFrameInternal(repaired, display: false) }
        alphaValue = 1
        if !isVisible {
            #if SAIITY_TEST_HOOKS
            presentationRequestCount += 1
            #endif
            orderFrontRegardless()
        }
    }

    /// Show sample text so legibility can be judged without waiting for someone
    /// to speak.
    func showPreview() {
        let st = CaptionStyle.current
        clearHistory()
        show(text: CaptionStyle.longPreviewOriginal, isFinal: true, sentenceID: -1)
        showTranslation(st.showTranslation ? CaptionStyle.longPreviewTranslation : "",
                        forSentenceID: -1)
        presentIfNeeded()
    }

    /// Forget a dragged position and return to the default spot. Clearing the
    /// stored frame is not enough on its own — the live window keeps whatever it
    /// already has until something tells it to move, which is why the Settings
    /// button appeared to do nothing.
    func resetPosition() {
        hasCustomFrame = false
        userWidth = nil
        FrameStore.reset()
        // Recompute rather than keeping the width the bubble happens to have.
        // Reset has just discarded the user's chosen width, so the width is a
        // setting again — carrying the old one forward is how a dragged-wide
        // bubble survived a reset, got saved back out on the next drag, and came
        // back wider than the setting on every launch after that.
        //
        // sizeToFit does the centring too, now that hasCustomFrame is false:
        // it puts the bubble at the default spot with the width the settings
        // ask for, which is the whole point of this button.
        sizeToFit(immediateShrink: true)
    }

    // MARK: - Content

    /// `text` is shown dimmed while volatile so it is visually obvious the
    /// engine may still revise it.
    func show(text: String, isFinal: Bool, sentenceID: Int? = nil) {
        let id = sentenceID ?? history.entries.last?.sentenceID ?? -1
        if !text.isEmpty {
            history.upsertOriginal(text, sentenceID: id)
            volatileSentenceID = isFinal ? nil : id
            renderHistory(changedSentenceID: id, immediate: isFinal)
        }
        // effectiveStyle, not CaptionStyle.current: captions update several
        // times a second, and reading the raw style here dropped the
        // accessibility adjustments applyStyle had just made — Increase
        // Contrast survived only until the next caption arrived.
        let st = effectiveStyle
        rowViews[id]?.original.alphaValue = isFinal
            ? st.original.opacity : st.original.volatileOpacity
        guard !st.hidden else { orderOut(nil); return }
        presentIfNeeded()
    }

    /// Shown under the original line.
    ///
    /// While translation is switched on the row keeps its height even when it is
    /// empty — see `reservesTranslationRow`.
    ///
    /// `stale` dims the row: the source line has already moved on, so this
    /// translation belongs to the *previous* sentence. Dimming says so without
    /// removing it — a late translation the viewer can still attach to what
    /// they just read beats an empty row, which is what translating slower
    /// than recognising used to produce.
    func showTranslation(_ text: String, stale: Bool = false) {
        guard let id = history.entries.last?.sentenceID else { return }
        showTranslation(text, forSentenceID: id, stale: stale)
    }

    func showTranslation(_ text: String, forSentenceID sentenceID: Int,
                         stale: Bool = false) {
        // An empty value is used when translation is switched off. Keep the
        // history intact; the style controls whether those rows are visible.
        if !text.isEmpty {
            history.upsertTranslation(text, forSentenceID: sentenceID, stale: stale)
        }
        renderHistory(changedSentenceID: text.isEmpty ? nil : sentenceID, immediate: true)
    }

    func showSpeaker(_ label: String?, forSentenceID sentenceID: Int) {
        history.setSpeaker(label, forSentenceID: sentenceID)
        renderHistory(changedSentenceID: sentenceID, immediate: true)
    }

    /// The source moved on while this translation stayed. Same dimming as
    /// `showTranslation(stale: true)` without re-setting the text.
    func markTranslationStale(forSentenceID sentenceID: Int) {
        history.markTranslationStale(forSentenceID: sentenceID)
        renderHistory(changedSentenceID: sentenceID, immediate: true)
    }

    /// Hold a line of space for the translation for as long as translation is
    /// enabled, even between captions.
    ///
    /// Without this the bubble gained a row when a translation arrived and lost
    /// it again on the next caption, so it changed height twice per line. The
    /// cost is one empty line of glass while the translator is thinking, which
    /// is far less distracting than the bubble resizing under the text.
    var reservesTranslationRow = false {
        didSet {
            guard reservesTranslationRow != oldValue else { return }
            renderHistory(immediate: true)
            sizeToFit(immediateShrink: true)
        }
    }

    /// Replace the visible history, used by the recent-caption recap and the
    /// settings preview. The live transcript remains the source of truth.
    func showHistory(_ entries: [CaptionHistoryEntry]) {
        followsLatest = true
        volatileSentenceID = nil
        history.replace(with: entries)
        renderHistory(immediate: true)
        presentIfNeeded()
    }

    /// True only while a caption row is actually on screen. A hidden bubble,
    /// or one cleared down to an empty panel, is not showing a caption.
    var hasVisibleCaption: Bool {
        !CaptionStyle.current.hidden && !history.entries.isEmpty
    }

    func clearHistory(keepVisible: Bool = false) {
        followsLatest = true
        host.showsJumpToLatest = false
        volatileSentenceID = nil
        history.clear()
        renderHistory(immediate: true)
        if keepVisible {
            presentIfNeeded(allowEmpty: true)
        } else {
            orderOut(nil)
        }
    }

    func clear() { clearHistory() }

    /// Give the document view and every row concrete frames before AppKit is
    /// asked to display the panel. This avoids relying on an NSStackView to
    /// discover a scroll document's height during the same event that created
    /// the first subtitle bubble.
    private func layoutHistory() {
        #if SAIITY_TEST_HOOKS
        historyLayoutPassCount += 1
        #endif
        let width = max(1, frame.width - Self.hPadding * 2)
        let st = effectiveStyle
        var y: CGFloat = 0

        for (index, entry) in history.entries.enumerated() {
            guard let row = rowViews[entry.sentenceID] else { continue }
            let reserve = reservesTranslationRow
                && entry.sentenceID == history.entries.last?.sentenceID
            let height = CaptionRowView.height(for: entry, style: st,
                                               width: width,
                                               reserveTranslation: reserve)
            row.frame = NSRect(x: 0, y: y, width: width, height: max(1, height))
            y += height
            if index < history.entries.count - 1 { y += Self.historyRowGap }
        }

        historyStack.setFrameSize(NSSize(width: width, height: max(1, y)))
        historyStack.needsLayout = true
    }

    private func scrollToLatest() {
        isAdjustingScroll = true
        defer { isAdjustingScroll = false }
        let maxY = max(0, historyStack.bounds.height
            - scrollView.contentView.bounds.height)
        scrollView.contentView.scroll(to: NSPoint(x: 0, y: maxY))
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    @objc private func historyScrollChanged(_ notification: Notification? = nil) {
        guard !isAdjustingScroll else { return }
        let remaining = historyStack.bounds.height - scrollView.contentView.bounds.maxY
        followsLatest = remaining <= 8
        host.showsJumpToLatest = !followsLatest
    }

    func jumpToLatest() {
        followsLatest = true
        host.showsJumpToLatest = false
        scrollToLatest()
    }

    var isReviewingHistory: Bool { isVisible && !followsLatest }

    private func renderHistory(changedSentenceID: Int? = nil,
                               immediate: Bool = false) {
        if !immediate {
            pendingRenderSentenceID = changedSentenceID ?? pendingRenderSentenceID
            renderWork?.cancel()
            let elapsed = Date().timeIntervalSince(lastRenderAt)
            let delay = max(0, Self.volatileRenderInterval - elapsed)
            var work: DispatchWorkItem?
            work = DispatchWorkItem { [weak self] in
                guard let self, let work, !work.isCancelled else { return }
                self.renderWork = nil
                let pending = self.pendingRenderSentenceID
                self.pendingRenderSentenceID = nil
                self.renderHistory(changedSentenceID: pending, immediate: true)
            }
            renderWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work!)
            return
        }
        renderWork?.cancel()
        renderWork = nil
        pendingRenderSentenceID = nil
        lastRenderAt = Date()
        let oldOffset = scrollView.contentView.bounds.minY
        let anchor = history.entries.compactMap { entry -> (Int, CGFloat)? in
            guard let row = rowViews[entry.sentenceID], row.frame.maxY > oldOffset else { return nil }
            return (entry.sentenceID, oldOffset - row.frame.minY)
        }.first
        isAdjustingScroll = true
        defer { isAdjustingScroll = false }
        #if SAIITY_TEST_HOOKS
        renderPassCount += 1
        #endif
        let visibleIDs = Set(history.entries.map(\.sentenceID))
        let staleRows = rowViews.filter { !visibleIDs.contains($0.key) }
        for (id, row) in staleRows {
            row.removeFromSuperview()
            rowViews.removeValue(forKey: id)
        }

        let st = effectiveStyle
        for entry in history.entries {
            let row: CaptionRowView
            let isNew: Bool
            if let existing = rowViews[entry.sentenceID] {
                row = existing
                isNew = false
            } else {
                row = CaptionRowView()
                historyStack.addSubview(row)
                rowViews[entry.sentenceID] = row
                isNew = true
            }
            if isNew || changedSentenceID == nil || changedSentenceID == entry.sentenceID {
                row.set(entry: entry, style: st, staleDim: staleDim,
                        reserveTranslation: reservesTranslationRow
                            && entry.sentenceID == history.entries.last?.sentenceID)
            }

        }
        if let volatileSentenceID,
           let row = rowViews[volatileSentenceID] {
            row.original.alphaValue = st.original.volatileOpacity
        }
        // Every row is frame-managed, so this is a cheap invalidation rather
        // than an AppKit stack-layout pass that can re-enter on macOS 27.
        historyStack.needsLayout = true
        scrollView.needsLayout = true
        sizeToFit()
        if !followsLatest {
            let offset = anchor.flatMap { id, inset in rowViews[id].map { $0.frame.minY + inset } } ?? oldOffset
            let maximum = max(0, historyStack.bounds.height - scrollView.contentView.bounds.height)
            scrollView.contentView.scroll(to: NSPoint(x: 0, y: min(maximum, max(0, offset))))
            scrollView.reflectScrolledClipView(scrollView.contentView)
            host.showsJumpToLatest = true
            return
        }
        // Let AppKit finish the stack/document layout outside the caption
        // callback. Explicit layout calls can recurse on macOS 27 while the
        // window server is already laying out. One dispatch, one scroll: the
        // two separate blocks that used to do this ran twice per caption, and
        // the second was already guarded by `scrollToLatestPending` — so the
        // first one, the only one that ran on every pass, had nothing to
        // deduplicate against.
        guard !scrollToLatestPending else { return }
        scrollToLatestPending = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.scrollToLatestPending = false
            guard self.followsLatest else { return }
            self.scrollToLatest()
        }
    }
}
