import AppKit
import Foundation
import Testing

@testable import sAiity

/// The caption bubble drifting left has been reported three times and "fixed"
/// twice. Both times the arithmetic was several steps removed from the symptom,
/// so these pin the arithmetic itself.
struct BubbleGeometryTests {

    /// A typical laptop panel, matching the display the bug was seen on.
    private let screen = NSRect(x: 0, y: 0, width: 1710, height: 1067)

    @Test("The automatic width always leaves the margin on both sides")
    func autoWidthRespectsMargin() {
        // THE failure signature: a width exactly equal to the screen's. When
        // that happens the clamp has only one legal x — hard against the left
        // edge — which is what "the bubble drifts left" actually was.
        for margin in [0.0, 12.0, 24.0, 80.0] as [CGFloat] {
            for fraction in [0.3, 0.62, 0.9, 1.0] as [CGFloat] {
                let w = BubbleGeometry.autoWidth(visible: screen.width,
                                                 fraction: fraction, margin: margin)
                #expect(w <= screen.width - margin * 2 || w == BubbleGeometry.minWidth,
                        "fraction \(fraction) margin \(margin) produced \(w) of \(screen.width)")
            }
        }
    }

    @Test("An automatically sized bubble is never pinned to an edge")
    func autoWidthIsCentredWithRoomEitherSide() {
        let margin: CGFloat = 24
        let w = BubbleGeometry.autoWidth(visible: screen.width, fraction: 0.62, margin: margin)
        let f = BubbleGeometry.clamp(NSRect(x: 400, y: 97, width: w, height: 110),
                                     into: screen, margin: margin, respectMargin: true)
        #expect(f.minX >= margin, "left edge at \(f.minX), margin is \(margin)")
        #expect(f.maxX <= screen.width - margin, "right edge at \(f.maxX)")
        #expect(f.minX != 0, "pinned to the left edge — the exact reported bug")
    }

    @Test("A frame already inside the screen is left exactly where it is")
    func inBoundsIsIdentity() {
        // If this moved anything, every caption would nudge the bubble.
        let f = NSRect(x: 300, y: 97, width: 1000, height: 119)
        let out = BubbleGeometry.clamp(f, into: screen, margin: 24, respectMargin: true)
        #expect(out == f)
    }

    @Test("Clamping is idempotent")
    func clampIsStable() {
        // Applied on every layout, so a second pass that moved the frame again
        // would drift by that amount per caption.
        let start = NSRect(x: -200, y: -50, width: 2000, height: 400)
        let once = BubbleGeometry.clamp(start, into: screen, margin: 24, respectMargin: true)
        let twice = BubbleGeometry.clamp(once, into: screen, margin: 24, respectMargin: true)
        #expect(once == twice, "\(once) then \(twice)")
    }

    @Test("A bubble as wide as the screen is centred, not pinned")
    func degenerateWidthIsCentredNotPinned() {
        // The collapse: width == usable span leaves min(max(x, lower), upper)
        // with upper <= lower, so every x resolves to the lower bound. It used
        // to slam the bubble against the left edge on every single caption.
        let f = BubbleGeometry.clamp(NSRect(x: 500, y: 97, width: screen.width, height: 110),
                                     into: screen, margin: 24, respectMargin: true)
        #expect(f.minX >= 0)
        #expect(abs(f.midX - screen.midX) < 1, "not centred: midX \(f.midX) vs \(screen.midX)")
    }

    @Test("A dragged full-screen width sticks")
    func draggedWidthIsHonoured() {
        // "If the user pulls the bubble to full width that is okay" — but never
        // past the screen.
        #expect(BubbleGeometry.draggedWidth(screen.width, visible: screen.width) == screen.width)
        #expect(BubbleGeometry.draggedWidth(9000, visible: screen.width) == screen.width)
        #expect(BubbleGeometry.draggedWidth(10, visible: screen.width) == BubbleGeometry.minWidth)

        let f = BubbleGeometry.clamp(NSRect(x: 0, y: 97, width: screen.width, height: 110),
                                     into: screen, margin: 24, respectMargin: false)
        #expect(f.width == screen.width, "a dragged full width was shrunk")
        #expect(f.minX == 0)
    }

    @Test("Growth trims the height rather than sliding the bubble down")
    func bottomEdgeIsAnchored() {
        let tall = NSRect(x: 300, y: 900, width: 1000, height: 400)   // top past the screen
        let f = BubbleGeometry.clamp(tall, into: screen, margin: 24, respectMargin: true)
        #expect(f.minY == tall.minY, "the base moved from \(tall.minY) to \(f.minY)")
        #expect(f.maxY <= screen.maxY)
    }

    @Test("Nothing ever ends up off screen")
    func alwaysContained() {
        let awkward = [
            NSRect(x: -900, y: -400, width: 3000, height: 2000),
            NSRect(x: 1700, y: 1000, width: 800, height: 300),
            NSRect(x: 0, y: 0, width: 1, height: 1),
        ]
        for r in awkward {
            for respect in [true, false] {
                let f = BubbleGeometry.clamp(r, into: screen, margin: 24, respectMargin: respect)
                #expect(f.minX >= screen.minX - 0.5, "\(r) → \(f) hangs off the left")
                #expect(f.maxX <= screen.maxX + 0.5, "\(r) → \(f) hangs off the right")
                #expect(f.minY >= screen.minY - 0.5, "\(r) → \(f) hangs off the bottom")
                #expect(f.maxY <= screen.maxY + 0.5, "\(r) → \(f) hangs off the top")
            }
        }
    }
}

