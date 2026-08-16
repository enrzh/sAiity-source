import AppKit

@MainActor
final class DictationToastWindow: NSPanel {
    private let label = NSTextField(labelWithString: "")
    private let spinner = NSProgressIndicator()

    override init(contentRect: NSRect, styleMask: NSWindow.StyleMask, backing: NSWindow.BackingStoreType, defer flag: Bool) {
        super.init(contentRect: contentRect, styleMask: styleMask, backing: backing, defer: flag)
        isFloatingPanel = true
        level = .statusBar
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        ignoresMouseEvents = true

        let effect = NSVisualEffectView()
        effect.material = .hudWindow
        effect.state = .active
        effect.blendingMode = .behindWindow
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 12
        effect.layer?.masksToBounds = true

        label.font = .systemFont(ofSize: 13, weight: .medium)
        label.textColor = .labelColor
        label.alignment = .center
        label.lineBreakMode = .byTruncatingTail

        spinner.style = .spinning
        spinner.controlSize = .small

        let stack = NSStackView(views: [spinner, label])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 9, left: 14, bottom: 9, right: 14)
        effect.addSubview(stack)
        stack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: effect.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: effect.trailingAnchor),
            stack.topAnchor.constraint(equalTo: effect.topAnchor),
            stack.bottomAnchor.constraint(equalTo: effect.bottomAnchor),
            label.widthAnchor.constraint(greaterThanOrEqualToConstant: 86),
        ])
        contentView = effect
    }

    func show(text: String, animated: Bool) {
        label.stringValue = text
        spinner.isHidden = !animated
        animated ? spinner.startAnimation(nil) : spinner.stopAnimation(nil)
        let size = contentView?.fittingSize ?? NSSize(width: 150, height: 34)
        setContentSize(NSSize(width: max(150, size.width), height: 36))
        if !isVisible {
            orderFrontRegardless()
        }
    }

    func dismiss() {
        spinner.stopAnimation(nil)
        orderOut(nil)
    }
}
