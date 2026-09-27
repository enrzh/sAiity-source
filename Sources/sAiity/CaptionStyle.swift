import AppKit
import Foundation

extension Notification.Name {
    static let saiityCaptionStyleChanged = Notification.Name("sAiityCaptionStyleChanged")
    static let saiityDictationStyleChanged = Notification.Name("sAiityDictationStyleChanged")
    static let saiityDictationPreview = Notification.Name("sAiityDictationPreview")
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
    static let dictation = TextStyle(fontSize: 14, weight: 0.3, colorHex: "FFFFFF",
                                     opacity: 1.0, volatileOpacity: 1.0, maxLines: 4)

    var color: NSColor { CaptionStyle.color(fromHex: colorHex) ?? .white }
    var font: NSFont { .systemFont(ofSize: fontSize, weight: .init(weight)) }

    private static let fittedFontCache: NSCache<NSString, NSFont> = {
        let cache = NSCache<NSString, NSFont>()
        cache.countLimit = 512
        return cache
    }()

    /// Keep the selected size for short text, but shrink long spans until the
    /// configured line budget is usable. The setting is a starting size; the
    /// per-line fit keeps long captions inside the bubble without changing the
    /// user's chosen scale.
    func fittedFont(for text: String, width: CGFloat, minimumSize: CGFloat,
                    maxLines: Int) -> NSFont {
        let baseSize = max(minimumSize, fontSize)
        guard !text.isEmpty, width > 1, maxLines > 0 else {
            return .systemFont(ofSize: baseSize, weight: .init(weight))
        }

        // Width changes during an edge drag should not create a new entry for
        // every fractional point. Conservative rounding keeps wrapping
        // correct while limiting cache churn.
        let cacheWidth = max(1, floor(width / 4) * 4)
        let key = "\(fontSize)|\(weight)|\(minimumSize)|\(maxLines)|\(cacheWidth)|\(text)" as NSString
        if let cached = Self.fittedFontCache.object(forKey: key) {
            return cached
        }

        // Binary search for the largest point size that still fits the line
        // budget. Stepping down one point at a time cost up to 36 text
        // measurements per cache miss, on the main actor, up to twice per
        // caption; the fit predicate is monotonic in the point size, so ~5
        // measurements find the same answer. Whole points only, so the result
        // is still a size the user can recognise from the settings slider.
        let minimum = max(1, Int(minimumSize.rounded()))
        let maximum = max(minimum, Int(baseSize.rounded()))
        var low = minimum
        var high = maximum
        while low < high {
            let mid = (low + high + 1) / 2
            if Self.fits(text: text, width: cacheWidth, maxLines: maxLines,
                          pointSize: CGFloat(mid), weight: weight) {
                low = mid
            } else {
                high = mid - 1
            }
        }

        let fitted = NSFont.systemFont(ofSize: CGFloat(low), weight: .init(weight))
        Self.fittedFontCache.setObject(fitted, forKey: key)
        return fitted
    }

    private static func fits(text: String, width: CGFloat, maxLines: Int,
                             pointSize: CGFloat, weight: Double) -> Bool {
        let candidate = NSFont.systemFont(ofSize: pointSize, weight: .init(weight))
        let rect = (text as NSString).boundingRect(
            with: NSSize(width: width, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: candidate])
        let lineHeight = candidate.ascender - candidate.descender + candidate.leading
        let lineCount = max(1, Int(ceil(rect.height / max(1, lineHeight))))
        return lineCount <= maxLines
    }

    /// Avoid a one-point grow/shrink oscillation while a live caption is still
    /// being revised. Shrinking is never delayed when the current size no
    /// longer fits the line budget.
    func stabilizedFont(for text: String, width: CGFloat, minimumSize: CGFloat,
                        maxLines: Int, previousPointSize: CGFloat?) -> NSFont {
        let candidate = fittedFont(for: text, width: width,
                                   minimumSize: minimumSize, maxLines: maxLines)
        guard let previousPointSize,
              candidate.pointSize > previousPointSize,
              candidate.pointSize - previousPointSize < 2 else {
            return candidate
        }
        return .systemFont(ofSize: previousPointSize, weight: .init(weight))
    }
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
    /// Width of the press-to-talk result bubble, in points.
    var dictationWidth: Double = 224
    /// When false, the subtitle bubble keeps the width chosen by dragging an edge.
    var autoResize: Bool = true

    var showTranslation: Bool = true
    var hidden: Bool = false           // hide the bubble without stopping capture

    static let key = "captionStyle"

    private enum CodingKeys: String, CodingKey {
        case original, translation, lineGap, cornerRadius, glassStyle, tintHex
        case widthFraction, screenMargin, maxHeight, dictationWidth, autoResize, showTranslation, hidden
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
        dictationWidth = 224
        autoResize = true
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
        dictationWidth = try c.decodeIfPresent(Double.self, forKey: .dictationWidth) ?? 224
        autoResize = try c.decodeIfPresent(Bool.self, forKey: .autoResize) ?? true
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

    /// Dictation has the same rendering surface as captions, but its settings
    /// are intentionally independent so a large subtitle layout does not make
    /// a compact press-to-talk result unusable.
    static var dictationDefaults: CaptionStyle {
        var defaults = CaptionStyle()
        defaults.original = .dictation
        defaults.translation = .dictation
        return defaults
    }

