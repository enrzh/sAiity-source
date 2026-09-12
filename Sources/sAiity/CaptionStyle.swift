import AppKit
import Foundation

extension Notification.Name {
    static let saiityCaptionStyleChanged = Notification.Name("sAiityCaptionStyleChanged")
    static let saiityCaptionPreview = Notification.Name("sAiityCaptionPreview")
}

/// How one line of text is drawn. The original caption and the translation each
/// get their own, because they are read differently: the original is glanced at
/// to follow along, the translation is what a non-speaker actually reads.
///
/// Previously the translation was hardcoded to 24 pt teal with no control at
/// all, so someone reading the translation who enlarged "Caption size" made the
/// line they were *not* reading bigger.
struct TextStyle: Equatable, Codable, Sendable {
    var fontSize: Double
    /// NSFont weight, as a raw value: -0.4 … 0.6 in practice.
    var weight: Double
    /// sRGB hex, six digits. Not optional — text always has a colour.
    var colorHex: String
    var opacity: Double
    /// Dimming applied while the engine may still revise this line. Only the
    /// original is ever volatile, but keeping the field symmetric means the two
    /// roles can share one editor.
    var volatileOpacity: Double
    var maxLines: Int

    static let original = TextStyle(fontSize: 30, weight: 0.3, colorHex: "FFFFFF",
                                    opacity: 1.0, volatileOpacity: 0.72, maxLines: 4)
    static let translation = TextStyle(fontSize: 26, weight: 0.0, colorHex: "9FE8FF",
                                       opacity: 1.0, volatileOpacity: 1.0, maxLines: 4)

    var color: NSColor { CaptionStyle.color(fromHex: colorHex) ?? .white }
    var font: NSFont { .systemFont(ofSize: fontSize, weight: .init(weight)) }
}

/// How the caption bubble looks. Persisted, and applied live — changing a value
/// in the window updates the bubble immediately rather than on next launch,
/// because you cannot judge caption legibility from a settings form.
struct CaptionStyle: Equatable, Codable, Sendable {

    // MARK: Text, per role
    var original: TextStyle = .original
    var translation: TextStyle = .translation
    /// Gap between the original line and the translation under it.
    var lineGap: Double = 6

    // MARK: The bubble
    var cornerRadius: Double = 22
    static let regularGlass = 0
    static let clearGlass = 1
    static let solidGlass = 2
    static let liquidGlass = 3
    var glassStyle: Int = regularGlass // regular, clear, solid, or Liquid Glass
    var tintHex: String = ""           // empty = untinted glass

    /// Width as a fraction of the screen's usable width.
    ///
    /// The bubble's width is a SETTING, deliberately, not a measurement. Sizing
    /// it to its text meant every caption — and every translation arriving a
    /// moment later — resized and re-centred the window. A subtitle bubble whose
    /// width tracks its content cannot help but jitter.
    var widthFraction: Double = 0.62
    /// How much space to leave between the bubble and the screen edge. Applies
    /// to the automatic width and to how far the bubble may be pushed.
    var screenMargin: Double = 24
    /// Maximum height of the bubble's scrollable subtitle history, in points.
    var maxHeight: Double = 260

    var showTranslation: Bool = true
    var hidden: Bool = false           // hide the bubble without stopping capture

    static let key = "captionStyle"

    private enum CodingKeys: String, CodingKey {
        case original, translation, lineGap, cornerRadius, glassStyle, tintHex
        case widthFraction, screenMargin, maxHeight, showTranslation, hidden
    }

    init() {
        original = .original
        translation = .translation
        lineGap = 6
        cornerRadius = 22
        glassStyle = 0
        tintHex = ""
        widthFraction = 0.62
        screenMargin = 24
        maxHeight = 260
        showTranslation = true
        hidden = false
    }

    /// Decode older preferences without discarding the complete style just
    /// because the height setting did not exist in that version.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        original = try c.decodeIfPresent(TextStyle.self, forKey: .original) ?? .original
        translation = try c.decodeIfPresent(TextStyle.self, forKey: .translation) ?? .translation
        lineGap = try c.decodeIfPresent(Double.self, forKey: .lineGap) ?? 6
        cornerRadius = try c.decodeIfPresent(Double.self, forKey: .cornerRadius) ?? 22
        glassStyle = try c.decodeIfPresent(Int.self, forKey: .glassStyle) ?? 0
        tintHex = try c.decodeIfPresent(String.self, forKey: .tintHex) ?? ""
        widthFraction = try c.decodeIfPresent(Double.self, forKey: .widthFraction) ?? 0.62
        screenMargin = try c.decodeIfPresent(Double.self, forKey: .screenMargin) ?? 24
        maxHeight = try c.decodeIfPresent(Double.self, forKey: .maxHeight) ?? 260
        showTranslation = try c.decodeIfPresent(Bool.self, forKey: .showTranslation) ?? true
        hidden = try c.decodeIfPresent(Bool.self, forKey: .hidden) ?? false
    }

    static var current: CaptionStyle {
        get {
            guard let d = UserDefaults.standard.data(forKey: key),
                  let s = try? JSONDecoder().decode(CaptionStyle.self, from: d) else {
                return CaptionStyle()
            }
            return s
        }
        set {
            if let d = try? JSONEncoder().encode(newValue) {
                UserDefaults.standard.set(d, forKey: key)
            }
            NotificationCenter.default.post(name: .saiityCaptionStyleChanged, object: nil)
        }
    }

    static func color(fromHex hex: String) -> NSColor? {
        guard hex.count == 6, let v = UInt32(hex, radix: 16) else { return nil }
        return NSColor(srgbRed: CGFloat((v >> 16) & 0xFF) / 255,
                       green: CGFloat((v >> 8) & 0xFF) / 255,
                       blue: CGFloat(v & 0xFF) / 255, alpha: 1)
    }

    static func hex(from color: NSColor) -> String {
        guard let c = color.usingColorSpace(.sRGB) else { return "FFFFFF" }
        return String(format: "%02X%02X%02X",
                      Int(round(c.redComponent * 255)),
                      Int(round(c.greenComponent * 255)),
                      Int(round(c.blueComponent * 255)))
    }

    var tintColor: NSColor? {
        tintHex.isEmpty ? nil : Self.color(fromHex: tintHex)
    }

    /// A realistic two-line sample, so the preview exercises wrapping and the
    /// translation row rather than a single short word.
    /// Localised as a pair, and deliberately crossed: the *translated* row has
    /// to read in the UI language, so on a German Mac the original line is the
    /// English one. Two fixed literals showed a German user a German caption
    /// being "translated" into English.
    static var sampleOriginal: String {
        String(localized: "Dies ist eine Beispiel-Untertitelzeile, um Größe und Lesbarkeit zu prüfen.")
    }
    static var sampleTranslation: String {
        String(localized: "This is a sample subtitle line, to check size and legibility.")
    }
}
