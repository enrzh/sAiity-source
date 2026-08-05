import AppKit
import Foundation

extension Notification.Name {
    static let saiityCaptionStyleChanged = Notification.Name("sAiityCaptionStyleChanged")
    static let saiityCaptionPreview = Notification.Name("sAiityCaptionPreview")
}

/// How the caption bubble looks. Persisted, and applied live — changing a value
/// in the window updates the bubble immediately rather than on next launch,
/// because you cannot judge caption legibility from a settings form.
struct CaptionStyle: Equatable, Codable, Sendable {
    var fontSize: Double = 30
    var translationFontSize: Double = 24
    var maxLines: Int = 3
    var cornerRadius: Double = 22
    var textOpacity: Double = 1.0
    /// Volatile (not yet committed) text is dimmed so it is obvious the engine
    /// may still revise it.
    var volatileOpacity: Double = 0.72
    var glassStyle: Int = 0            // 0 = regular, 1 = clear
    var tintHex: String = ""           // empty = untinted glass
    var showTranslation: Bool = true
    var hidden: Bool = false           // hide the bubble without stopping capture

    static let key = "captionStyle"

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

    var tintColor: NSColor? {
        guard !tintHex.isEmpty, tintHex.count == 6,
              let v = UInt32(tintHex, radix: 16) else { return nil }
        return NSColor(srgbRed: CGFloat((v >> 16) & 0xFF) / 255,
                       green: CGFloat((v >> 8) & 0xFF) / 255,
                       blue: CGFloat(v & 0xFF) / 255, alpha: 1)
    }

    /// A realistic two-line sample, so the preview exercises wrapping and the
    /// translation row rather than a single short word.
    static let sampleOriginal = "Dies ist eine Beispiel-Untertitelzeile, um Größe und Lesbarkeit zu prüfen."
    static let sampleTranslation = "This is a sample subtitle line, to check size and legibility."
}
