import AppKit

/// Shared background surface for the two floating bubbles.
///
/// Liquid Glass owns its content through `contentView`; keeping that contract
/// explicit avoids the hierarchy churn that previously made the native view
/// unstable on macOS 27. The older AppKit surface remains the fallback for the
/// existing styles and accessibility settings.
@MainActor
final class BubbleSurfaceView: NSView {
    private let content: NSView
    private let visual = NSVisualEffectView()
    private let liquid = NSGlassEffectView()
    private(set) var renderedStyle = CaptionStyle.regularGlass

    init(contentView: NSView) {
        content = contentView
        super.init(frame: .zero)

        autoresizingMask = [.width, .height]
        visual.wantsLayer = true
        visual.autoresizingMask = [.width, .height]
        liquid.autoresizingMask = [.width, .height]
        addSubview(visual)
        addSubview(liquid)
        visual.frame = bounds
        liquid.frame = bounds
        liquid.isHidden = true
        apply(style: CaptionStyle())
    }

    required init?(coder: NSCoder) { fatalError() }

    func apply(style: CaptionStyle, forceSolid: Bool = false) {
        let requested = forceSolid ? CaptionStyle.solidGlass : style.glassStyle
        let next = [CaptionStyle.regularGlass, CaptionStyle.clearGlass,
                    CaptionStyle.solidGlass, CaptionStyle.liquidGlass].contains(requested)
            ? requested : CaptionStyle.regularGlass
        renderedStyle = next

        visual.layer?.cornerRadius = style.cornerRadius
        visual.layer?.masksToBounds = true
        visual.blendingMode = .behindWindow
        visual.state = .active

        if next == CaptionStyle.liquidGlass {
            content.translatesAutoresizingMaskIntoConstraints = true
            if liquid.contentView !== content {
                // NSGlassEffectView owns the handoff between its content view
                // and the previous superview. Removing the view first can
                // leave the native glass hierarchy without drawable content
                // until a later style change.
                liquid.contentView = content
            }
            // AppKit does not guarantee a non-zero frame when a content view
            // is first handed to NSGlassEffectView. Keep the host sized with
            // the glass surface so its controls remain drawable immediately.
            content.frame = liquid.bounds
            content.autoresizingMask = [.width, .height]
            liquid.cornerRadius = style.cornerRadius
            liquid.style = .regular
            liquid.tintColor = style.tintColor
            visual.isHidden = true
            liquid.isHidden = false
            return
        }

        liquid.contentView = nil
        if content.superview !== visual {
            content.translatesAutoresizingMaskIntoConstraints = true
            visual.addSubview(content)
            content.frame = visual.bounds
            content.autoresizingMask = [.width, .height]
        }

        switch next {
        case CaptionStyle.clearGlass:
            visual.material = .underWindowBackground
            visual.layer?.backgroundColor = NSColor.clear.cgColor
        case CaptionStyle.solidGlass:
            visual.material = .hudWindow
            visual.layer?.backgroundColor = (style.tintColor
                                              ?? NSColor(white: 0.06, alpha: 1)).cgColor
        default:
            visual.material = .hudWindow
            visual.layer?.backgroundColor = NSColor.clear.cgColor
        }
        visual.isHidden = false
        liquid.isHidden = true
    }

#if SAIITY_TEST_HOOKS
    var usesLiquidGlassForTests: Bool { !liquid.isHidden }
    var contentAttachedForTests: Bool {
        guard content.frame.width > 0, content.frame.height > 0 else { return false }
        var view: NSView? = content
        while let current = view {
            if current.isHidden { return false }
            if current === self { return true }
            view = current.superview
        }
        return false
    }
#endif
}