/// A saved frame records where the bubble was, not how wide it should be.
///
/// From the field: `captionFrame` held 1520pt on a 1710pt screen whose settings
/// ask for 1060, restored verbatim because the restore path used a margin-blind
/// clamp. The bubble came back nearly edge to edge — 41pt of gap on one side,
/// 149 on the other, and the 24pt margin honoured on neither.
@Suite struct RestoredWidthTests {

    private static let screen = NSRect(x: 0, y: 0, width: 1710, height: 1011)

    @Test("A stale saved width does not survive a restore")
    func staleWidthIsReplacedBySetting() {
        let saved = NSRect(x: 41, y: 290, width: 1520, height: 149)
        // What restoreFrame now does when no user width was ever stored.
        let want = BubbleGeometry.autoWidth(visible: Self.screen.width,
                                            fraction: 0.62, margin: 24)
        #expect(want == 1060.2, "the setting's width, not the saved one")

        var f = saved
        f.size.width = want
        let final = BubbleGeometry.clamp(f, into: Self.screen, margin: 24, respectMargin: true)

        #expect(final.width == want)
        #expect(final.minX >= Self.screen.minX + 24, "left margin honoured")
        #expect(final.maxX <= Self.screen.maxX - 24, "right margin honoured")
    }

    @Test("A width the user really chose still survives, edge to edge")
    func userChosenWidthSurvives() {
        // Dragging the bubble to full width has to stick, so this path skips the
        // margin deliberately — but never leaves the screen.
        let w = BubbleGeometry.draggedWidth(3000, visible: Self.screen.width)
        #expect(w == Self.screen.width)
        let f = BubbleGeometry.clamp(NSRect(x: 900, y: 90, width: w, height: 149),
                                     into: Self.screen, margin: 24, respectMargin: false)
        #expect(f.minX >= Self.screen.minX)
        #expect(f.maxX <= Self.screen.maxX, "even a dragged width stays on screen")
    }

    @Test("Any saved frame, however wrong, lands fully on screen")
    func absurdSavedFramesAreContained() {
        for saved in [NSRect(x: -800, y: 10, width: 4000, height: 200),
                      NSRect(x: 1690, y: 10, width: 1520, height: 200),
                      NSRect(x: 41, y: 290, width: 1520, height: 149)] {
            var f = FrameStoreClampShim.clamp(saved, into: Self.screen)
            f.size.width = BubbleGeometry.autoWidth(visible: Self.screen.width,
                                                    fraction: 0.62, margin: 24)
            let final = BubbleGeometry.clamp(f, into: Self.screen, margin: 24, respectMargin: true)
            #expect(final.minX >= Self.screen.minX, "\(saved) left off screen")
            #expect(final.maxX <= Self.screen.maxX, "\(saved) right off screen")
        }
    }
}

/// Mirrors FrameStore.clamp, which is nested inside OverlayWindow and not
/// reachable from here. Kept identical on purpose: if the real one changes and
/// this does not, the test above stops describing the shipped behaviour.
enum FrameStoreClampShim {
    static func clamp(_ saved: NSRect, into visible: NSRect) -> NSRect {
        var f = saved
        f.size.width = min(f.width, visible.width)
        f.size.height = min(f.height, visible.height)
        f.origin.x = min(max(f.minX, visible.minX), visible.maxX - f.width)
        f.origin.y = min(max(f.minY, visible.minY), visible.maxY - f.height)
        return f
    }
}
