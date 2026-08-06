import AppKit

/// Where the caption bubble goes, as pure arithmetic.
///
/// Pulled out of `OverlayWindow` so it can be tested without a window, a screen
/// or a running app. It is worth testing: every version of the "bubble moves"
/// bug has come down to a few lines of clamping, and the symptom on screen —
/// "it drifted left" — is several steps removed from the arithmetic that caused
/// it. The failure signature to watch for is a width exactly equal to the
/// screen's, which means the margin was bypassed and the clamp then has only one
/// legal x: hard against the left edge.
enum BubbleGeometry {

    /// Wide enough that the corner controls never collide with the text.
    static let minWidth: CGFloat = 420

    /// The automatic width: a fraction of the screen, always leaving the margin
    /// on both sides.
    static func autoWidth(visible: CGFloat, fraction: CGFloat, margin: CGFloat) -> CGFloat {
        let m = max(0, margin)
        let usable = max(minWidth, visible - m * 2)
        return min(max(fraction * visible, minWidth), usable)
    }

    /// A width the user chose by dragging. Honoured up to the full screen — "pull
    /// it to full width" has to stick — but never beyond it.
    static func draggedWidth(_ chosen: CGFloat, visible: CGFloat) -> CGFloat {
        min(max(chosen, minWidth), visible)
    }

    /// Fit a frame to the screen while keeping its BOTTOM edge where it is.
    ///
    /// The generic clamp pushed the whole window down when growth took its top
    /// past the screen, which reads as a jump; here the height is trimmed
    /// instead. `respectMargin` is false only for a width the user dragged, who
    /// may legitimately want the bubble edge to edge.
    static func clamp(_ rect: NSRect, into visible: NSRect,
                      margin: CGFloat, respectMargin: Bool) -> NSRect {
        var f = rect
        let side = respectMargin ? max(0, margin) : 0
        f.size.width = min(f.width, visible.width - side * 2)
        // Guard the degenerate case rather than trusting it cannot happen: if the
        // width ever did equal the usable span, `min(max(…))` collapses to a
        // single legal x and the bubble sits hard against one edge. Centring is a
        // far better answer than pinning.
        let lower = visible.minX + side
        let upper = visible.maxX - f.width - side
        f.origin.x = upper <= lower ? visible.midX - f.width / 2
                                    : min(max(f.minX, lower), upper)
        f.origin.y = max(f.minY, visible.minY)
        if f.maxY > visible.maxY { f.size.height = visible.maxY - f.minY }
        return f
    }
}
