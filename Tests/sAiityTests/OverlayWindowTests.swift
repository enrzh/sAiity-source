import AppKit
import Testing

@testable import sAiity

@MainActor
@Suite struct OverlayWindowTests {
    @Test("a visible caption update performs one history layout and no window reordering")
    func captionUpdatesAvoidRepeatedLayoutAndPresentation() {
        let previous = CaptionStyle.current
        var style = previous
        style.hidden = false
        CaptionStyle.current = style
        let window = OverlayWindow()
        defer { window.orderOut(nil); CaptionStyle.current = previous }
        window.showHistory((0..<40).map { CaptionHistoryEntry(sentenceID: $0, original: "Synthetic caption \($0).") })
        let layouts = window.historyLayoutPassesForTests
        let presentations = window.presentationRequestsForTests
        let began = ContinuousClock.now
        for index in 0..<200 { window.show(text: "Synthetic caption updated \(index).", isFinal: true, sentenceID: 39) }
        #expect(window.historyLayoutPassesForTests - layouts == 200)
        #expect(window.presentationRequestsForTests == presentations)
        #expect(window.historyEntriesForTests.count == 40)
        #expect(window.historyEntriesForTests.last?.original == "Synthetic caption updated 199.")
        print("SYLLIVRA_PERF bubble updates=200 rows=40 layouts=\(window.historyLayoutPassesForTests - layouts) presentations=\(window.presentationRequestsForTests - presentations) elapsed=\(began.duration(to: .now))")
    }

    @Test("the shared bubble surface changes background material without fading its content")
    func backgroundTransparencyToggleKeepsContent() {
        let frame = NSRect(x: 0, y: 0, width: 320, height: 110)
        let content = NSView(frame: frame)
        let surface = BubbleSurfaceView(contentView: content)
        surface.frame = frame
        var style = CaptionStyle()
        style.backgroundIsTransparent = false
        surface.apply(style: style)
        #expect(surface.renderedStyle == CaptionStyle.solidGlass)
        #expect(surface.contentAttachedForTests)
        #expect(content.alphaValue == 1)
        style.backgroundIsTransparent = true
        surface.apply(style: style)
        #expect(surface.renderedStyle == CaptionStyle.regularGlass)
        #expect(surface.contentAttachedForTests)
        surface.apply(style: style, forceSolid: true)
        #expect(surface.renderedStyle == CaptionStyle.solidGlass)
        #expect(content.alphaValue == 1)
    }

    @Test("the saved caption confirmation opens its transcript and pending status does not")
    func saveConfirmationOpensTranscript() throws {
        let view = BubbleContentView(frame: .init(x: 0, y: 0, width: 500, height: 110))
        var opened = 0
        view.showTranscriptSaveStatus(String(localized: "Saved to Transcripts")) { opened += 1 }
        let button = try #require(view.subviews.compactMap { $0 as? NSButton }.first)
        #expect(!button.isHidden && button.isEnabled)
        #expect(button.toolTip == String(localized: "Open transcript"))
        button.performClick(nil)
        #expect(opened == 1)
        view.showTranscriptSaveStatus(String(localized: "Saving transcript…"))
        #expect(!button.isEnabled)
        button.performClick(nil)
        #expect(opened == 1)
    }

    @Test("reading history survives incoming captions and translation until Jump to latest")
    func readerControlsScrolling() async throws {
        let previous = CaptionStyle.current
        var style = previous
        style.hidden = false
        style.maxHeight = 180
        CaptionStyle.current = style
        defer { CaptionStyle.current = previous }
        let window = OverlayWindow()
        window.showHistory((0..<30).map {
            CaptionHistoryEntry(sentenceID: $0, original: "Earlier caption number \($0).")
        })
        window.jumpToLatest()
        try #require(window.historyScrollMaximumForTests > 100)
        #expect(window.followsLatestForTests)
        window.scrollHistoryForTests(to: 40)
        #expect(!window.followsLatestForTests)
        let offset = window.historyScrollOffsetForTests
        window.show(text: "New speech at the bottom.", isFinal: true, sentenceID: 30)
        window.showTranslation("Earlier translated caption.", forSentenceID: 25)
        await Task.yield(); await Task.yield()
        #expect(!window.followsLatestForTests)
        #expect(abs(window.historyScrollOffsetForTests - offset) <= 1)
        window.jumpToLatest()
        #expect(window.followsLatestForTests)
        #expect(abs(window.historyScrollOffsetForTests - window.historyScrollMaximumForTests) <= 1)
        window.scrollHistoryForTests(to: 0)
        window.clearHistory(keepVisible: true)
        #expect(window.followsLatestForTests)
        window.orderOut(nil)
    }

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

    @Test("caption font changes reach the live bubble for both text roles")
    func captionFontChangesAreAppliedTogether() {
        let defaults = UserDefaults.standard
        let key = CaptionStyle.key
        let previous = defaults.data(forKey: key)
        defer {
            if let previous { defaults.set(previous, forKey: key) }
            else { defaults.removeObject(forKey: key) }
        }

        var style = CaptionStyle.current
        style.original.fontSize = 38
        style.translation.fontSize = 38
        CaptionStyle.current = style

        let window = OverlayWindow()
        #expect(window.renderedStyleForTests.original.fontSize == 38)
        #expect(window.renderedStyleForTests.translation.fontSize == 38)
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
        #expect(!window.hasVisibleCaption)
        window.orderOut(nil)
    }

    @Test("clear is only for a caption that is on screen")
    func clearRequiresAVisibleCaption() {
        let defaults = UserDefaults.standard
        let styleKey = CaptionStyle.key
        let previousStyle = defaults.data(forKey: styleKey)
        defer {
            if let previousStyle {
                defaults.set(previousStyle, forKey: styleKey)
            } else {
                defaults.removeObject(forKey: styleKey)
            }
        }

        var style = CaptionStyle.current
        style.hidden = false
        CaptionStyle.current = style
        let window = OverlayWindow()
        #expect(!window.hasVisibleCaption)

        window.show(text: "A caption is showing.", isFinal: true, sentenceID: 1)
        #expect(window.hasVisibleCaption)
        #expect(CaptionLatencyCopy.clearEnabled(showingCaption: window.hasVisibleCaption))

        style.hidden = true
        CaptionStyle.current = style
        #expect(!window.hasVisibleCaption)
        window.orderOut(nil)
    }

    @Test("volatile caption updates coalesce layout renders")
    func volatileUpdatesCoalesce() async throws {
        let window = OverlayWindow()
        let before = window.renderPassesForTests

        for index in 0..<8 {
            window.show(text: "Hello revision \(index)",
                        isFinal: false,
                        sentenceID: 1)
        }
        try await Task.sleep(nanoseconds: 180_000_000)

        #expect(window.renderPassesForTests - before <= 2)
        window.orderOut(nil)
    }
}
