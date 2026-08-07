import Foundation

/// One way to persist a setting, instead of six.
///
/// The read-with-fallback / write-back pair was hand-rolled per setting across
/// six files, each with its own small differences — which is exactly how new
/// settings kept re-inventing the pattern and one of them ended up posting a
/// notification the others did not. Two deliberately keep custom accessors and
/// say why: `CaptionStyle.current` posts a change notification so the live
/// bubble follows the sliders, and `LocalModel.selected` resolves against a
/// catalogue rather than storing the value itself.
@propertyWrapper
struct Defaults<Value>: Sendable where Value: Sendable {
    private let key: String
    private let fallback: Value
    private let read: @Sendable (UserDefaults, String) -> Value?
    private let write: @Sendable (UserDefaults, String, Value) -> Void

    var wrappedValue: Value {
        get { read(.standard, key) ?? fallback }
        set { write(.standard, key, newValue) }
    }

    /// Property-list types: Bool, Int, Double, String, [String]…
    init(wrappedValue: Value, _ key: String) {
        self.key = key
        self.fallback = wrappedValue
        self.read = { d, k in d.object(forKey: k) as? Value }
        self.write = { d, k, v in d.set(v, forKey: k) }
    }

    /// String-backed enums, stored by raw value with a fallback for anything
    /// unrecognised — which is also what makes removing an enum case safe: a
    /// stored value that no longer exists resolves to the fallback instead of
    /// crashing or resetting unrelated settings.
    init(wrappedValue: Value, rawKey key: String)
    where Value: RawRepresentable, Value.RawValue == String {
        self.key = key
        self.fallback = wrappedValue
        self.read = { d, k in d.string(forKey: k).flatMap(Value.init(rawValue:)) }
        self.write = { d, k, v in d.set(v.rawValue, forKey: k) }
    }

    /// A choice that may genuinely never have been made.
    ///
    /// The difference from `rawKey` is the whole point: with a non-optional
    /// fallback there is no way to say "nothing chosen", so a fresh install
    /// reported a model as selected that it had not downloaded. Writing nil
    /// removes the key, so "never chosen" and "chosen, then cleared" are the
    /// same state — which is what the UI needs in order to show neither.
    ///
    /// An unrecognised stored value also reads as nil rather than as a
    /// substitute, so a model that has been removed from the catalogue leaves
    /// the user with no selection instead of a silent replacement.
    init<Wrapped>(wrappedValue: Value = nil, optionalRawKey key: String)
    where Value == Wrapped?, Wrapped: RawRepresentable, Wrapped.RawValue == String {
        self.key = key
        self.fallback = wrappedValue
        self.read = { d, k in d.string(forKey: k).flatMap(Wrapped.init(rawValue:)).map { .some($0) } }
        self.write = { d, k, v in
            if let v { d.set(v.rawValue, forKey: k) } else { d.removeObject(forKey: k) }
        }
    }
}
