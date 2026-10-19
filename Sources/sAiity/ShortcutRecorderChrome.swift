import AppKit

/// The look of a shortcut recorder, defined once.
///
/// ## Why this exists
///
/// Both recorders — the five in Settings → Captions and the one in Dictation —
/// were drawing a macOS **text field** by hand: `controlBackgroundColor` at 72%
/// over a `separatorColor` hairline, corner radius 8, a centred monospaced label.
/// That is the standard recipe for a field, so the controls read as editable
/// text. Someone will click one expecting to type a shortcut, and nothing they
/// type will register.
///
/// The difference between a field and a button on macOS is the *fill*, not the
/// border: a field is filled with the window background so it looks recessed
/// into the page, while a button is filled with a colour that belongs to it. So
/// these are filled with the accent colour — which is what the system itself
/// does for a control that is armed and available — and an unset shortcut is
/// filled more faintly with copy that invites the click rather than reporting a
/// status.
///
/// One definition, because these two were already drifting towards each other
/// and the day they differ by a shade nobody would notice is the day one of them
/// is wrong.
enum ShortcutRecorderChrome {
    /// Corner radius, shared so the two recorders are the same shape.
    static let cornerRadius: CGFloat = 8

    /// How the control looks in each of its three states.
    ///
    /// - Parameters:
    ///   - recording: armed and listening for keys.
    ///   - assigned: has a shortcut.
    ///
    /// At rest it is a quiet button, the same weight as the other controls in
    /// a settings form; a full accent fill made the one shortcut the loudest
    /// thing on the page. The accent appears only while it is listening.
    static func fill(recording: Bool, assigned: Bool) -> CGColor {
        if recording {
            return NSColor.controlAccentColor.withAlphaComponent(0.22).cgColor
        }
        return NSColor.labelColor.withAlphaComponent(assigned ? 0.07 : 0.04).cgColor
    }

    static func border(recording: Bool, assigned: Bool) -> CGColor {
        if recording { return NSColor.controlAccentColor.withAlphaComponent(0.8).cgColor }
        return NSColor.separatorColor.cgColor
    }

    static func borderWidth(recording: Bool) -> CGFloat { recording ? 1.5 : 0.5 }

    /// Text for the resting states.
    ///
    /// "Not set" reports a status; a control that has no value yet should say
    /// what pressing it does. Unassigned recorders also get the accent text colour
    /// so the invitation is the first thing read, not the last.
    ///
    /// Localized here rather than at the call site: the assigned value is a live
    /// key chord and cannot be a localization key, and a `String` is not a
    /// `String.LocalizationValue`, so the call sites assign the result directly.
    static func label(assigned: String?, recording: Bool) -> (text: String, isInvitation: Bool) {
        if recording { return (String(localized: "Press keys…"), false) }
        if let assigned, !assigned.isEmpty { return (assigned, false) }
        return (String(localized: "Click to set"), true)
    }
}
