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

    override func accessibilityPerformPress() -> Bool {
        guard let onPress else { return false }
        onPress()
        return true
    }

    override func setAccessibilityFocused(_ flag: Bool) {
        super.setAccessibilityFocused(flag)
        if flag { onAccessibilityFocus?() }
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
    var onOpenWindow: (() -> Void)?
    var onClear: (() -> Void)?

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
    /// The dot's two homes: the settings icon's spot while the controls are
    /// hidden, and just right of the icon once it fades in.
    private var dotAtIconSpot: NSLayoutConstraint!
    private var dotBesideIcon: NSLayoutConstraint!
    private let menuButton = AccessibleIconButton()
    private let copyButton = AccessibleIconButton()
    private let clearButton = AccessibleIconButton()
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
        // Was a bare drag-handle glyph, which looked like a button and did
        // nothing when clicked. Now it opens the main window — the bubble is
        // often the only part of sAiity on screen.
        menuButton.image = NSImage(systemSymbolName: "slider.horizontal.3",
                                   accessibilityDescription: nil)?
            .withSymbolConfiguration(cfg)
        menuButton.contentTintColor = NSColor.white.withAlphaComponent(0.75)
        menuButton.alphaValue = 0
        menuButton.toolTip = String(localized: "Open sAiity")

        copyButton.image = NSImage(systemSymbolName: "doc.on.doc",
                                   accessibilityDescription: nil)?
            .withSymbolConfiguration(cfg)
        copyButton.contentTintColor = NSColor.white.withAlphaComponent(0.75)
        copyButton.alphaValue = 0
        copyButton.toolTip = String(localized: "Copy this line")

        // Wipe what is on screen without stopping recognition — for the moment
        // a caption is still sitting over something you want to see, or a line
        // you would rather not leave on a shared screen.
        clearButton.image = NSImage(systemSymbolName: "xmark.circle",
                                    accessibilityDescription: nil)?
            .withSymbolConfiguration(cfg)
        clearButton.contentTintColor = NSColor.white.withAlphaComponent(0.75)
        clearButton.alphaValue = 0
        clearButton.toolTip = String(localized: "Clear the caption")

        // Recording writes a durable, permanent record — it gets a marker on the
        // one element guaranteed to be on screen.
        recordDot.wantsLayer = true
        recordDot.layer?.backgroundColor = NSColor.systemRed.cgColor
        recordDot.layer?.cornerRadius = 4
        recordDot.isHidden = true

        // The bubble was a VoiceOver dead zone: image views and a bare NSView,
        // no roles, no labels — a subtitle app whose own subtitles and controls
        // a screen reader could not see.
        menuButton.setAccessibilityRole(.button)
        menuButton.setAccessibilityLabel(String(localized: "Open sAiity settings"))
        copyButton.setAccessibilityRole(.button)
        copyButton.setAccessibilityLabel(String(localized: "Copy this caption"))
        clearButton.setAccessibilityRole(.button)
        clearButton.setAccessibilityLabel(String(localized: "Clear the caption"))
        recordDot.setAccessibilityRole(.image)
        recordDot.setAccessibilityLabel(String(localized: "Recording a transcript"))

        // The AX press and the mouse click share the same handlers, so the
        // two input paths cannot drift apart.
        menuButton.onPress = { [weak self] in self?.onOpenWindow?() }
        copyButton.onPress = { [weak self] in
            self?.onCopy?()
            self?.flashCopied()
        }
        clearButton.onPress = { [weak self] in self?.onClear?() }
        for b in [menuButton, copyButton, clearButton] {
            b.onAccessibilityFocus = { [weak self] in self?.setControls(visible: true) }
        }

        for v in [menuButton, copyButton, clearButton, recordDot] {
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
            menuButton.leadingAnchor.constraint(equalTo: leadingAnchor, constant: inset),
            menuButton.centerYAnchor.constraint(equalTo: topAnchor, constant: controlStripHeight / 2),

            recordDot.widthAnchor.constraint(equalToConstant: 8),
            recordDot.heightAnchor.constraint(equalToConstant: 8),
            recordDot.centerYAnchor.constraint(equalTo: menuButton.centerYAnchor),

            copyButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -inset),
            copyButton.centerYAnchor.constraint(equalTo: menuButton.centerYAnchor),

            // Immediately left of Copy, in the same right-hand action cluster.
            clearButton.trailingAnchor.constraint(equalTo: copyButton.leadingAnchor,
                                                  constant: -14),
            clearButton.centerYAnchor.constraint(equalTo: menuButton.centerYAnchor),
        ])

        // While the controls are hidden the dot takes the settings icon's place
        // — centred on it, so it reads as "this is the status here" rather than
        // floating in empty space next to an invisible button. On hover the icon
        // fades in and the dot slides right to make room.
        dotAtIconSpot = recordDot.centerXAnchor.constraint(equalTo: menuButton.centerXAnchor)
        dotBesideIcon = recordDot.leadingAnchor.constraint(equalTo: menuButton.trailingAnchor,
                                                          constant: 9)
        dotAtIconSpot.isActive = true
    }

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
    private var menuRect: NSRect { menuButton.frame.insetBy(dx: -10, dy: -10) }
    private var clearRect: NSRect { clearButton.frame.insetBy(dx: -10, dy: -10) }

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
        } else if copyRect.contains(p) || menuRect.contains(p) || clearRect.contains(p) {
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
        // Swap the dot's constraint inside the same animation group as the fade,
        // so the icon appearing and the dot moving aside read as one gesture.
        dotAtIconSpot.isActive = !visible
        dotBesideIcon.isActive = visible
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.14
            ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            ctx.allowsImplicitAnimation = true
            menuButton.animator().alphaValue = visible ? 1 : 0
            copyButton.animator().alphaValue = visible ? 1 : 0
            clearButton.animator().alphaValue = visible ? 1 : 0
            layoutSubtreeIfNeeded()
        }
    }

    // MARK: - Click / drag

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)

        if copyRect.contains(p) {
            copyButton.onPress?()
            return
        }
        if clearRect.contains(p) {
            clearButton.onPress?()
            return
        }
        if menuRect.contains(p) {
            menuButton.onPress?()
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
    private let label = NSTextField(labelWithString: "")
    private let translationLabel = NSTextField(labelWithString: "")
    private let stack = NSStackView()
    private let glass = NSGlassEffectView()
    private let host = BubbleContentView()

    private var saveWork: DispatchWorkItem?
    private var hasCustomFrame = false
    /// Width chosen by dragging an edge; nil = size to the text.
    private var userWidth: CGFloat?

    var onCopy: (() -> Void)? {
        get { host.onCopy }
        set { host.onCopy = newValue }
    }

    var onOpenWindow: (() -> Void)? {
        get { host.onOpenWindow }
        set { host.onOpenWindow = newValue }
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

        glass.cornerRadius = BubbleContentView.cornerRadius
        // Plain .regular glass measured darkest and most legible of the styles;
        // no tintColor, which washes the text out.
        glass.style = .regular

        // Both lines are configured together, deliberately.
        //
        // They were configured separately, and one line differed: the original
        // got a lowered horizontal compression resistance and the translation
        // did not. An NSTextField at the default priority refuses to be drawn
        // narrower than its text, so instead of wrapping inside the bubble a
        // long translation pushed straight through it — and since the bubble is
        // held against the screen edge, "through the bubble" means off the
        // screen, with the line clipped mid-word. Short lines fit, so it only
        // ever showed up on long translated captions.
        //
        // The two roles differ in font, colour and line count. They must not
        // differ in how they wrap.
        for text in [label, translationLabel] {
            text.alignment = .center
            text.lineBreakMode = .byWordWrapping
            text.cell?.wraps = true
            text.translatesAutoresizingMaskIntoConstraints = false
            text.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            // Wrap to the bubble, never to the text's own preferred width.
            text.preferredMaxLayoutWidth = Self.minWidth - Self.hPadding * 2
        }

        label.font = .systemFont(ofSize: 30, weight: .semibold)
        label.textColor = .white
        label.maximumNumberOfLines = 3

        translationLabel.font = .systemFont(ofSize: 24, weight: .medium)
        translationLabel.textColor = NSColor.systemTeal
        translationLabel.maximumNumberOfLines = 2
        translationLabel.isHidden = true

        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        label.setAccessibilityRole(.staticText)
        label.setAccessibilityLabel(String(localized: "Live caption"))
        translationLabel.setAccessibilityRole(.staticText)
        translationLabel.setAccessibilityLabel(String(localized: "Translation"))
        stack.addArrangedSubview(label)
        stack.addArrangedSubview(translationLabel)

        host.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: host.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: host.trailingAnchor, constant: -24),
            // Leave room for the control strip so hovering never covers the text.
            stack.topAnchor.constraint(equalTo: host.topAnchor, constant: 34),
            stack.bottomAnchor.constraint(equalTo: host.bottomAnchor, constant: -14),
        ])

        // Content must go through `contentView`, not addSubview: only the
        // contentView is clipped by cornerRadius and placed inside the effect.
        glass.contentView = host
        contentView = glass

        contentMinSize = NSSize(width: 280, height: 80)
        restoreFrame()
        applyStyle(CaptionStyle.current)

        // A user-dragged edge sets the bubble's width; from then on text wraps
        // to it instead of the bubble resizing itself around the text.
        NotificationCenter.default.addObserver(
            forName: NSWindow.didEndLiveResizeNotification, object: self,
            queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
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
                MainActor.assumeIsolated { self?.applyStyle(CaptionStyle.current) }
            }
        // Reduce Transparency / Increase Contrast changing mid-session must
        // take effect immediately, like every other style change.
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
            object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.applyStyle(CaptionStyle.current) }
            }
        NotificationCenter.default.addObserver(
            forName: .saiityCaptionPreview, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.showPreview() }
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
        // Deliberately does NOT set userWidth. A saved frame means "this is
        // where it was", not "the user chose this width" — conflating the two
        // meant the automatic width and the screen margin were switched off from
        // the second launch onwards, with no user action at all. The width is
        // restored separately, and only if a real drag stored one.
        userWidth = FrameStore.loadUserWidth().map { min($0, screen.visibleFrame.width) }

        let v = screen.visibleFrame
        let st = CaptionStyle.current
        var f = FrameStore.clamp(saved, into: v)
        // A saved frame records WHERE the bubble was, never how wide it should
        // be. Without a stored user width the width is a setting, so a width
        // left over from a wider display, an older build or a since-changed
        // setting must not survive the restore. Found in the field: 1520pt
        // restored onto a 1710pt screen whose setting asks for 1060, which left
        // 41pt of gap on one side and 149 on the other and honoured the 24pt
        // margin on neither.
        if userWidth == nil {
            f.size.width = BubbleGeometry.autoWidth(visible: v.width,
                                                    fraction: CGFloat(st.widthFraction),
                                                    margin: CGFloat(st.screenMargin))
        }
        // And the margin-aware clamp, not FrameStore's margin-blind one — that
        // one only caps at the screen edge, so it would happily restore a bubble
        // running the full width of the display with no margin at all.
        setFrameInternal(BubbleGeometry.clamp(f, into: v,
                                              margin: CGFloat(st.screenMargin),
                                              respectMargin: userWidth == nil),
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
        userWidth = userWidth.map { min($0, (FrameStore.bestScreen(for: frame)
                                             ?? NSScreen.main)?.visibleFrame.width ?? $0) }
        keepOnScreen()
        sizeToFit(immediateShrink: true)
    }

    private static let hPadding: CGFloat = 24      // each side
    private static let topPadding: CGFloat = 34    // control strip
    private static let bottomPadding: CGFloat = 14
    /// Wide enough that the corner controls never collide with the text.
    private static var minWidth: CGFloat { BubbleGeometry.minWidth }

    private func measure(_ text: String, font: NSFont, width: CGFloat,
                         maxLines: Int = 0) -> NSSize {
        guard !text.isEmpty else { return .zero }
        let r = (text as NSString).boundingRect(
            with: NSSize(width: width, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: font])
        var h = ceil(r.height)
        if maxLines > 0 {
            // maxLines is a growth CAP, and the label truncates at the same
            // number — so measuring past it would size the window for text
            // nobody can see. Text longer than the cap wraps down to that many
            // lines and is elided only beyond it.
            let line = ceil(font.ascender - font.descender + font.leading)
            h = min(h, line * CGFloat(maxLines) + 2)
        }
        return NSSize(width: ceil(r.width), height: h)
    }

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
        if let uw = userWidth {
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
        label.preferredMaxLayoutWidth = contentW
        translationLabel.preferredMaxLayoutWidth = contentW

        // Only the HEIGHT responds to content: text wraps inside a fixed width
        // and the bubble grows upward from its bottom edge.
        var contentH = measure(label.stringValue, font: st.original.font,
                               width: contentW, maxLines: st.original.maxLines).height
        if !translationLabel.isHidden {
            // A space when the row is reserved but empty, so it holds exactly
            // one line rather than collapsing and changing height the moment a
            // translation lands.
            let t = translationLabel.stringValue.isEmpty ? " " : translationLabel.stringValue
            contentH += CGFloat(st.lineGap)
                + measure(t, font: st.translation.font, width: contentW,
                          maxLines: st.translation.maxLines).height
        }
        // Never taller than 40% of the screen, whatever the maths says.
        let targetH = min(max(110, contentH + Self.topPadding + Self.bottomPadding),
                          v.height * 0.4)

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
                || abs(final.origin.y - frame.origin.y) > 0.5 else { return }

        if TestHooks.verboseLogging {
            // The bubble's stillness cannot be seen from a script, so it is
            // logged: x and width must not change between captions.
            NSLog(String(format: "sAiity bubble: x=%.0f y=%.0f w=%.0f h=%.0f screen=%.0f",
                         final.origin.x, final.origin.y, final.width, final.height, v.width))
        }
        setFrameInternal(final)
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
                             respectMargin: userWidth == nil)
    }

    /// Push the persisted look onto the live window. Called on every change so
    /// the settings page is a real preview, not a promise about next launch.
    /// The system accessibility settings the style must defer to. A user who
    /// set Reduce Transparency system-wide has answered the glass question for
    /// every app; the bubble does not get to overrule that.
    private var effectiveStyle: CaptionStyle {
        var st = CaptionStyle.current
        let a11y = NSWorkspace.shared
        if a11y.accessibilityDisplayShouldReduceTransparency, st.glassStyle != 2 {
            st.glassStyle = 2   // solid
        }
        if a11y.accessibilityDisplayShouldIncreaseContrast {
            st.glassStyle = 2
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
        // Every visual property comes from the struct. Nothing is hardcoded
        // here any more: the original used to be fixed white/semibold and the
        // translation fixed teal/medium, so half the style fields were read but
        // could never be changed and the rest were not read at all.
        label.font = st.original.font
        label.textColor = st.original.color
        label.maximumNumberOfLines = st.original.maxLines
        translationLabel.font = st.translation.font
        translationLabel.textColor = st.translation.color
        translationLabel.maximumNumberOfLines = st.translation.maxLines
        translationLabel.alphaValue = st.translation.opacity
        stack.spacing = CGFloat(st.lineGap)

        glass.cornerRadius = st.cornerRadius
        switch st.glassStyle {
        case 1: glass.style = .clear
        default: glass.style = .regular
        }
        // "Solid" is the legibility answer for bright video, where even regular
        // glass leaves white-on-white at roughly 2:1 contrast. NSGlassEffectView
        // has no opaque mode, so it is a near-black layer behind the content.
        if st.glassStyle == 2 {
            glass.tintColor = st.tintColor ?? NSColor(white: 0.06, alpha: 1)
        } else {
            glass.tintColor = st.tintColor
        }
        // Both directions. Only the hide half existed, so un-hiding — which
        // now has its own global hot key — did nothing visible until the next
        // caption chunk happened to arrive, which during a pause in speech
        // reads as a broken shortcut.
        if st.hidden {
            orderOut(nil)
        } else if !label.stringValue.isEmpty, !isVisible {
            orderFrontRegardless()
        }
        sizeToFit(immediateShrink: true)
    }

    /// Show sample text so legibility can be judged without waiting for someone
    /// to speak.
    func showPreview() {
        let st = CaptionStyle.current
        show(text: CaptionStyle.sampleOriginal, isFinal: true)
        showTranslation(st.showTranslation ? CaptionStyle.sampleTranslation : "")
        orderFrontRegardless()
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
    func show(text: String, isFinal: Bool) {
        label.stringValue = text
        // effectiveStyle, not CaptionStyle.current: captions update several
        // times a second, and reading the raw style here dropped the
        // accessibility adjustments applyStyle had just made — Increase
        // Contrast survived only until the next caption arrived.
        let st = effectiveStyle
        label.alphaValue = isFinal ? st.original.opacity : st.original.volatileOpacity
        sizeToFit()
        guard !st.hidden else { orderOut(nil); return }
        if !text.isEmpty, !isVisible { orderFrontRegardless() }
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
        translationLabel.stringValue = text
        translationLabel.isHidden = text.isEmpty && !reservesTranslationRow
        translationLabel.alphaValue = effectiveStyle.translation.opacity * (stale ? staleDim : 1)
        sizeToFit()
    }

    /// The source moved on while this translation stayed. Same dimming as
    /// `showTranslation(stale: true)` without re-setting the text.
    func markTranslationStale() {
        guard !translationLabel.stringValue.isEmpty else { return }
        translationLabel.alphaValue = effectiveStyle.translation.opacity * staleDim
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
            if reservesTranslationRow {
                translationLabel.isHidden = false
            } else if translationLabel.stringValue.isEmpty {
                translationLabel.isHidden = true
            }
            sizeToFit(immediateShrink: true)
        }
    }

    func clear() {
        label.stringValue = ""
        translationLabel.stringValue = ""
        translationLabel.isHidden = true
        orderOut(nil)
    }
}
