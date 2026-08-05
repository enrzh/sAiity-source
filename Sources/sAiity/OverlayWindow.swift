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

    /// The screen the saved frame overlaps most; if it overlaps none, that
    /// display is gone and we fall back to the primary.
    static func bestScreen(for frame: NSRect) -> NSScreen? {
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
    private let menuButton = NSImageView()
    private let copyButton = NSImageView()
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
                                   accessibilityDescription: "Open sAiity")?
            .withSymbolConfiguration(cfg)
        menuButton.contentTintColor = NSColor.white.withAlphaComponent(0.75)
        menuButton.alphaValue = 0
        menuButton.toolTip = "Open sAiity"

        copyButton.image = NSImage(systemSymbolName: "doc.on.doc",
                                   accessibilityDescription: "Copy caption")?
            .withSymbolConfiguration(cfg)
        copyButton.contentTintColor = NSColor.white.withAlphaComponent(0.75)
        copyButton.alphaValue = 0
        copyButton.toolTip = "Copy this line"

        // Recording writes a durable, permanent record — it gets a marker on the
        // one element guaranteed to be on screen.
        recordDot.wantsLayer = true
        recordDot.layer?.backgroundColor = NSColor.systemRed.cgColor
        recordDot.layer?.cornerRadius = 4
        recordDot.isHidden = true

        for v in [menuButton, copyButton, recordDot] {
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
            recordDot.leadingAnchor.constraint(equalTo: menuButton.trailingAnchor, constant: 9),
            recordDot.centerYAnchor.constraint(equalTo: menuButton.centerYAnchor),

            copyButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -inset),
            copyButton.centerYAnchor.constraint(equalTo: menuButton.centerYAnchor),
        ])
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
        let interactive = dragRegion.insetBy(dx: -armSlack, dy: -armSlack).contains(p)
        if window?.ignoresMouseEvents != !interactive {
            window?.ignoresMouseEvents = !interactive
        }
        // An open hand over the strip is a far better "you can move this" hint
        // than a glyph that looks clickable but is not.
        guard interactive else { return }
        if copyRect.contains(p) || menuRect.contains(p) {
            NSCursor.arrow.set()
        } else {
            NSCursor.openHand.set()
        }
    }

    private func setControls(visible: Bool) {
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.14
            menuButton.animator().alphaValue = visible ? 1 : 0
            copyButton.animator().alphaValue = visible ? 1 : 0
        }
    }

    // MARK: - Click / drag

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)

        if copyRect.contains(p) {
            onCopy?()
            flashCopied()
            return
        }
        if menuRect.contains(p) {
            onOpenWindow?()
            return
        }
        guard dragRegion.insetBy(dx: -armSlack, dy: -armSlack).contains(p) else { return }
        // Near an edge the system's resize machinery owns the gesture; starting
        // a window drag there would make the bubble un-resizable.
        let edge: CGFloat = 8
        if p.x < edge || p.x > bounds.maxX - edge || p.y < edge || p.y > bounds.maxY - edge {
            super.mouseDown(with: event)
            return
        }
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
                                   accessibilityDescription: "Copied")?
            .withSymbolConfiguration(cfg)
        copyButton.contentTintColor = NSColor.systemGreen
        let w = DispatchWorkItem { [weak self] in
            self?.copyButton.image = NSImage(systemSymbolName: "doc.on.doc",
                                             accessibilityDescription: "Copy caption")?
                .withSymbolConfiguration(cfg)
            self?.copyButton.contentTintColor = NSColor.white.withAlphaComponent(0.75)
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

        label.font = .systemFont(ofSize: 30, weight: .semibold)
        label.textColor = .white
        label.alignment = .center
        label.lineBreakMode = .byWordWrapping
        label.maximumNumberOfLines = 3
        label.cell?.wraps = true
        label.translatesAutoresizingMaskIntoConstraints = false
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        translationLabel.font = .systemFont(ofSize: 24, weight: .medium)
        translationLabel.textColor = NSColor.systemTeal
        translationLabel.alignment = .center
        translationLabel.lineBreakMode = .byWordWrapping
        translationLabel.maximumNumberOfLines = 2
        translationLabel.cell?.wraps = true
        translationLabel.isHidden = true
        translationLabel.translatesAutoresizingMaskIntoConstraints = false

        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
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
                    self.userWidth = self.frame.width
                    self.hasCustomFrame = true
                    FrameStore.save(self.frame)
                    self.sizeToFit()
                }
            }

        NotificationCenter.default.addObserver(
            forName: .saiityCaptionStyleChanged, object: nil, queue: .main) { [weak self] _ in
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

    private func restoreFrame() {
        guard let saved = FrameStore.load(),
              let screen = FrameStore.bestScreen(for: saved) else {
            if let s = NSScreen.main { setFrame(defaultFrame(on: s), display: false) }
            return
        }
        hasCustomFrame = true
        userWidth = saved.width
        setFrame(FrameStore.clamp(saved, into: screen.visibleFrame), display: false)
    }

    @objc private func frameMoved() {
        hasCustomFrame = true
        // Coalesce the flood of move notifications during a drag.
        saveWork?.cancel()
        let w = DispatchWorkItem { [weak self] in
            guard let self else { return }
            FrameStore.save(self.frame)
        }
        saveWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: w)
    }

    @objc private func screensChanged() {
        guard let screen = FrameStore.bestScreen(for: frame) else { return }
        setFrame(FrameStore.clamp(frame, into: screen.visibleFrame), display: true)
    }

    private static let hPadding: CGFloat = 24      // each side
    private static let topPadding: CGFloat = 34    // control strip
    private static let bottomPadding: CGFloat = 14
    /// Wide enough that the corner controls never collide with the text.
    private static let minWidth: CGFloat = 420
    /// How much the natural width must change before the window is resized.
    /// Below this the bubble visibly breathes as each word arrives.
    private static let resizeSlack: CGFloat = 28

    private func measure(_ text: String, font: NSFont, width: CGFloat,
                         maxLines: Int = 0) -> NSSize {
        guard !text.isEmpty else { return .zero }
        let r = (text as NSString).boundingRect(
            with: NSSize(width: width, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: font])
        var h = ceil(r.height)
        if maxLines > 0 {
            // The label truncates at maxLines; measuring past that sized the
            // window for text nobody sees — the "bubble takes over the whole
            // screen" bug when a translation ran long.
            let line = ceil(font.ascender - font.descender + font.leading)
            h = min(h, line * CGFloat(maxLines) + 2)
        }
        return NSSize(width: ceil(r.width), height: h)
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
    /// Gated on an actual size change: glass costs more per resize than a
    /// visual-effect view, and captions update several times a second.
    private func sizeToFit() {
        guard let screen = FrameStore.bestScreen(for: frame) ?? NSScreen.main else { return }
        let v = screen.visibleFrame
        let maxWidth = min(1100, v.width - 120)
        let unwrapped = CGFloat.greatestFiniteMagnitude

        var natural = measure(label.stringValue, font: label.font ?? .systemFont(ofSize: 30),
                              width: unwrapped).width
        if !translationLabel.isHidden {
            natural = max(natural, measure(translationLabel.stringValue,
                                           font: translationLabel.font ?? .systemFont(ofSize: 24),
                                           width: unwrapped).width)
        }
        var targetW = min(max(natural + Self.hPadding * 2, Self.minWidth), maxWidth)
        if let uw = userWidth {
            // The user chose a width by dragging an edge; keep it.
            targetW = min(max(uw, 280), maxWidth)
        }

        let st = CaptionStyle.current
        let contentW = targetW - Self.hPadding * 2
        var contentH = measure(label.stringValue, font: label.font ?? .systemFont(ofSize: 30),
                               width: contentW, maxLines: st.maxLines).height
        if !translationLabel.isHidden {
            // Measure a space when the row is reserved but empty, so it holds
            // exactly one line rather than collapsing to nothing.
            let t = translationLabel.stringValue.isEmpty ? " " : translationLabel.stringValue
            contentH += stack.spacing + measure(t,
                                                font: translationLabel.font ?? .systemFont(ofSize: 24),
                                                width: contentW,
                                                maxLines: translationLabel.maximumNumberOfLines).height
        }
        // Belt and braces: never more than 40% of the screen, whatever the maths.
        let targetH = min(max(110, contentH + Self.topPadding + Self.bottomPadding),
                          v.height * 0.4)

        // Hysteresis. Every partial result changes the text, and at a 0.5pt
        // threshold the window re-laid-out on essentially every frame, which
        // reads as the bubble twitching rather than the caption updating.
        let widthChanged = abs(targetW - frame.width) > Self.resizeSlack
        let heightChanged = abs(targetH - frame.height) > 1
        guard widthChanged || heightChanged else { return }
        // Never shrink the width for a momentarily shorter line — only grow, or
        // shrink when it is a real difference. Otherwise the edges breathe in
        // and out with each word.
        if !widthChanged { targetW = frame.width }

        var f = frame
        f.origin.x = frame.midX - targetW / 2      // grow symmetrically
        // Anchor the BOTTOM edge, so the bubble grows upward.
        //
        // It used to pin the top and grow down, which is wrong for something
        // that sits near the bottom of the screen: adding the translation row
        // pushed it past the screen edge, `clamp` shoved it back up, and the
        // whole bubble appeared to jump every time a translation arrived.
        f.size = NSSize(width: targetW, height: targetH)
        if !hasCustomFrame {
            f.origin.x = v.midX - targetW / 2
            f.origin.y = v.minY + 90
        }
        setFrame(FrameStore.clamp(f, into: v), display: true)
    }

    /// Push the persisted look onto the live window. Called on every change so
    /// the settings page is a real preview, not a promise about next launch.
    func applyStyle(_ st: CaptionStyle) {
        label.font = .systemFont(ofSize: st.fontSize, weight: .semibold)
        label.maximumNumberOfLines = st.maxLines
        translationLabel.font = .systemFont(ofSize: st.translationFontSize, weight: .medium)
        glass.cornerRadius = st.cornerRadius
        glass.style = st.glassStyle == 1 ? .clear : .regular
        glass.tintColor = st.tintColor
        if st.hidden { orderOut(nil) }
        sizeToFit()
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
        UserDefaults.standard.removeObject(forKey: "captionFrame")
        guard let screen = NSScreen.main else { return }
        let v = screen.visibleFrame
        setFrame(NSRect(x: v.midX - frame.width / 2, y: v.minY + 90,
                        width: frame.width, height: frame.height), display: true)
    }

    // MARK: - Content

    /// `text` is shown dimmed while volatile so it is visually obvious the
    /// engine may still revise it.
    func show(text: String, isFinal: Bool) {
        label.stringValue = text
        let st = CaptionStyle.current
        label.alphaValue = isFinal ? st.textOpacity : st.volatileOpacity
        sizeToFit()
        guard !CaptionStyle.current.hidden else { orderOut(nil); return }
        if !text.isEmpty, !isVisible { orderFrontRegardless() }
    }

    /// Shown under the original line.
    ///
    /// While translation is switched on the row keeps its height even when it is
    /// empty — see `reservesTranslationRow`.
    func showTranslation(_ text: String) {
        translationLabel.stringValue = text
        translationLabel.isHidden = text.isEmpty && !reservesTranslationRow
        sizeToFit()
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
            sizeToFit()
        }
    }

    func clear() {
        label.stringValue = ""
        translationLabel.stringValue = ""
        translationLabel.isHidden = true
        orderOut(nil)
    }
}
