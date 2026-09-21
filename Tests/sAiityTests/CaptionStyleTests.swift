import AppKit
import Foundation
import Testing

@testable import sAiity

/// An appearance setting that is stored but never read, or read but never
/// settable, looks exactly like a working feature and does nothing.
///
/// Five of the ten fields on the old `CaptionStyle` were in that state: the
/// translation font size, corner radius and both opacities had no control at
/// all, and the tint had neither a control nor any writer, so the glass could
/// never be tinted. `showTranslation` was worse — it had a control, and it only
/// changed the preview sample.
@MainActor
struct CaptionStyleTests {

    /// Every property, paired with a mutation. If a field is added without being
    /// added here the test stops compiling, which is the point.
    private static let mutations: [(String, (inout CaptionStyle) -> Void)] = [
        ("original.fontSize",         { $0.original.fontSize = 41 }),
        ("original.weight",           { $0.original.weight = 0.4 }),
        ("original.colorHex",         { $0.original.colorHex = "FF0000" }),
        ("original.opacity",          { $0.original.opacity = 0.5 }),
        ("original.volatileOpacity",  { $0.original.volatileOpacity = 0.3 }),
        ("original.maxLines",         { $0.original.maxLines = 7 }),
        ("translation.fontSize",      { $0.translation.fontSize = 19 }),
        ("translation.weight",        { $0.translation.weight = 0.4 }),
        ("translation.colorHex",      { $0.translation.colorHex = "00FF00" }),
        ("translation.opacity",       { $0.translation.opacity = 0.4 }),
        ("translation.volatileOpacity", { $0.translation.volatileOpacity = 0.4 }),
        ("translation.maxLines",      { $0.translation.maxLines = 6 }),
        ("lineGap",                   { $0.lineGap = 17 }),
        ("cornerRadius",              { $0.cornerRadius = 3 }),
        ("glassStyle",                { $0.glassStyle = CaptionStyle.liquidGlass }),
        ("tintHex",                   { $0.tintHex = "112233" }),
        ("widthFraction",             { $0.widthFraction = 0.9 }),
        ("screenMargin",              { $0.screenMargin = 77 }),
        ("maxHeight",                  { $0.maxHeight = 480 }),
        ("dictationWidth",             { $0.dictationWidth = 360 }),
        ("autoResize",                 { $0.autoResize.toggle() }),
        ("showTranslation",           { $0.showTranslation.toggle() }),
        ("hidden",                    { $0.hidden.toggle() }),
    ]

    @Test("Every style property survives a round trip through UserDefaults")
    func everyPropertyPersists() throws {
        for (name, mutate) in Self.mutations {
            var s = CaptionStyle()
            mutate(&s)
            let data = try JSONEncoder().encode(s)
            let back = try JSONDecoder().decode(CaptionStyle.self, from: data)
            #expect(back == s, "\(name) did not survive encode/decode")
            #expect(s != CaptionStyle(), "\(name) mutation was a no-op — the test is lying")
        }
    }

    @Test("Colours round-trip through hex without drifting")
    func colourRoundTrip() {
        for hex in ["FFFFFF", "000000", "9FE8FF", "FF0000", "123456"] {
            let c = try! #require(CaptionStyle.color(fromHex: hex))
            #expect(CaptionStyle.hex(from: c) == hex, "\(hex) drifted")
        }
        // Garbage in must not produce a colour; the caller falls back to white.
        #expect(CaptionStyle.color(fromHex: "nope") == nil)
        #expect(CaptionStyle.color(fromHex: "") == nil)
        #expect(CaptionStyle.color(fromHex: "FFF") == nil)
    }

    @Test("An empty tint means untinted, not black")
    func emptyTintIsNil() {
        var s = CaptionStyle()
        s.tintHex = ""
        #expect(s.tintColor == nil)
        s.tintHex = "204060"
        #expect(s.tintColor != nil)
    }

    @Test("The two roles are independently styled")
    func rolesAreIndependent() {
        // The complaint that prompted this: enlarging "Caption size" made the
        // original bigger while the translation — the line a non-speaker is
        // actually reading — stayed locked at 24 pt.
        var s = CaptionStyle()
        s.original.fontSize = 60
        #expect(s.translation.fontSize != s.original.fontSize)
        #expect(s.original.font.pointSize == 60)
        let got = Double(s.translation.font.pointSize)
        let want = CaptionStyle().translation.fontSize
        #expect(got == want, "translation font is \(got), expected \(want)")
    }

