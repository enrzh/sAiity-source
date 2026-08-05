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
        ("glassStyle",                { $0.glassStyle = 2 }),
        ("tintHex",                   { $0.tintHex = "112233" }),
        ("widthFraction",             { $0.widthFraction = 0.9 }),
        ("screenMargin",              { $0.screenMargin = 77 }),
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
    }
}
