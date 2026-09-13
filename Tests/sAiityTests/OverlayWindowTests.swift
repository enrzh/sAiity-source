import AppKit
import Testing

@testable import sAiity

@MainActor
@Suite struct OverlayWindowTests {
    @Test("Liquid Glass is applied to the subtitle bubble")
    func liquidGlassStyle() {
        let defaults = UserDefaults.standard
        let previous = defaults.data(forKey: CaptionStyle.key)
        defer {
            if let previous { defaults.set(previous, forKey: CaptionStyle.key) }
            else { defaults.removeObject(forKey: CaptionStyle.key) }
        }

        var style = CaptionStyle.current
        style.glassStyle = CaptionStyle.liquidGlass
        CaptionStyle.current = style
        let window = OverlayWindow()
        #expect(window.renderedBubbleStyleForTests == CaptionStyle.liquidGlass)
        #expect(window.usesLiquidGlassForTests)
        window.orderOut(nil)
    }

    @Test("explicitly revealing the subtitle bubble works before the first caption")
    func revealBeforeFirstCaption() {
        let defaults = UserDefaults.standard
        let styleKey = CaptionStyle.key
        let previousStyle = defaults.data(forKey: styleKey)
        var style = CaptionStyle.current
        style.hidden = false
        CaptionStyle.current = style
        defer {
            if let previousStyle {
                defaults.set(previousStyle, forKey: styleKey)
            } else {
                defaults.removeObject(forKey: styleKey)
            }
        }

        let window = OverlayWindow()
        window.reveal()

        #expect(window.isVisible)
        window.orderOut(nil)
    }

    @Test("subtitle bubble presents its first caption without a layout crash")
    func firstCaptionPresentation() {
        let defaults = UserDefaults.standard
        let styleKey = CaptionStyle.key
        let previousStyle = defaults.data(forKey: styleKey)
        let style = CaptionStyle.current

        defer {
            if let previousStyle {
                defaults.set(previousStyle, forKey: styleKey)
            } else {
                defaults.removeObject(forKey: styleKey)
            }
        }

        var visibleStyle = style
        visibleStyle.hidden = false
        visibleStyle.maxHeight = max(120, visibleStyle.maxHeight)
        CaptionStyle.current = visibleStyle

        let window = OverlayWindow()
        window.show(text: "Ich denke we should ship this today.",
                    isFinal: true,
                    sentenceID: 1)
        window.showTranslation("Ich denke, wir sollten das heute versenden.",
                               forSentenceID: 1)

        #expect(window.isVisible)
        #expect(window.frame.width >= BubbleGeometry.minWidth)
        #expect(window.frame.height >= 110)

        window.clearHistory(keepVisible: true)
        #expect(window.isVisible)
        window.orderOut(nil)
    }
}