    @Test("Text size adapts to long captions")
    func textSizeFitsItsLineBudget() {
        let style = TextStyle.original
        let short = style.fittedFont(for: "Hello", width: 700,
                                     minimumSize: 18, maxLines: 4)
        let long = style.fittedFont(
            for: String(repeating: "A long caption that needs to wrap. ", count: 20),
            width: 120, minimumSize: 18, maxLines: 3)

        #expect(abs(Double(short.pointSize) - style.fontSize) < 0.01)
        #expect(long.pointSize < style.fontSize)
        #expect(long.pointSize >= 18)
    }

    @Test("Font growth has a small settling threshold")
    func fontGrowthIsStabilized() {
        let style = TextStyle.original
        let font = style.stabilizedFont(for: "Short text", width: 700,
                                        minimumSize: 18, maxLines: 4,
                                        previousPointSize: 29)
        #expect(font.pointSize == 29)
    }

    @Test("Defaults are legible rather than merely pretty")
    func defaultsAreReadable() {
        let s = CaptionStyle()
        // Both lines large enough to read across a room, and the translation not
        // smaller than the original by more than a little — it is often the line
        // that matters most.
        #expect(s.original.fontSize >= 24)
        #expect(s.translation.fontSize >= s.original.fontSize * 0.8)
        // Room to wrap. maxLines is a growth cap, and at 1–2 a long sentence is
        // silently cut off rather than wrapped.
        #expect(s.original.maxLines >= 3)
        #expect(s.translation.maxLines >= 3)
        // A gap from the screen edge by default, which is what "don't run off
        // the edge" needs.
        #expect(s.screenMargin > 0)
        #expect(s.widthFraction > 0 && s.widthFraction <= 1)
        #expect(s.maxHeight >= 110)
        #expect(s.autoResize)
    }

    @Test("Styles from before the height setting keep their values")
    func legacyStyleDecodesWithHeightDefault() throws {
        let legacy = """
        {"original":{"fontSize":42,"weight":0.3,"colorHex":"FFFFFF","opacity":1,"volatileOpacity":0.72,"maxLines":4},"translation":{"fontSize":26,"weight":0,"colorHex":"9FE8FF","opacity":1,"volatileOpacity":1,"maxLines":4},"lineGap":9,"cornerRadius":12,"glassStyle":1,"tintHex":"","widthFraction":0.7,"screenMargin":30,"showTranslation":false,"hidden":false}
        """.data(using: .utf8)!
        let style = try JSONDecoder().decode(CaptionStyle.self, from: legacy)
        #expect(style.original.fontSize == 42)
        #expect(style.showTranslation == false)
        #expect(style.maxHeight == 260)
        #expect(style.autoResize)
    }

    @Test("Dictation defaults are independent from caption preferences")
    func dictationDefaultsAreIndependent() {
        var captions = CaptionStyle()
        captions.original.fontSize = 58
        captions.glassStyle = CaptionStyle.liquidGlass

        let dictation = CaptionStyle.dictationDefaults
        #expect(dictation.original == .dictation)
        #expect(dictation.original.fontSize != captions.original.fontSize)
        #expect(dictation.glassStyle == CaptionStyle.regularGlass)
    }

    @Test("Balanced is the default preset for both surfaces")
    func balancedPresetMatchesDefaults() {
        #expect(CaptionStyle().matchingPreset(for: .captions) == .balanced)
        #expect(CaptionStyle.dictationDefaults.matchingPreset(for: .dictation) == .balanced)
    }

    @Test("Presets change appearance without changing behavior")
    func presetsPreserveBehavior() {
        var style = CaptionStyle()
        style.hidden = true
        style.showTranslation = false
        style.autoResize = false
        let customWidth = style.dictationWidth

        let readable = BubbleStylePreset.readable.applying(to: style, context: .captions)
        #expect(readable.hidden)
        #expect(readable.showTranslation == false)
        #expect(readable.autoResize == false)
        #expect(readable.dictationWidth == customWidth)
        #expect(readable.original.fontSize > style.original.fontSize)
        #expect(readable.matchingPreset(for: .captions) == .readable)
    }

    @Test("Manual visual edits switch the preset to Custom")
    func manualEditIsCustom() {
        var style = CaptionStyle()
        #expect(style.matchingPreset(for: .captions) == .balanced)
        style.lineGap += 1
        #expect(style.matchingPreset(for: .captions) == nil)
    }

    @Test("Caption and dictation presets keep unrelated dimensions independent")
    func presetContextsRemainIndependent() {
        var captions = CaptionStyle()
        captions.dictationWidth = 411
        let captionResult = BubbleStylePreset.minimal.applying(to: captions, context: .captions)
        #expect(captionResult.dictationWidth == 411)

        var dictation = CaptionStyle.dictationDefaults
        dictation.widthFraction = 0.91
        let dictationResult = BubbleStylePreset.readable.applying(to: dictation, context: .dictation)
        #expect(dictationResult.widthFraction == 0.91)
        #expect(dictationResult.dictationWidth == 320)
    }
}