    static var currentDictation: CaptionStyle {
        get {
            guard let d = UserDefaults.standard.data(forKey: dictationKey),
                  let s = try? JSONDecoder().decode(CaptionStyle.self, from: d) else {
                // The old app used the caption style for both surfaces. Carry
                // that appearance forward once, then keep future edits local.
                var migrated = CaptionStyle.current
                migrated.original = .dictation
                migrated.translation = .dictation
                if let data = try? JSONEncoder().encode(migrated) {
                    UserDefaults.standard.set(data, forKey: dictationKey)
                }
                return migrated
            }
            return s
        }
        set {
            if let d = try? JSONEncoder().encode(newValue) {
                UserDefaults.standard.set(d, forKey: dictationKey)
            }
            NotificationCenter.default.post(name: .saiityDictationStyleChanged, object: nil)
        }
    }

    static let dictationKey = "dictationBubbleStyle"

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

    static let longPreviewOriginal =
        "Das ist eine längere Vorschau, and now we switch to English so the automatic font sizing can be checked. 你好，继续测试。"
    static let longPreviewTranslation =
        "This is a longer preview that checks wrapping, translation spacing, and mixed-script readability."
    static let longDictationPreview =
        "Das ist eine längere dictation preview with English mixed in.\n\n你好，继续测试这段可滚动的结果文本。\n\nThe bubble should stay readable while the result remains scrollable."
}

enum BubbleStyleContext: Hashable, Sendable {
    case captions
    case dictation
}

enum BubbleStylePreset: String, CaseIterable, Hashable, Sendable {
    case minimal
    case balanced
    case readable
    case liquidGlass

    var title: String {
        switch self {
        case .minimal: String(localized: "Minimal")
        case .balanced: String(localized: "Balanced")
        case .readable: String(localized: "Readable")
        case .liquidGlass: String(localized: "Liquid Glass")
        }
    }

    /// Presets deliberately leave behavior fields alone. A visual choice must
    /// not unexpectedly hide the bubble, change translation, or disable drag
    /// sizing.
    func applying(to style: CaptionStyle, context: BubbleStyleContext) -> CaptionStyle {
        var result = style
        var original = context == .dictation ? TextStyle.dictation : TextStyle.original
        var translation = context == .dictation ? TextStyle.dictation : TextStyle.translation
        var lineGap = style.lineGap
        var widthFraction = style.widthFraction
        var screenMargin = style.screenMargin
        var dictationWidth = style.dictationWidth
        var maxHeight = style.maxHeight
        var cornerRadius = style.cornerRadius

        switch self {
        case .minimal:
            lineGap = 4
            widthFraction = 0.52
            screenMargin = 20
            maxHeight = 180
            dictationWidth = 200
            cornerRadius = 14
            if context == .captions {
                original = TextStyle(fontSize: 24, weight: 0.0, colorHex: "FFFFFF",
                                     opacity: 0.92, volatileOpacity: 0.68, maxLines: 3)
                translation = TextStyle(fontSize: 20, weight: 0.0, colorHex: "9FE8FF",
                                        opacity: 0.92, volatileOpacity: 1.0, maxLines: 3)
            }
        case .balanced:
            lineGap = 6
            widthFraction = 0.62
            screenMargin = 24
            maxHeight = 260
            dictationWidth = 224
            cornerRadius = 22
        case .readable:
            lineGap = 8
            widthFraction = 0.72
            screenMargin = 28
            maxHeight = 360
            dictationWidth = 320
            cornerRadius = 24
            original = TextStyle(fontSize: context == .dictation ? 20 : 42,
                                 weight: 0.3, colorHex: "FFFFFF", opacity: 1.0,
                                 volatileOpacity: context == .dictation ? 1.0 : 0.72,
                                 maxLines: 5)
            translation = TextStyle(fontSize: context == .dictation ? 18 : 34,
                                    weight: 0.0, colorHex: "BDEFFF", opacity: 1.0,
                                    volatileOpacity: 1.0, maxLines: 5)
        case .liquidGlass:
            lineGap = 6
            widthFraction = 0.62
            screenMargin = 24
            maxHeight = 260
            dictationWidth = 224
            cornerRadius = 22
        }

        result.original = original
        result.translation = translation
        result.maxHeight = maxHeight
        result.cornerRadius = cornerRadius
        if context == .captions {
            result.lineGap = lineGap
            result.widthFraction = widthFraction
            result.screenMargin = screenMargin
        } else {
            result.dictationWidth = dictationWidth
        }
        result.glassStyle = self == .liquidGlass ? CaptionStyle.liquidGlass : CaptionStyle.regularGlass
        result.tintHex = ""
        return result
    }
}

extension CaptionStyle {
    func matchingPreset(for context: BubbleStyleContext) -> BubbleStylePreset? {
        BubbleStylePreset.allCases.first { preset in
            let candidate = preset.applying(to: self, context: context)
            return hasSameAppearance(as: candidate, context: context)
        }
    }

    private func hasSameAppearance(as other: CaptionStyle, context: BubbleStyleContext) -> Bool {
        guard original == other.original,
              translation == other.translation,
              cornerRadius == other.cornerRadius,
              glassStyle == other.glassStyle,
              tintHex == other.tintHex,
              maxHeight == other.maxHeight else { return false }
        switch context {
        case .captions:
            return lineGap == other.lineGap
                && widthFraction == other.widthFraction
                && screenMargin == other.screenMargin
        case .dictation:
            return dictationWidth == other.dictationWidth
        }
    }
}
